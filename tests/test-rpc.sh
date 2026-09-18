#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-microvm RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises the MicroVm RPC service against the live OMV configuration
# database. Creates a test VM object and removes it on exit. If a real
# downloaded image is available, the VM is actually booted and put
# through a full warm+cold snapshot/restore round trip; otherwise
# lifecycle tests fall back to the no-image failure path.
#
# Requirements:
#   - Run as root
#   - OMV with the microvm plugin installed and configured
#   - A shared folder must already be set in plugin settings
#   - For the real snapshot/restore round trip: at least one downloaded
#     image, and enough host support to actually boot a Firecracker VM
#     (/dev/kvm, a bridge named br0)

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() { echo -e "  ${GREEN}PASS${NC}  $1" >&2; ((PASS++)) || true; }
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}
_skip() { echo -e "  ${YELLOW}SKIP${NC}  $1${2:+  ($2)}" >&2; ((SKIP++)) || true; }

RPC_OUT=""

assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    RPC_OUT=""
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:300}"
        return 1
    fi
    _pass "$desc"
    RPC_OUT="$out"
    return 0
}

assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded"
        return 1
    fi
    _pass "$desc"
    return 0
}

json_get() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$2',''))" 2>/dev/null; }
json_uuid() { json_get "$1" "uuid"; }

# Polls a background RPC job (execBgProc — createSnapshot/restoreSnapshot)
# to completion via the Exec service. $1 is the raw RPC response containing
# the bg status filename, $2 an optional timeout in seconds.
wait_bg() {
    local raw=$1 timeout=${2:-120} waited=0 filename out running
    filename=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null)
    if [ -z "$filename" ]; then
        echo "no background job filename in: $raw"
        return 1
    fi
    while [ "$waited" -lt "$timeout" ]; do
        out=$(omv-rpc -u admin "Exec" "getOutput" "{\"filename\":\"$filename\",\"pos\":0}" 2>&1)
        if echo "$out" | grep -qi "exception"; then
            echo "$out"
            return 1
        fi
        running=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('running'))" 2>/dev/null)
        [ "$running" = "False" ] && { echo "$out"; return 0; }
        sleep 1
        waited=$((waited + 1))
    done
    echo "timed out waiting for background job (filename=$filename)"
    return 1
}

vm_checksum() {
    md5sum "${SF_PATH%/}/vms/omvtest_microvm/rootfs.ext4" 2>/dev/null | awk '{print $1}'
}

# Finds a snapshot's directory id by its name, reading meta.json files
# directly (SF_PATH must already be resolved) — independent of whatever
# shape enumerateSnapshots' RPC response happens to have.
find_snapshot_id() {
    local want=$1 f
    for f in "${SF_PATH%/}/vms/omvtest_microvm/snapshots"/*/meta.json; do
        [ -f "$f" ] || continue
        if python3 -c "
import json, sys
d = json.load(open('$f'))
sys.exit(0 if d.get('name') == '$want' else 1)
" 2>/dev/null; then
            basename "$(dirname "$f")"
            return 0
        fi
    done
    return 1
}

vm_state() {
    omv-rpc -u admin "MicroVm" "getVmDetails" '{"name":"omvtest_microvm"}' 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null
}

wait_for_state() {
    local want=$1 timeout=${2:-60} waited=0 s
    while [ "$waited" -lt "$timeout" ]; do
        s=$(vm_state)
        [ "$s" = "$want" ] && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

OMV_NEW_UUID=$(grep -oP 'OMV_CONFIGOBJECT_NEW_UUID="\K[^"]+' /etc/default/openmediavault 2>/dev/null \
    || echo "fa4b1c66-ef79-11e5-87a0-0002b3a176b4")

VM_UUID=""
JOB_UUID=""

pre_cleanup() {
    local list='{"start":0,"limit":100,"sortfield":"name","sortdir":"ASC"}'
    local existing
    existing=$(omv-rpc -u admin "MicroVm" "getVmList" "$list" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name') == 'omvtest_microvm':
        print(r['uuid'])
" 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        info "Pre-cleanup: removing leftover test VM ($existing)"
        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$existing\",\"command\":\"delete\"}" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    section "Cleanup"
    if [ -n "$JOB_UUID" ]; then
        info "Deleting test job $JOB_UUID"
        omv-rpc -u admin "MicroVm" "deleteJob" "{\"uuid\":\"$JOB_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$VM_UUID" ]; then
        info "Deleting test VM $VM_UUID"
        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"delete\"}" >/dev/null 2>&1 || true
    fi
    echo "" >&2
    info "Deploying pending config changes asynchronously (clears web UI banner)"
    nohup omv-salt deploy run --quiet --append-dirty >/dev/null 2>&1 &
}
trap cleanup EXIT

section "Pre-cleanup"
pre_cleanup

# ---------------------------------------------------------------------------
# 1. Settings
# ---------------------------------------------------------------------------
section "Settings"

assert_rpc "getSettings" "MicroVm" "getSettings" '{}'
assert_rpc "getSettings returns firecracker_version" "MicroVm" "getSettings" '{}' '"firecracker_version"'

SETTINGS="$RPC_OUT"
if [ -n "$SETTINGS" ]; then
    SET_PARAMS=$(echo "$SETTINGS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keep = ['enable', 'sharedfolderref', 'default_bridge', 'install_cterm']
out = {k: d[k] for k in keep if k in d}
print(json.dumps(out))
" 2>/dev/null)
    if [ -n "$SET_PARAMS" ]; then
        assert_rpc "setSettings (round-trip)" "MicroVm" "setSettings" "$SET_PARAMS"
    fi
    SF_REF=$(json_get "$SETTINGS" "sharedfolderref")
fi

SF_PATH=""
REAL_IMAGE_REF=""
if [ -n "${SF_REF:-}" ]; then
    SF_PATH=$(omv-rpc -u admin "ShareMgmt" "getPath" "{\"uuid\":\"$SF_REF\"}" 2>/dev/null | jq -r '.' 2>/dev/null || echo "")
    IMG_LIST=$(omv-rpc -u admin "MicroVm" "enumerateImages" '{}' 2>/dev/null || echo '[]')
    REAL_IMAGE_REF=$(echo "$IMG_LIST" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d[0]['ref'] if d else '')
except Exception:
    print('')
" 2>/dev/null)
fi
if [ -n "$REAL_IMAGE_REF" ]; then
    info "Real image available ($REAL_IMAGE_REF) — the VM will actually boot and run a full snapshot/restore round trip."
else
    info "No downloaded image found — VM lifecycle/snapshot tests fall back to the no-image failure path."
fi

# ---------------------------------------------------------------------------
# 2. Networking helpers
# ---------------------------------------------------------------------------
section "Networking"

assert_rpc "enumerateBridges" "MicroVm" "enumerateBridges" '{}'

# ---------------------------------------------------------------------------
# 3. VMs — CRUD
# ---------------------------------------------------------------------------
section "VMs"

assert_rpc "getVmList" "MicroVm" "getVmList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

assert_rpc "getVmNameStateList" "MicroVm" "getVmNameStateList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

TEST_IMAGE_REF="${REAL_IMAGE_REF:-omvtest-nonexistent-image-x86_64}"

CREATE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'omvtest_microvm',
    'enable': True,
    'autostart': False,
    'vcpus': 1,
    'memory_mib': 512,
    'imageref': '$TEST_IMAGE_REF',
    'bridge': 'br0',
    'macaddr': '',
    'bootargs': 'console=ttyS0 reboot=k panic=1 pci=off',
    'notes': 'RPC test VM'
}))
")
assert_rpc "setVm (create)" "MicroVm" "setVm" "$CREATE_PARAMS"
VM_UUID=$(json_uuid "$RPC_OUT")
info "Created VM uuid=$VM_UUID"

if [ -n "$VM_UUID" ]; then
    assert_rpc "getVm" "MicroVm" "getVm" "{\"uuid\":\"$VM_UUID\"}" '"omvtest_microvm"'

    UPDATE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$VM_UUID',
    'name': 'omvtest_microvm',
    'enable': True,
    'autostart': False,
    'vcpus': 2,
    'memory_mib': 1024,
    'imageref': '$TEST_IMAGE_REF',
    'bridge': 'br0',
    'macaddr': '',
    'bootargs': 'console=ttyS0 reboot=k panic=1 pci=off',
    'notes': 'RPC test VM - updated'
}))
")
    assert_rpc "setVm (update)" "MicroVm" "setVm" "$UPDATE_PARAMS" 'updated'

    CHANGE_IMAGE_PARAMS=$(echo "$UPDATE_PARAMS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['imageref'] = 'omvtest-other-image-x86_64'
print(json.dumps(d))
")
    assert_rpc_fails "setVm (change image on existing VM)" "MicroVm" "setVm" "$CHANGE_IMAGE_PARAMS"

    assert_rpc "doCommand autostartenable" "MicroVm" "doCommand" \
        "{\"uuid\":\"$VM_UUID\",\"command\":\"autostartenable\"}" '"autostart":\s*true\|"autostart": true'
    assert_rpc "doCommand autostartdisable" "MicroVm" "doCommand" \
        "{\"uuid\":\"$VM_UUID\",\"command\":\"autostartdisable\"}"

    if [ -n "$REAL_IMAGE_REF" ]; then
        assert_rpc "doCommand start (real image)" "MicroVm" "doCommand" \
            "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}"
        if wait_for_state running 60; then
            _pass "VM with a real image reaches 'running' state"
        else
            _fail "VM with a real image reaches 'running' state" "state=$(vm_state) after waiting"
        fi
    else
        # Type=simple's start job completes on fork, not on staying alive,
        # so this succeeds even with no image — the VM fails moments later.
        assert_rpc "doCommand start (no image files)" "MicroVm" "doCommand" \
            "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}"
        if wait_for_state error 10; then
            _pass "VM without a real image lands in 'error' state"
        else
            _fail "VM without a real image lands in 'error' state" "state=$(vm_state) after waiting"
        fi
    fi

    assert_rpc "getVmDetails" "MicroVm" "getVmDetails" '{"name":"omvtest_microvm"}' '"consolelog"'
    assert_rpc "getConsoleLog" "MicroVm" "getConsoleLog" '{"name":"omvtest_microvm"}'
else
    _skip "getVm" "no vm uuid"
    _skip "setVm (update)" "no vm uuid"
    _skip "setVm (change image on existing VM)" "no vm uuid"
    _skip "doCommand autostartenable" "no vm uuid"
    _skip "doCommand autostartdisable" "no vm uuid"
    if [ -n "$REAL_IMAGE_REF" ]; then
        _skip "doCommand start (real image)" "no vm uuid"
        _skip "VM with a real image reaches 'running' state" "no vm uuid"
    else
        _skip "doCommand start (no image files)" "no vm uuid"
        _skip "VM without a real image lands in 'error' state" "no vm uuid"
    fi
    _skip "getVmDetails" "no vm uuid"
    _skip "getConsoleLog" "no vm uuid"
fi

assert_rpc_fails "setVm (missing name)" "MicroVm" "setVm" "$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'name': '', 'enable': True, 'autostart': False,
    'vcpus': 1, 'memory_mib': 512, 'imageref': '', 'bridge': '',
    'macaddr': '', 'bootargs': '', 'notes': ''
}))")"

assert_rpc_fails "getVm (bad uuid)" "MicroVm" "getVm" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
# 4. Images
# ---------------------------------------------------------------------------
section "Images"

assert_rpc "getImageList" "MicroVm" "getImageList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

assert_rpc "enumerateImages" "MicroVm" "enumerateImages" '{}'
assert_rpc "enumerateImages entries have a ref" "MicroVm" "enumerateImages" '{}' '"ref"\|^\[\]$'

assert_rpc "getImageCatalog" "MicroVm" "getImageCatalog" '{}'
assert_rpc "getImageCatalog entries have an id" "MicroVm" "getImageCatalog" '{}' '"id"'
assert_rpc "getImageCatalog entries have a version" "MicroVm" "getImageCatalog" '{}' '"version"'

assert_rpc_fails "deleteImage (bad uuid)" "MicroVm" "deleteImage" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

if [ -z "${SF_REF:-}" ]; then
    _skip "downloadImage (requires shared folder)" "no sharedfolderref configured"
else
    info "Shared folder is configured — downloadImage is exercised via the web UI, not this smoke test (network fetch, long-running)."
fi

# ---------------------------------------------------------------------------
# 5. Snapshots
# ---------------------------------------------------------------------------
section "Snapshots"

if [ -n "$VM_UUID" ]; then
    assert_rpc "enumerateSnapshots (empty for a VM with no snapshots)" "MicroVm" "enumerateSnapshots" \
        "{\"vmuuid\":\"$VM_UUID\"}" '^\[\]$'

    if [ -z "$REAL_IMAGE_REF" ]; then
        assert_rpc_fails "createSnapshot (VM not running)" "MicroVm" "createSnapshot" \
            "{\"vmuuid\":\"$VM_UUID\",\"name\":\"omvtest-snap\",\"notes\":\"\"}"
    fi
else
    _skip "enumerateSnapshots (empty for a VM with no snapshots)" "no vm uuid"
    _skip "createSnapshot (VM not running)" "no vm uuid"
fi

assert_rpc_fails "enumerateSnapshots (missing vmuuid)" "MicroVm" "enumerateSnapshots" '{}'

assert_rpc_fails "createSnapshot (bad vm uuid)" "MicroVm" "createSnapshot" \
    '{"vmuuid":"00000000-0000-0000-0000-000000000000","name":"x","notes":""}'

assert_rpc_fails "restoreSnapshot (bad vm uuid)" "MicroVm" "restoreSnapshot" \
    '{"vmuuid":"00000000-0000-0000-0000-000000000000","snapshotid":"deadbeefdeadbeef"}'

assert_rpc_fails "deleteSnapshot (bad vm uuid)" "MicroVm" "deleteSnapshot" \
    '{"vmuuid":"00000000-0000-0000-0000-000000000000","snapshotid":"deadbeefdeadbeef"}'

assert_rpc_fails "deleteAllSnapshots (bad vm uuid)" "MicroVm" "deleteAllSnapshots" \
    '{"vmuuid":"00000000-0000-0000-0000-000000000000"}'

# Real end-to-end round trip against the live VM: a warm snapshot (pause,
# dump memory, resume) while running, then a cold snapshot (disk only)
# once stopped, restored and verified byte-for-byte via host-side
# checksums — no guest-side scripting needed.
if [ -n "$VM_UUID" ] && [ -n "$REAL_IMAGE_REF" ] && [ "$(vm_state)" = "running" ]; then
    info "Running the real snapshot/restore round trip against the live VM ..."

    WARM_OUT=$(omv-rpc -u admin "MicroVm" "createSnapshot" \
        "{\"vmuuid\":\"$VM_UUID\",\"name\":\"omvtest-warm-snap\",\"notes\":\"\"}" 2>&1)
    if BG_RESULT=$(wait_bg "$WARM_OUT" 180); then
        _pass "createSnapshot (warm, real running VM)"
    else
        _fail "createSnapshot (warm, real running VM)" "$(echo "$BG_RESULT" | tail -5)"
    fi

    if [ "$(vm_state)" = "running" ]; then
        _pass "VM still running after warm snapshot (resume worked)"
    else
        _fail "VM still running after warm snapshot (resume worked)" "state=$(vm_state)"
    fi

    assert_rpc "enumerateSnapshots (finds the warm snapshot)" "MicroVm" "enumerateSnapshots" \
        "{\"vmuuid\":\"$VM_UUID\"}" 'omvtest-warm-snap'

    WARM_ID=$(find_snapshot_id "omvtest-warm-snap")

    if [ -n "$WARM_ID" ]; then
        WARM_DIR="${SF_PATH%/}/vms/omvtest_microvm/snapshots/${WARM_ID}"
        MEM_SIZE=$(stat -c%s "${WARM_DIR}/memfile" 2>/dev/null || echo 0)
        if [ "$MEM_SIZE" -gt 0 ]; then
            _pass "Warm snapshot's memfile is non-empty"
        else
            _fail "Warm snapshot's memfile is non-empty" "size=$MEM_SIZE"
        fi
        assert_rpc "deleteSnapshot (warm, real)" "MicroVm" "deleteSnapshot" \
            "{\"vmuuid\":\"$VM_UUID\",\"snapshotid\":\"$WARM_ID\"}"
    else
        _fail "Warm snapshot's memfile is non-empty" "could not find warm snapshot"
        _skip "deleteSnapshot (warm, real)" "could not find warm snapshot"
    fi

    assert_rpc "doCommand stop (before cold snapshot)" "MicroVm" "doCommand" \
        "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}"
    if wait_for_state stopped 30; then
        _pass "VM reaches 'stopped' state"
    else
        _fail "VM reaches 'stopped' state" "state=$(vm_state) after waiting"
    fi

    COLD_OUT=$(omv-rpc -u admin "MicroVm" "createSnapshot" \
        "{\"vmuuid\":\"$VM_UUID\",\"name\":\"omvtest-cold-snap\",\"notes\":\"\"}" 2>&1)
    if BG_RESULT=$(wait_bg "$COLD_OUT" 60); then
        _pass "createSnapshot (cold, stopped VM)"
    else
        _fail "createSnapshot (cold, stopped VM)" "$(echo "$BG_RESULT" | tail -5)"
    fi

    COLD_ID=$(find_snapshot_id "omvtest-cold-snap")

    if [ -n "$COLD_ID" ]; then
        COLD_DIR="${SF_PATH%/}/vms/omvtest_microvm/snapshots/${COLD_ID}"
        if [ -f "${COLD_DIR}/vmstate" ] || [ -f "${COLD_DIR}/memfile" ]; then
            _fail "Cold snapshot has no memory/device state" "vmstate or memfile unexpectedly present"
        else
            _pass "Cold snapshot has no memory/device state"
        fi

        SNAP_CHECKSUM=$(md5sum "${COLD_DIR}/rootfs.ext4" 2>/dev/null | awk '{print $1}')

        MNT=$(mktemp -d)
        if mount -o loop "${SF_PATH%/}/vms/omvtest_microvm/rootfs.ext4" "$MNT" 2>/dev/null; then
            touch "${MNT}/omvtest-post-snapshot-marker" 2>/dev/null
            umount "$MNT"
            _pass "Modified the live disk after the cold snapshot (mount+touch)"
        else
            _fail "Modified the live disk after the cold snapshot (mount+touch)" "loop mount failed"
        fi
        rmdir "$MNT" 2>/dev/null || true

        MODIFIED_CHECKSUM=$(vm_checksum)
        if [ -n "$SNAP_CHECKSUM" ] && [ "$MODIFIED_CHECKSUM" != "$SNAP_CHECKSUM" ]; then
            _pass "Live disk diverges from the cold snapshot after modification"
        else
            _fail "Live disk diverges from the cold snapshot after modification" "snap=$SNAP_CHECKSUM live=$MODIFIED_CHECKSUM"
        fi

        RESTORE_OUT=$(omv-rpc -u admin "MicroVm" "restoreSnapshot" \
            "{\"vmuuid\":\"$VM_UUID\",\"snapshotid\":\"$COLD_ID\"}" 2>&1)
        if BG_RESULT=$(wait_bg "$RESTORE_OUT" 60); then
            _pass "restoreSnapshot (cold)"
        else
            _fail "restoreSnapshot (cold)" "$(echo "$BG_RESULT" | tail -5)"
        fi

        RESTORED_CHECKSUM=$(vm_checksum)
        if [ -n "$SNAP_CHECKSUM" ] && [ "$RESTORED_CHECKSUM" = "$SNAP_CHECKSUM" ]; then
            _pass "Restored disk exactly matches the cold snapshot"
        else
            _fail "Restored disk exactly matches the cold snapshot" "snap=$SNAP_CHECKSUM restored=$RESTORED_CHECKSUM"
        fi

        if wait_for_state running 60; then
            _pass "VM boots successfully after being restored"
        else
            _fail "VM boots successfully after being restored" "state=$(vm_state) after waiting"
        fi
        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true

        assert_rpc "deleteSnapshot (cold, real)" "MicroVm" "deleteSnapshot" \
            "{\"vmuuid\":\"$VM_UUID\",\"snapshotid\":\"$COLD_ID\"}"
    else
        _fail "Cold snapshot has no memory/device state" "could not find cold snapshot"
        _skip "Live disk diverges from the cold snapshot after modification" "could not find cold snapshot"
        _skip "restoreSnapshot (cold)" "could not find cold snapshot"
        _skip "Restored disk exactly matches the cold snapshot" "could not find cold snapshot"
        _skip "VM boots successfully after being restored" "could not find cold snapshot"
        _skip "deleteSnapshot (cold, real)" "could not find cold snapshot"
    fi
elif [ -n "$VM_UUID" ] && [ -z "$REAL_IMAGE_REF" ]; then
    _skip "real snapshot/restore round trip" "no downloaded image available"
fi

# enumerateSnapshots/deleteSnapshot are pure filesystem operations (see
# microvm.inc: snapshots aren't confdb-tracked) — exercise them for real
# against a hand-fabricated snapshot directory too, independent of the
# real round trip above.
if [ -n "$VM_UUID" ] && [ -n "${SF_REF:-}" ]; then
    if [ -n "$SF_PATH" ]; then
        SNAP_ID=$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')
        SNAP_DIR="${SF_PATH%/}/vms/omvtest_microvm/snapshots/${SNAP_ID}"
        mkdir -p "$SNAP_DIR"
        : > "${SNAP_DIR}/memfile"
        : > "${SNAP_DIR}/vmstate"
        : > "${SNAP_DIR}/rootfs.ext4"
        cat > "${SNAP_DIR}/meta.json" <<EOF
{"name":"omvtest-fake-snap","notes":"fabricated by test-rpc.sh","created":"$(date -Iseconds)","size_bytes":0}
EOF

        assert_rpc "enumerateSnapshots (finds a fabricated snapshot)" "MicroVm" "enumerateSnapshots" \
            "{\"vmuuid\":\"$VM_UUID\"}" '"omvtest-fake-snap'

        assert_rpc "deleteSnapshot (removes a fabricated snapshot)" "MicroVm" "deleteSnapshot" \
            "{\"vmuuid\":\"$VM_UUID\",\"snapshotid\":\"$SNAP_ID\"}"

        if [ -d "$SNAP_DIR" ]; then
            _fail "deleteSnapshot actually removes the directory" "still exists: $SNAP_DIR"
            rm -rf "$SNAP_DIR"
        else
            _pass "deleteSnapshot actually removes the directory"
        fi
    else
        _skip "enumerateSnapshots (finds a fabricated snapshot)" "could not resolve shared folder path"
        _skip "deleteSnapshot (removes a fabricated snapshot)" "could not resolve shared folder path"
        _skip "deleteSnapshot actually removes the directory" "could not resolve shared folder path"
    fi
else
    _skip "enumerateSnapshots (finds a fabricated snapshot)" "no vm uuid or shared folder"
    _skip "deleteSnapshot (removes a fabricated snapshot)" "no vm uuid or shared folder"
    _skip "deleteSnapshot actually removes the directory" "no vm uuid or shared folder"
fi

# deleteAllSnapshots against two hand-fabricated snapshots — same
# filesystem-only exercise as above, but for the "remove everything" path.
if [ -n "$VM_UUID" ] && [ -n "${SF_REF:-}" ] && [ -n "$SF_PATH" ]; then
    SNAPS_DIR="${SF_PATH%/}/vms/omvtest_microvm/snapshots"
    for i in 1 2; do
        id=$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')
        d="${SNAPS_DIR}/${id}"
        mkdir -p "$d"
        : > "${d}/rootfs.ext4"
        cat > "${d}/meta.json" <<EOF
{"name":"omvtest-fake-snap-$i","notes":"","created":"$(date -Iseconds)","size_bytes":0}
EOF
    done

    assert_rpc "deleteAllSnapshots (removes multiple fabricated snapshots)" "MicroVm" "deleteAllSnapshots" \
        "{\"vmuuid\":\"$VM_UUID\"}"

    LEFTOVER=$(find "$SNAPS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if [ "$LEFTOVER" -eq 0 ]; then
        _pass "deleteAllSnapshots actually removes every directory"
    else
        _fail "deleteAllSnapshots actually removes every directory" "$LEFTOVER entries remain under $SNAPS_DIR"
        rm -rf "$SNAPS_DIR"
    fi
else
    _skip "deleteAllSnapshots (removes multiple fabricated snapshots)" "no vm uuid or shared folder"
    _skip "deleteAllSnapshots actually removes every directory" "no vm uuid or shared folder"
fi

# ---------------------------------------------------------------------------
# 6. Disk resize
# ---------------------------------------------------------------------------
section "Disk resize"

assert_rpc_fails "resizeDisk (missing vmuuid)" "MicroVm" "resizeDisk" '{"size_mib":"2048"}'

assert_rpc_fails "resizeDisk (bad vm uuid)" "MicroVm" "resizeDisk" \
    '{"vmuuid":"00000000-0000-0000-0000-000000000000","size_mib":"2048"}'

if [ -n "$VM_UUID" ] && [ -n "$REAL_IMAGE_REF" ]; then
    # Independent of whatever state the snapshot round trip above left the
    # VM in — resize always requires 'stopped'.
    omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true
    wait_for_state stopped 30 || true

    RESIZE_ROOTFS="${SF_PATH%/}/vms/omvtest_microvm/rootfs.ext4"
    CURRENT_MIB=$(( $(stat -c%s "$RESIZE_ROOTFS" 2>/dev/null || echo 0) / 1048576 ))

    if [ "$CURRENT_MIB" -gt 0 ]; then
        assert_rpc_fails "resizeDisk (shrink rejected)" "MicroVm" "resizeDisk" \
            "{\"vmuuid\":\"$VM_UUID\",\"size_mib\":\"${CURRENT_MIB}\"}"

        assert_rpc "doCommand start (for resize-while-running check)" "MicroVm" "doCommand" \
            "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}"
        wait_for_state running 60 || true
        assert_rpc_fails "resizeDisk (VM running)" "MicroVm" "resizeDisk" \
            "{\"vmuuid\":\"$VM_UUID\",\"size_mib\":\"$((CURRENT_MIB + 256))\"}"

        assert_rpc "doCommand stop (before real resize)" "MicroVm" "doCommand" \
            "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}"
        wait_for_state stopped 30 || true

        NEW_MIB=$((CURRENT_MIB + 256))
        RESIZE_OUT=$(omv-rpc -u admin "MicroVm" "resizeDisk" \
            "{\"vmuuid\":\"$VM_UUID\",\"size_mib\":\"${NEW_MIB}\"}" 2>&1)
        if BG_RESULT=$(wait_bg "$RESIZE_OUT" 60); then
            _pass "resizeDisk (grow, real disk)"
        else
            _fail "resizeDisk (grow, real disk)" "$(echo "$BG_RESULT" | tail -5)"
        fi

        RESIZED_MIB=$(( $(stat -c%s "$RESIZE_ROOTFS" 2>/dev/null || echo 0) / 1048576 ))
        if [ "$RESIZED_MIB" -eq "$NEW_MIB" ]; then
            _pass "Rootfs file grew to the requested size"
        else
            _fail "Rootfs file grew to the requested size" "expected ${NEW_MIB} MiB, got ${RESIZED_MIB} MiB"
        fi

        if e2fsck -fn "$RESIZE_ROOTFS" >/dev/null 2>&1; then
            _pass "Filesystem is clean after resize"
        else
            _fail "Filesystem is clean after resize" "e2fsck reported errors"
        fi
    else
        _skip "resizeDisk (shrink rejected)" "rootfs missing/empty"
        _skip "resizeDisk (VM running)" "rootfs missing/empty"
        _skip "resizeDisk (grow, real disk)" "rootfs missing/empty"
        _skip "Rootfs file grew to the requested size" "rootfs missing/empty"
        _skip "Filesystem is clean after resize" "rootfs missing/empty"
    fi
else
    _skip "resizeDisk (shrink rejected)" "no vm uuid or real image"
    _skip "resizeDisk (VM running)" "no vm uuid or real image"
    _skip "resizeDisk (grow, real disk)" "no vm uuid or real image"
    _skip "Rootfs file grew to the requested size" "no vm uuid or real image"
    _skip "Filesystem is clean after resize" "no vm uuid or real image"
fi

# ---------------------------------------------------------------------------
# 7. Backups
# ---------------------------------------------------------------------------
section "Backups"

assert_rpc "getBackupList" "MicroVm" "getBackupList" \
    '{"start":0,"limit":25,"sortfield":"vmname","sortdir":"ASC"}' '"total"'

assert_rpc_fails "doBackup (missing vmname)" "MicroVm" "doBackup" '{"path":"/tmp"}'
assert_rpc_fails "doBackup (missing path)" "MicroVm" "doBackup" '{"vmname":"omvtest_microvm"}'

# Real end-to-end round trip: back up the (now stopped) test VM's disk to a
# throwaway directory, mutate the live disk, restore from the backup, and
# verify byte-for-byte via host-side checksums — mirrors the snapshot round
# trip above but through the backup list file / arbitrary destination path.
BACKUP_TEST_DIR=$(mktemp -d /tmp/omvtest-microvm-backup.XXXXXX)

if [ -n "$VM_UUID" ] && [ -n "$REAL_IMAGE_REF" ]; then
    info "Running a real cold backup/restore round trip against the test VM ..."

    BACKUP_OUT=$(omv-rpc -u admin "MicroVm" "doBackup" \
        "{\"vmname\":\"omvtest_microvm\",\"path\":\"$BACKUP_TEST_DIR\",\"name\":\"omvtest-backup\",\"notes\":\"\"}" 2>&1)
    if BG_RESULT=$(wait_bg "$BACKUP_OUT" 60); then
        _pass "doBackup (cold, real)"
    else
        _fail "doBackup (cold, real)" "$(echo "$BG_RESULT" | tail -5)"
    fi

    BACKUP_DATE_DIR=$(find "${BACKUP_TEST_DIR}/omvtest_microvm" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)
    BACKUP_DATE=$(basename "${BACKUP_DATE_DIR:-}")

    if [ -n "$BACKUP_DATE" ]; then
        assert_rpc "getBackupList (finds the real backup)" "MicroVm" "getBackupList" \
            '{"start":0,"limit":100,"sortfield":"vmname","sortdir":"ASC"}' 'omvtest-backup'

        BACKUP_CHECKSUM=$(md5sum "${BACKUP_DATE_DIR}/rootfs.ext4" 2>/dev/null | awk '{print $1}')

        MNT=$(mktemp -d)
        if mount -o loop "${SF_PATH%/}/vms/omvtest_microvm/rootfs.ext4" "$MNT" 2>/dev/null; then
            touch "${MNT}/omvtest-post-backup-marker" 2>/dev/null
            umount "$MNT"
            _pass "Modified the live disk after the backup (mount+touch)"
        else
            _fail "Modified the live disk after the backup (mount+touch)" "loop mount failed"
        fi
        rmdir "$MNT" 2>/dev/null || true

        RESTORE_OUT=$(omv-rpc -u admin "MicroVm" "restoreBackup" \
            "{\"vmuuid\":\"$VM_UUID\",\"path\":\"$BACKUP_TEST_DIR\",\"vmname\":\"omvtest_microvm\",\"date\":\"$BACKUP_DATE\"}" 2>&1)
        if BG_RESULT=$(wait_bg "$RESTORE_OUT" 60); then
            _pass "restoreBackup (cold)"
        else
            _fail "restoreBackup (cold)" "$(echo "$BG_RESULT" | tail -5)"
        fi

        RESTORED_CHECKSUM=$(vm_checksum)
        if [ -n "$BACKUP_CHECKSUM" ] && [ "$RESTORED_CHECKSUM" = "$BACKUP_CHECKSUM" ]; then
            _pass "Restored disk exactly matches the backup"
        else
            _fail "Restored disk exactly matches the backup" "backup=$BACKUP_CHECKSUM restored=$RESTORED_CHECKSUM"
        fi

        if wait_for_state running 60; then
            _pass "VM boots successfully after being restored from backup"
        else
            _fail "VM boots successfully after being restored from backup" "state=$(vm_state) after waiting"
        fi
        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true

        BACKUP_UUID=$(grep ",${BACKUP_TEST_DIR%/}/\\?,omvtest_microvm,${BACKUP_DATE}," /etc/omv-microvm-backup.list 2>/dev/null | head -1 | cut -d, -f1)
        if [ -n "$BACKUP_UUID" ]; then
            assert_rpc "deleteBackup (real)" "MicroVm" "deleteBackup" \
                "{\"uuid\":\"$BACKUP_UUID\",\"path\":\"$BACKUP_TEST_DIR\",\"vmname\":\"omvtest_microvm\",\"date\":\"$BACKUP_DATE\"}"
            if [ -d "$BACKUP_DATE_DIR" ]; then
                _fail "deleteBackup actually removes the directory" "still exists: $BACKUP_DATE_DIR"
            else
                _pass "deleteBackup actually removes the directory"
            fi
        else
            _skip "deleteBackup (real)" "could not find list-file uuid for the backup"
        fi
    else
        _fail "getBackupList (finds the real backup)" "could not find backup directory under $BACKUP_TEST_DIR"
        _skip "restoreBackup (cold)" "could not find backup directory"
    fi
else
    _skip "real backup/restore round trip" "no vm uuid or no downloaded image"
fi
rm -rf "$BACKUP_TEST_DIR"

# getBackupList/deleteBackup are driven by the flat list file plus whatever
# is actually on disk — exercise them against a hand-fabricated entry too,
# independent of the real round trip above.
FAKE_BACKUP_DIR=$(mktemp -d /tmp/omvtest-microvm-backup-fake.XXXXXX)
FAKE_VM_DIR="${FAKE_BACKUP_DIR}/omvtest_microvm/2020-01-01_00-00-00"
mkdir -p "$FAKE_VM_DIR"
: > "${FAKE_VM_DIR}/rootfs.ext4"
cat > "${FAKE_VM_DIR}/meta.json" <<EOF
{"name":"omvtest-fake-backup","notes":"fabricated by test-rpc.sh","created":"$(date -Iseconds)","size_bytes":0,"warm":false}
EOF
FAKE_BACKUP_UUID=$(cat /proc/sys/kernel/random/uuid)
echo "${FAKE_BACKUP_UUID},${FAKE_BACKUP_DIR},omvtest_microvm,2020-01-01_00-00-00,0" >> /etc/omv-microvm-backup.list

assert_rpc "getBackupList (finds a fabricated backup)" "MicroVm" "getBackupList" \
    '{"start":0,"limit":100,"sortfield":"vmname","sortdir":"ASC"}' 'omvtest-fake-backup'

assert_rpc "deleteBackup (removes a fabricated backup)" "MicroVm" "deleteBackup" \
    "{\"uuid\":\"$FAKE_BACKUP_UUID\",\"path\":\"$FAKE_BACKUP_DIR\",\"vmname\":\"omvtest_microvm\",\"date\":\"2020-01-01_00-00-00\"}"

if [ -d "$FAKE_VM_DIR" ] || grep -q "^${FAKE_BACKUP_UUID}," /etc/omv-microvm-backup.list 2>/dev/null; then
    _fail "deleteBackup actually removes the directory and list entry" "leftover state"
else
    _pass "deleteBackup actually removes the directory and list entry"
fi
rm -rf "$FAKE_BACKUP_DIR"

# syncBackupList reconciles the list file against what's actually on disk:
# a row backed by a real directory (with rootfs.ext4) must survive, a row
# whose directory is gone must be dropped, and a .bak copy of the original
# list file must be left behind.
SYNC_BACKUP_DIR=$(mktemp -d /tmp/omvtest-microvm-backup-sync.XXXXXX)
SYNC_VALID_DIR="${SYNC_BACKUP_DIR}/omvtest_microvm/2020-01-01_00-00-00"
mkdir -p "$SYNC_VALID_DIR"
: > "${SYNC_VALID_DIR}/rootfs.ext4"
SYNC_VALID_UUID=$(cat /proc/sys/kernel/random/uuid)
SYNC_ORPHAN_UUID=$(cat /proc/sys/kernel/random/uuid)
echo "${SYNC_VALID_UUID},${SYNC_BACKUP_DIR},omvtest_microvm,2020-01-01_00-00-00,0" >> /etc/omv-microvm-backup.list
echo "${SYNC_ORPHAN_UUID},${SYNC_BACKUP_DIR},omvtest_microvm,2019-01-01_00-00-00,0" >> /etc/omv-microvm-backup.list

SYNC_OUT=$(omv-rpc -u admin "MicroVm" "syncBackupList" '{}' 2>&1)
if BG_RESULT=$(wait_bg "$SYNC_OUT" 30); then
    _pass "syncBackupList"
else
    _fail "syncBackupList" "$(echo "$BG_RESULT" | tail -5)"
fi

if grep -q "^${SYNC_VALID_UUID}," /etc/omv-microvm-backup.list 2>/dev/null; then
    _pass "syncBackupList keeps a row backed by a real directory"
else
    _fail "syncBackupList keeps a row backed by a real directory" "row missing after sync"
fi

if grep -q "^${SYNC_ORPHAN_UUID}," /etc/omv-microvm-backup.list 2>/dev/null; then
    _fail "syncBackupList drops a row whose directory is gone" "orphaned row still present"
else
    _pass "syncBackupList drops a row whose directory is gone"
fi

if [ -f /etc/omv-microvm-backup.list.bak ]; then
    _pass "syncBackupList leaves a .bak copy of the list file"
else
    _fail "syncBackupList leaves a .bak copy of the list file" "no .bak file found"
fi

sed -i "/^${SYNC_VALID_UUID},/d" /etc/omv-microvm-backup.list
rm -rf "$SYNC_BACKUP_DIR"

# ---------------------------------------------------------------------------
# 8. Scheduled backup jobs
# ---------------------------------------------------------------------------
section "Scheduled backup jobs"

JOB_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'enable': True,
    'vmname': 'omvtest_microvm',
    'path': '/tmp',
    'keep': 3,
    'sendemail': False,
    'emailonerror': False,
    'comment': 'RPC test job',
    'execution': 'daily',
    'minute': '0',
    'everynminute': False,
    'hour': '3',
    'everynhour': False,
    'month': '*',
    'dayofmonth': '*',
    'everyndayofmonth': False,
    'dayofweek': '*'
}))
")
assert_rpc "setJob (create)" "MicroVm" "setJob" "$JOB_PARAMS"
JOB_UUID=$(json_uuid "$RPC_OUT")
info "Created job uuid=$JOB_UUID"

if [ -n "$JOB_UUID" ]; then
    assert_rpc "getJob" "MicroVm" "getJob" "{\"uuid\":\"$JOB_UUID\"}" '"omvtest_microvm"'
    assert_rpc "getJobList" "MicroVm" "getJobList" \
        '{"start":0,"limit":25,"sortfield":"vmname","sortdir":"ASC"}' '"total"'

    UPDATE_JOB_PARAMS=$(echo "$JOB_PARAMS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['uuid'] = '$JOB_UUID'
d['keep'] = 5
print(json.dumps(d))
")
    assert_rpc "setJob (update)" "MicroVm" "setJob" "$UPDATE_JOB_PARAMS" 'updated\|"keep":\s*5\|"keep": 5'

    assert_rpc "deleteJob" "MicroVm" "deleteJob" "{\"uuid\":\"$JOB_UUID\"}"
    JOB_UUID=""
else
    _skip "getJob" "no job uuid"
    _skip "getJobList" "no job uuid"
    _skip "setJob (update)" "no job uuid"
    _skip "deleteJob" "no job uuid"
fi

assert_rpc_fails "setJob (missing execution)" "MicroVm" "setJob" "$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'enable': True, 'vmname': 'x', 'path': '/tmp'
}))")"

assert_rpc_fails "getJob (bad uuid)" "MicroVm" "getJob" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

assert_rpc_fails "doJob (bad uuid)" "MicroVm" "doJob" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
echo -e "  ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo "" >&2
    echo "Failed tests:" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t" >&2
    done
fi
[ "$FAIL" -eq 0 ]
