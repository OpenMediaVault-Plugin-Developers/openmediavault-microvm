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
NETWORK_UUID=""
DISK_UUID=""
NAT_NETWORK_UUID=""

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

    local existing_net
    existing_net=$(omv-rpc -u admin "MicroVm" "getNetworkList" '{"start":0,"limit":100,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name') in ('omvtest_network', 'omvtest_natdhcp'):
        print(r['uuid'])
" 2>/dev/null || echo "")
    for net in $existing_net; do
        info "Pre-cleanup: removing leftover test network ($net)"
        omv-rpc -u admin "MicroVm" "deleteNetwork" "{\"uuid\":\"$net\"}" >/dev/null 2>&1 || true
    done
}

cleanup() {
    section "Cleanup"
    if [ -n "$JOB_UUID" ]; then
        info "Deleting test job $JOB_UUID"
        omv-rpc -u admin "MicroVm" "deleteJob" "{\"uuid\":\"$JOB_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$DISK_UUID" ]; then
        info "Deleting test disk $DISK_UUID"
        omv-rpc -u admin "MicroVm" "deleteDisk" "{\"uuid\":\"$DISK_UUID\",\"deletefile\":true}" >/dev/null 2>&1 || true
    fi
    if [ -n "$VM_UUID" ]; then
        info "Deleting test VM $VM_UUID"
        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"delete\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$NAT_NETWORK_UUID" ]; then
        info "Deleting test NAT network $NAT_NETWORK_UUID"
        omv-rpc -u admin "MicroVm" "deleteNetwork" "{\"uuid\":\"$NAT_NETWORK_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$NETWORK_UUID" ]; then
        info "Deleting test network $NETWORK_UUID"
        omv-rpc -u admin "MicroVm" "deleteNetwork" "{\"uuid\":\"$NETWORK_UUID\"}" >/dev/null 2>&1 || true
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
keep = ['enable', 'sharedfolderref', 'install_cterm']
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
# 2b. Networks — CRUD
# ---------------------------------------------------------------------------
section "Networks"

TEST_NETWORK_NAME="omvtest_network"

NETWORK_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': '$TEST_NETWORK_NAME',
    'type': 'bridge',
    'bridge': 'br0',
    'subnet': '',
    'dhcp': True,
    'notes': 'RPC test network'
}))
")
assert_rpc "setNetwork (create, bridge type)" "MicroVm" "setNetwork" "$NETWORK_PARAMS"
NETWORK_UUID=$(json_uuid "$RPC_OUT")
info "Created network uuid=$NETWORK_UUID"

if [ -n "$NETWORK_UUID" ]; then
    assert_rpc "getNetwork" "MicroVm" "getNetwork" "{\"uuid\":\"$NETWORK_UUID\"}" "$TEST_NETWORK_NAME"
    assert_rpc "getNetworkList" "MicroVm" "getNetworkList" \
        '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

    UPDATE_NETWORK_PARAMS=$(echo "$NETWORK_PARAMS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['uuid'] = '$NETWORK_UUID'
d['notes'] = 'RPC test network - updated'
print(json.dumps(d))
")
    assert_rpc "setNetwork (update)" "MicroVm" "setNetwork" "$UPDATE_NETWORK_PARAMS" 'updated'
else
    _skip "getNetwork" "no network uuid"
    _skip "getNetworkList" "no network uuid"
    _skip "setNetwork (update)" "no network uuid"
fi

assert_rpc_fails "setNetwork (bridge type, missing bridge)" "MicroVm" "setNetwork" "$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'name': 'omvtest_bad_network', 'type': 'bridge',
    'bridge': '', 'subnet': '', 'dhcp': True, 'notes': ''
}))")"

assert_rpc_fails "setNetwork (nat type, bad subnet)" "MicroVm" "setNetwork" "$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'name': 'omvtest_bad_network2', 'type': 'nat',
    'bridge': '', 'subnet': 'not-a-subnet', 'dhcp': True, 'notes': ''
}))")"

assert_rpc_fails "getNetwork (bad uuid)" "MicroVm" "getNetwork" '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# Deliberately left in place (not deleted here) — the VM tests below
# reference it via networkref; cleanup() removes it after the VM.

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
    'networkref': '$TEST_NETWORK_NAME',
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
    'networkref': '$TEST_NETWORK_NAME',
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
    'vcpus': 1, 'memory_mib': 512, 'imageref': '', 'networkref': '',
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
    if wait_for_state stopped 60; then
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
        wait_for_state stopped 60 || true

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
    wait_for_state stopped 60 || true

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
        wait_for_state stopped 60 || true

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
# 6b. Data disks
# ---------------------------------------------------------------------------
section "Data disks"

assert_rpc "getDiskList" "MicroVm" "getDiskList" \
    '{"start":0,"limit":25,"sortfield":"name","sortdir":"ASC"}' '"total"'

disk_params() {
    # disk_params <uuid> <name> [<vmref>] [<readonly>] [<notes>]
    python3 -c "
import json
print(json.dumps({
    'uuid': '$1', 'vmref': '${3:-omvtest_microvm}', 'name': '$2',
    'sharedfolderref': '', 'size_mib': 64, 'fstype': 'ext4',
    'readonly': ${4:-False}, 'backup': True, 'notes': '${5:-}'
}))"
}

assert_rpc_fails "setDisk (unknown VM)" "MicroVm" "setDisk" \
    "$(disk_params "$OMV_NEW_UUID" omvtestdisk omvtest_no_such_vm)"
assert_rpc_fails "setDisk (reserved name 'rootfs')" "MicroVm" "setDisk" \
    "$(disk_params "$OMV_NEW_UUID" rootfs)"
assert_rpc_fails "setDisk (invalid name)" "MicroVm" "setDisk" \
    "$(disk_params "$OMV_NEW_UUID" 'bad-name')"

if [ -n "$VM_UUID" ] && [ -n "$SF_PATH" ]; then
    # Independent of whatever state earlier sections left the VM in.
    omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true
    wait_for_state stopped 60 || true

    DISK_FILE="${SF_PATH%/}/vms/omvtest_microvm/disks/omvtestdisk.img"
    rm -f "$DISK_FILE"

    assert_rpc "setDisk (create)" "MicroVm" "setDisk" "$(disk_params "$OMV_NEW_UUID" omvtestdisk)"
    DISK_UUID=$(json_uuid "$RPC_OUT")
    info "Created disk uuid=$DISK_UUID"

    if [ -f "$DISK_FILE" ] && [ "$(stat -c%s "$DISK_FILE")" -eq $((64 * 1048576)) ]; then
        _pass "Disk image created at the requested size"
    else
        _fail "Disk image created at the requested size" "missing or wrong size: $DISK_FILE"
    fi
    if [ "$(blkid -o value -s LABEL "$DISK_FILE" 2>/dev/null)" = "omvtestdisk" ]; then
        _pass "Disk image is ext4 labelled with the disk name"
    else
        _fail "Disk image is ext4 labelled with the disk name" "blkid: $(blkid "$DISK_FILE" 2>&1)"
    fi

    assert_rpc_fails "setDisk (duplicate name on same VM)" "MicroVm" "setDisk" \
        "$(disk_params "$OMV_NEW_UUID" omvtestdisk)"

    if [ -n "$DISK_UUID" ]; then
        assert_rpc "getDisk" "MicroVm" "getDisk" "{\"uuid\":\"$DISK_UUID\"}" '"omvtestdisk"'
        assert_rpc "setDisk (update options)" "MicroVm" "setDisk" \
            "$(disk_params "$DISK_UUID" omvtestdisk omvtest_microvm True updated)" 'updated'
        assert_rpc_fails "setDisk (rename existing disk)" "MicroVm" "setDisk" \
            "$(disk_params "$DISK_UUID" omvtestrenamed)"
        assert_rpc "setDisk (back to read-write)" "MicroVm" "setDisk" \
            "$(disk_params "$DISK_UUID" omvtestdisk)"

        assert_rpc "getVmList shows data_disk_count" "MicroVm" "getVmList" \
            '{"start":0,"limit":100,"sortfield":"name","sortdir":"ASC"}' '"data_disk_count": *1'

        assert_rpc_fails "resizeDataDisk (shrink rejected)" "MicroVm" "resizeDataDisk" \
            "{\"uuid\":\"$DISK_UUID\",\"size_mib\":\"32\"}"
        RESIZE_OUT=$(omv-rpc -u admin "MicroVm" "resizeDataDisk" \
            "{\"uuid\":\"$DISK_UUID\",\"size_mib\":\"96\"}" 2>&1)
        if BG_RESULT=$(wait_bg "$RESIZE_OUT" 60); then
            _pass "resizeDataDisk (grow)"
        else
            _fail "resizeDataDisk (grow)" "$(echo "$BG_RESULT" | tail -5)"
        fi
        if [ "$(stat -c%s "$DISK_FILE" 2>/dev/null || echo 0)" -eq $((96 * 1048576)) ] \
            && e2fsck -fn "$DISK_FILE" >/dev/null 2>&1; then
            _pass "Data disk grew and its filesystem is clean"
        else
            _fail "Data disk grew and its filesystem is clean" "size=$(stat -c%s "$DISK_FILE" 2>/dev/null)"
        fi

        if [ -n "$REAL_IMAGE_REF" ]; then
            assert_rpc "doCommand start (with data disk)" "MicroVm" "doCommand" \
                "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}"
            if wait_for_state running 60; then
                _pass "VM with a data disk reaches 'running' state"
            else
                _fail "VM with a data disk reaches 'running' state" "state=$(vm_state) after waiting"
            fi
            # Asks the live VMM rather than reading vm_config.json: the unit
            # is Type=simple, so 'running' is reported as soon as
            # omv-microvm-run forks — before it has rewritten the config
            # file, which still holds the previous boot's drives until then.
            FC_SOCKET="/run/openmediavault-microvm/omvtest_microvm/firecracker.socket"
            FC_DRIVES=""
            for _ in $(seq 1 30); do
                if [ -S "$FC_SOCKET" ]; then
                    FC_DRIVES=$(curl -sS --unix-socket "$FC_SOCKET" 'http://localhost/vm/config' 2>/dev/null \
                        | jq -c '[.drives[]?.drive_id]' 2>/dev/null)
                    [ -n "$FC_DRIVES" ] && break
                fi
                sleep 1
            done
            if echo "$FC_DRIVES" | jq -e 'index("omvtestdisk")' >/dev/null 2>&1; then
                _pass "Data disk is attached to the running VM"
            else
                _fail "Data disk is attached to the running VM" \
                    "drives=${FC_DRIVES:-<no API response>}; $(tail -5 "${SF_PATH%/}/vms/omvtest_microvm/vmm.log" 2>/dev/null)"
            fi
            assert_rpc_fails "resizeDataDisk (VM running)" "MicroVm" "resizeDataDisk" \
                "{\"uuid\":\"$DISK_UUID\",\"size_mib\":\"128\"}"
            assert_rpc_fails "deleteDisk (VM running)" "MicroVm" "deleteDisk" \
                "{\"uuid\":\"$DISK_UUID\",\"deletefile\":true}"

            SNAP_OUT=$(omv-rpc -u admin "MicroVm" "createSnapshot" \
                "{\"vmuuid\":\"$VM_UUID\",\"name\":\"omvtest-disk-snap\"}" 2>&1)
            if wait_bg "$SNAP_OUT" 120 >/dev/null; then
                DISK_SNAP_ID=$(find_snapshot_id omvtest-disk-snap || echo "")
                if [ -n "$DISK_SNAP_ID" ] && [ -f "${SF_PATH%/}/vms/omvtest_microvm/snapshots/${DISK_SNAP_ID}/disk-omvtestdisk.img" ]; then
                    _pass "Snapshot includes the data disk"
                else
                    _fail "Snapshot includes the data disk" "disk-omvtestdisk.img not in snapshot ${DISK_SNAP_ID}"
                fi
            else
                _fail "Snapshot includes the data disk" "createSnapshot failed"
            fi

            omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true
            wait_for_state stopped 60 || true
        else
            _skip "doCommand start (with data disk)" "no real image"
            _skip "VM with a data disk reaches 'running' state" "no real image"
            _skip "Data disk is attached to the running VM" "no real image"
            _skip "resizeDataDisk (VM running)" "no real image"
            _skip "deleteDisk (VM running)" "no real image"
            _skip "Snapshot includes the data disk" "no real image"
        fi

        assert_rpc "deleteDisk (keep file)" "MicroVm" "deleteDisk" \
            "{\"uuid\":\"$DISK_UUID\",\"deletefile\":\"false\"}"
        DISK_UUID=""
        if [ -f "$DISK_FILE" ]; then
            _pass "Kept disk image survives deleteDisk"
        else
            _fail "Kept disk image survives deleteDisk" "file gone: $DISK_FILE"
        fi

        assert_rpc "setDisk (reattach kept image)" "MicroVm" "setDisk" \
            "$(disk_params "$OMV_NEW_UUID" omvtestdisk)" '"size_mib": *96'
        DISK_UUID=$(json_uuid "$RPC_OUT")

        if [ -n "$DISK_UUID" ]; then
            assert_rpc "deleteDisk (delete file)" "MicroVm" "deleteDisk" \
                "{\"uuid\":\"$DISK_UUID\",\"deletefile\":true}"
            DISK_UUID=""
            if [ ! -e "$DISK_FILE" ]; then
                _pass "deleteDisk removes the disk image"
            else
                _fail "deleteDisk removes the disk image" "still present: $DISK_FILE"
            fi
        else
            _skip "deleteDisk (delete file)" "reattach failed"
            _skip "deleteDisk removes the disk image" "reattach failed"
        fi
    fi
else
    _skip "Data disk lifecycle" "no vm uuid or shared folder"
fi

# ---------------------------------------------------------------------------
# 6c. Jailer
# ---------------------------------------------------------------------------
section "Jailer"

vm_params() {
    # vm_params <jailer True|False|omit>
    python3 -c "
import json
d = {
    'uuid': '$VM_UUID', 'name': 'omvtest_microvm', 'enable': True, 'autostart': False,
    'vcpus': 2, 'memory_mib': 1024, 'imageref': '$TEST_IMAGE_REF',
    'networkref': '$TEST_NETWORK_NAME', 'macaddr': '',
    'bootargs': 'console=ttyS0 reboot=k panic=1 pci=off', 'notes': 'RPC test VM - updated'
}
if '$1' != 'omit':
    d['jailer'] = $1
print(json.dumps(d))"
}

vm_field() {
    omv-rpc -u admin "MicroVm" "getVm" "{\"uuid\":\"$VM_UUID\"}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null
}

# Must match the derivation in omv-microvm-run.
JAIL_DIR="/var/lib/openmediavault-microvm/jail/firecracker/mvm-$(echo -n omvtest_microvm | md5sum | cut -c1-16)"

if [ -n "$VM_UUID" ]; then
    omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true
    wait_for_state stopped 60 || true

    assert_rpc "setVm (enable jailer)" "MicroVm" "setVm" "$(vm_params True)"
    JAIL_UID=$(vm_field jail_uid)
    if [ "${JAIL_UID:-0}" -ge 1500000000 ] 2>/dev/null; then
        _pass "Jail uid allocated ($JAIL_UID)"
    else
        _fail "Jail uid allocated" "jail_uid=${JAIL_UID}"
    fi
    assert_rpc "setVm (jailer omitted keeps it on)" "MicroVm" "setVm" "$(vm_params omit)"
    if [ "$(vm_field jailer)" = "True" ] && [ "$(vm_field jail_uid)" = "$JAIL_UID" ]; then
        _pass "Jailer setting and uid survive an update without them"
    else
        _fail "Jailer setting and uid survive an update without them" \
            "jailer=$(vm_field jailer) jail_uid=$(vm_field jail_uid)"
    fi

    if [ -n "$REAL_IMAGE_REF" ]; then
        assert_rpc "doCommand start (jailed)" "MicroVm" "doCommand" \
            "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}"
        if wait_for_state running 60; then
            _pass "Jailed VM reaches 'running' state"
        else
            _fail "Jailed VM reaches 'running' state" "state=$(vm_state) after waiting"
        fi

        # Same race as the data disk check: wait for the live VMM.
        FC_SOCKET="/run/openmediavault-microvm/omvtest_microvm/firecracker.socket"
        FC_ROOT_DRIVE=""
        for _ in $(seq 1 30); do
            if [ -S "$FC_SOCKET" ]; then
                FC_ROOT_DRIVE=$(curl -sS --unix-socket "$FC_SOCKET" 'http://localhost/vm/config' 2>/dev/null \
                    | jq -r '.drives[]? | select(.drive_id == "rootfs") | .path_on_host' 2>/dev/null)
                [ -n "$FC_ROOT_DRIVE" ] && break
            fi
            sleep 1
        done
        if [ "$FC_ROOT_DRIVE" = "/rootfs.ext4" ]; then
            _pass "API socket works through the jail and sees chroot paths"
        else
            _fail "API socket works through the jail and sees chroot paths" \
                "rootfs drive=${FC_ROOT_DRIVE:-<no API response>}; $(tail -5 "${SF_PATH%/}/vms/omvtest_microvm/vmm.log" 2>/dev/null)"
        fi
        if pgrep -u "$JAIL_UID" -x firecracker >/dev/null; then
            _pass "Firecracker runs as the jail uid"
        else
            _fail "Firecracker runs as the jail uid" "no firecracker process with uid $JAIL_UID"
        fi

        assert_rpc_fails "setVm (switch jailer off while running)" "MicroVm" "setVm" "$(vm_params False)"

        SNAP_OUT=$(omv-rpc -u admin "MicroVm" "createSnapshot" \
            "{\"vmuuid\":\"$VM_UUID\",\"name\":\"omvtest-jail-snap\"}" 2>&1)
        JAIL_SNAP_ID=""
        if BG_RESULT=$(wait_bg "$SNAP_OUT" 120); then
            JAIL_SNAP_ID=$(find_snapshot_id omvtest-jail-snap || echo "")
        fi
        JAIL_SNAP_DIR="${SF_PATH%/}/vms/omvtest_microvm/snapshots/${JAIL_SNAP_ID}"
        if [ -n "$JAIL_SNAP_ID" ] && [ -f "${JAIL_SNAP_DIR}/jailed" ] \
            && [ "$(stat -c%u "${JAIL_SNAP_DIR}/memfile" 2>/dev/null)" = "0" ]; then
            _pass "Warm snapshot of a jailed VM (marked jailed, memfile owned by root)"
        else
            _fail "Warm snapshot of a jailed VM (marked jailed, memfile owned by root)" \
                "id=${JAIL_SNAP_ID}; $(ls -ln "$JAIL_SNAP_DIR" 2>&1 | tail -5)"
        fi

        if [ -n "$JAIL_SNAP_ID" ]; then
            RESTORE_OUT=$(omv-rpc -u admin "MicroVm" "restoreSnapshot" \
                "{\"vmuuid\":\"$VM_UUID\",\"snapshotid\":\"$JAIL_SNAP_ID\"}" 2>&1)
            if BG_RESULT=$(wait_bg "$RESTORE_OUT" 120) && wait_for_state running 60; then
                _pass "restoreSnapshot (warm, jailed)"
            else
                _fail "restoreSnapshot (warm, jailed)" "state=$(vm_state); $(echo "$BG_RESULT" | tail -5)"
            fi
        else
            _skip "restoreSnapshot (warm, jailed)" "no jailed snapshot"
        fi

        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true
        wait_for_state stopped 60 || true
        if [ ! -e "$JAIL_DIR" ] && ! findmnt -rn -o TARGET | grep -qF "$JAIL_DIR"; then
            _pass "Stopping removes the jail chroot and its mounts"
        else
            _fail "Stopping removes the jail chroot and its mounts" "$(findmnt -rn -o TARGET | grep -F "$JAIL_DIR")"
        fi
    else
        for t in "doCommand start (jailed)" "Jailed VM reaches 'running' state" \
            "API socket works through the jail and sees chroot paths" "Firecracker runs as the jail uid" \
            "setVm (switch jailer off while running)" \
            "Warm snapshot of a jailed VM (marked jailed, memfile owned by root)" \
            "restoreSnapshot (warm, jailed)" "Stopping removes the jail chroot and its mounts"; do
            _skip "$t" "no real image"
        done
    fi

    # Leaves the VM unjailed and stopped for the sections below.
    assert_rpc "setVm (disable jailer)" "MicroVm" "setVm" "$(vm_params False)"
    if [ "$(vm_field jail_uid)" = "$JAIL_UID" ]; then
        _pass "Jail uid is kept when the jailer is switched off"
    else
        _fail "Jail uid is kept when the jailer is switched off" "jail_uid=$(vm_field jail_uid)"
    fi

    if [ -n "$REAL_IMAGE_REF" ] && [ -n "${JAIL_SNAP_ID:-}" ]; then
        RESTORE_OUT=$(omv-rpc -u admin "MicroVm" "restoreSnapshot" \
            "{\"vmuuid\":\"$VM_UUID\",\"snapshotid\":\"$JAIL_SNAP_ID\"}" 2>&1)
        if wait_bg "$RESTORE_OUT" 120 >/dev/null; then
            _fail "restoreSnapshot (jailed snapshot, jailer now off) rejected" "restore succeeded"
            omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true
            wait_for_state stopped 60 || true
        else
            _pass "restoreSnapshot (jailed snapshot, jailer now off) rejected"
        fi
    else
        _skip "restoreSnapshot (jailed snapshot, jailer now off) rejected" "no real image or jailed snapshot"
    fi
else
    _skip "Jailer" "no vm uuid"
fi

# ---------------------------------------------------------------------------
# 6d. NAT network DHCP
# ---------------------------------------------------------------------------
section "NAT network DHCP"

TEST_NAT_NETWORK_NAME="omvtest_natdhcp"
# Override if this happens to overlap a host network.
TEST_NAT_SUBNET="${OMVTEST_NAT_SUBNET:-172.31.254.0/24}"
TEST_NAT_GATEWAY="${TEST_NAT_SUBNET%.*/*}.1"
DHCP_UNIT="omv-microvm-dhcp@${TEST_NAT_NETWORK_NAME}.service"
# Must match omv-microvm-run / omv-microvm-dhcp / omv-microvm-ensure-nat-network.
DHCP_DIR="/run/openmediavault-microvm-dhcp/${TEST_NAT_NETWORK_NAME}"
TEST_NAT_BRIDGE="mvm-nat-$(echo -n "$TEST_NAT_NETWORK_NAME" | md5sum | cut -c1-7)"
EXPECTED_MAC="02:fc:$(echo -n omvtest_microvm | md5sum | sed -E 's/^(..)(..)(..)(..).*/\1:\2:\3:\4/')"

# vm_set <key> <json-value>: getVm, change one field, setVm.
vm_set() {
    local cur
    cur=$(omv-rpc -u admin "MicroVm" "getVm" "{\"uuid\":\"$VM_UUID\"}" 2>/dev/null)
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['$1'] = json.loads(sys.argv[2])
print(json.dumps({k: d[k] for k in ('uuid', 'name', 'enable', 'autostart', 'vcpus', 'memory_mib',
    'imageref', 'networkref', 'macaddr', 'bootargs', 'notes', 'jailer', 'shutdown_timeout') if k in d}))
" "$cur" "$2"
}

nat_params() {
    # nat_params <uuid> <dhcp True|False>
    python3 -c "
import json
print(json.dumps({
    'uuid': '$1', 'name': '$TEST_NAT_NETWORK_NAME', 'type': 'nat', 'bridge': '',
    'subnet': '$TEST_NAT_SUBNET', 'dhcp': $2, 'notes': 'RPC test NAT network'
}))"
}

unit_active() { [ "$(systemctl is-active "$DHCP_UNIT" 2>/dev/null)" = "active" ]; }
wait_unit_active() {
    local _
    for _ in $(seq 1 "${1:-15}"); do unit_active && return 0; sleep 1; done
    return 1
}

# Sends one DNS query for "localhost" (answered from the host's /etc/hosts)
# straight to dnsmasq on the gateway; prints the first A record.
dns_query_localhost() {
    python3 - "$1" <<'PY' 2>/dev/null
import socket, struct, sys
q = struct.pack('>HHHHHH', 0x4d56, 0x0100, 1, 0, 0, 0) + b'\x09localhost\x00' + struct.pack('>HH', 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(q, (sys.argv[1], 53)); r, _ = s.recvfrom(512)
if struct.unpack('>H', r[6:8])[0] and r[-6:-4] == b'\x00\x04':
    print(socket.inet_ntoa(r[-4:]))
PY
}

assert_rpc "setNetwork (create, nat type with DHCP)" "MicroVm" "setNetwork" "$(nat_params "$OMV_NEW_UUID" True)"
NAT_NETWORK_UUID=$(json_uuid "$RPC_OUT")

if [ -n "$NAT_NETWORK_UUID" ]; then
    if ! ip link show "$TEST_NAT_BRIDGE" >/dev/null 2>&1; then
        if unit_active; then
            _fail "DHCP server not started before the network is up" "$DHCP_UNIT is active"
        else
            _pass "DHCP server not started before the network is up"
        fi
        DHCP_OUT=$(omv-microvm-dhcp "$TEST_NAT_NETWORK_NAME" 2>&1)
        if [ $? -ne 0 ] && echo "$DHCP_OUT" | grep -q "not up"; then
            _pass "omv-microvm-dhcp refuses to run without the bridge"
        else
            _fail "omv-microvm-dhcp refuses to run without the bridge" "$DHCP_OUT"
        fi
    else
        _skip "DHCP server not started before the network is up" "bridge left over from an earlier run"
        _skip "omv-microvm-dhcp refuses to run without the bridge" "bridge left over from an earlier run"
    fi

    assert_rpc "setNetwork (DHCP off)" "MicroVm" "setNetwork" "$(nat_params "$NAT_NETWORK_UUID" False)"
    DHCP_OUT=$(omv-microvm-dhcp "$TEST_NAT_NETWORK_NAME" 2>&1)
    if [ $? -ne 0 ] && echo "$DHCP_OUT" | grep -q "turned off"; then
        _pass "omv-microvm-dhcp refuses to run with DHCP off"
    else
        _fail "omv-microvm-dhcp refuses to run with DHCP off" "$DHCP_OUT"
    fi
    assert_rpc "setNetwork (DHCP back on)" "MicroVm" "setNetwork" "$(nat_params "$NAT_NETWORK_UUID" True)"

    if [ -n "$VM_UUID" ] && [ -n "$REAL_IMAGE_REF" ]; then
        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true
        wait_for_state stopped 60 || true
        assert_rpc "setVm (move to DHCP network, no MAC)" "MicroVm" "setVm" \
            "$(vm_set networkref "\"$TEST_NAT_NETWORK_NAME\"" | python3 -c "
import sys, json; d = json.load(sys.stdin); d['macaddr'] = ''; print(json.dumps(d))")"

        assert_rpc "doCommand start (on DHCP network)" "MicroVm" "doCommand" \
            "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}"
        wait_for_state running 60 || true

        if wait_unit_active 15; then
            _pass "DHCP server started with the first VM on the network"
        else
            _fail "DHCP server started with the first VM on the network" \
                "$(journalctl -u "$DHCP_UNIT" -n 5 --no-pager -o cat 2>&1)"
        fi

        HOSTS_LINE=$(cat "${DHCP_DIR}/hosts/omvtest_microvm" 2>/dev/null)
        if echo "$HOSTS_LINE" | grep -qE "^${EXPECTED_MAC},${TEST_NAT_SUBNET%.*/*}\.[0-9]+,infinite$"; then
            _pass "Reservation written with the derived MAC ($HOSTS_LINE)"
        else
            _fail "Reservation written with the derived MAC" "got '${HOSTS_LINE}', expected MAC ${EXPECTED_MAC}"
        fi

        FC_SOCKET="/run/openmediavault-microvm/omvtest_microvm/firecracker.socket"
        FC_VM_CONFIG=""
        for _ in $(seq 1 30); do
            if [ -S "$FC_SOCKET" ]; then
                FC_VM_CONFIG=$(curl -sS --unix-socket "$FC_SOCKET" 'http://localhost/vm/config' 2>/dev/null)
                [ -n "$FC_VM_CONFIG" ] && break
            fi
            sleep 1
        done
        if [ "$(echo "$FC_VM_CONFIG" | jq -r '."network-interfaces"[0].guest_mac' 2>/dev/null)" = "$EXPECTED_MAC" ]; then
            _pass "VM runs with the derived MAC"
        else
            _fail "VM runs with the derived MAC" "$(echo "$FC_VM_CONFIG" | jq -c '."network-interfaces"' 2>&1)"
        fi
        RESERVED_IP=$(echo "$HOSTS_LINE" | cut -d, -f2)
        if echo "$FC_VM_CONFIG" | jq -r '."boot-source".boot_args' 2>/dev/null \
            | grep -qF "ip=${RESERVED_IP}::${TEST_NAT_GATEWAY}:"; then
            _pass "Kernel ip= address matches the DHCP reservation"
        else
            _fail "Kernel ip= address matches the DHCP reservation" \
                "boot_args=$(echo "$FC_VM_CONFIG" | jq -r '."boot-source".boot_args' 2>&1)"
        fi
        if echo "$FC_VM_CONFIG" | jq -r '."boot-source".boot_args' 2>/dev/null \
            | grep -qF ":eth0:off:${TEST_NAT_GATEWAY}"; then
            _pass "Kernel ip= names the gateway as DNS server"
        else
            _fail "Kernel ip= names the gateway as DNS server" \
                "boot_args=$(echo "$FC_VM_CONFIG" | jq -r '."boot-source".boot_args' 2>&1)"
        fi

        if [ "$(dns_query_localhost "$TEST_NAT_GATEWAY")" = "127.0.0.1" ]; then
            _pass "dnsmasq answers DNS on the gateway address"
        else
            _fail "dnsmasq answers DNS on the gateway address" "$(ss -Hlnu 2>&1 | grep -F "$TEST_NAT_GATEWAY")"
        fi
        if ss -Hlnu 2>/dev/null | grep -qE "%${TEST_NAT_BRIDGE}:67\b"; then
            _pass "dnsmasq serves DHCP on the NAT bridge only"
        else
            _fail "dnsmasq serves DHCP on the NAT bridge only" "$(ss -Hlnu 2>&1 | grep ':67')"
        fi

        assert_rpc "setNetwork (DHCP off, network up)" "MicroVm" "setNetwork" "$(nat_params "$NAT_NETWORK_UUID" False)"
        if unit_active; then
            _fail "Turning DHCP off stops the server" "$DHCP_UNIT still active"
        else
            _pass "Turning DHCP off stops the server"
        fi
        assert_rpc "setNetwork (DHCP on, network up)" "MicroVm" "setNetwork" "$(nat_params "$NAT_NETWORK_UUID" True)"
        if wait_unit_active 10; then
            _pass "Turning DHCP on starts the server for a network that is up"
        else
            _fail "Turning DHCP on starts the server for a network that is up" "$DHCP_UNIT not active"
        fi

        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1 || true
        wait_for_state stopped 60 || true
        assert_rpc "setVm (back to the test bridge network)" "MicroVm" "setVm" \
            "$(vm_set networkref "\"$TEST_NETWORK_NAME\"")"
    else
        for t in "setVm (move to DHCP network, no MAC)" "doCommand start (on DHCP network)" \
            "DHCP server started with the first VM on the network" "Reservation written with the derived MAC" \
            "VM runs with the derived MAC" "Kernel ip= address matches the DHCP reservation" \
            "Kernel ip= names the gateway as DNS server" "dnsmasq answers DNS on the gateway address" \
            "dnsmasq serves DHCP on the NAT bridge only" "Turning DHCP off stops the server" \
            "Turning DHCP on starts the server for a network that is up" "setVm (back to the test bridge network)"; do
            _skip "$t" "no vm uuid or real image"
        done
    fi

    assert_rpc "deleteNetwork (NAT with DHCP)" "MicroVm" "deleteNetwork" "{\"uuid\":\"$NAT_NETWORK_UUID\"}"
    NAT_NETWORK_UUID=""
    if ! unit_active && [ ! -e "$DHCP_DIR" ] && ! ip link show "$TEST_NAT_BRIDGE" >/dev/null 2>&1; then
        _pass "deleteNetwork stops DHCP and removes its state and bridge"
    else
        _fail "deleteNetwork stops DHCP and removes its state and bridge" \
            "active=$(systemctl is-active "$DHCP_UNIT" 2>&1) dir=$(ls -d "$DHCP_DIR" 2>&1)"
    fi
else
    _skip "NAT network DHCP" "no network uuid"
fi

# ---------------------------------------------------------------------------
# 6e. Graceful shutdown
# ---------------------------------------------------------------------------
section "Graceful shutdown"

VM_UNIT="omv-microvm@omvtest_microvm.service"

# unit_log_since <epoch>: this VM unit's journal since then.
unit_log_since() { journalctl -u "$VM_UNIT" --since "@$1" --no-pager -o cat 2>/dev/null; }

# Waits for the guest to get far enough to act on Ctrl+Alt+Del.
wait_guest_booted() {
    local _
    for _ in $(seq 1 90); do
        grep -qiE 'login:|reached target' "${SF_PATH%/}/vms/omvtest_microvm/console.log" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

if [ -n "$VM_UUID" ]; then
    if systemctl show -p ExecStop --value "$VM_UNIT" 2>/dev/null | grep -q omv-microvm-shutdown; then
        _pass "VM unit has the graceful ExecStop"
    else
        _fail "VM unit has the graceful ExecStop" "$(systemctl show -p ExecStop --value "$VM_UNIT" 2>&1)"
    fi

    assert_rpc "setVm (shutdown_timeout 20)" "MicroVm" "setVm" "$(vm_set shutdown_timeout 20)" '"shutdown_timeout": *20'
    assert_rpc "setVm (shutdown_timeout omitted keeps it)" "MicroVm" "setVm" \
        "$(vm_set shutdown_timeout 20 | python3 -c "
import sys, json; d = json.load(sys.stdin); d.pop('shutdown_timeout'); print(json.dumps(d))")" '"shutdown_timeout": *20'
    assert_rpc_fails "setVm (shutdown_timeout 301)" "MicroVm" "setVm" "$(vm_set shutdown_timeout 301)"

    if [ -n "$REAL_IMAGE_REF" ] && [ "$(uname -m)" = "x86_64" ]; then
        assert_rpc "doCommand start (for graceful stop)" "MicroVm" "doCommand" \
            "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}"
        wait_for_state running 60 || true
        wait_guest_booted || info "Guest boot not seen on the console; trying the shutdown anyway."

        T0=$(date +%s)
        assert_rpc "doCommand stop (graceful)" "MicroVm" "doCommand" \
            "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}"
        if [ $(( $(date +%s) - T0 )) -le 5 ]; then
            _pass "doCommand stop returns without waiting for the guest"
        else
            _fail "doCommand stop returns without waiting for the guest" "took $(( $(date +%s) - T0 ))s"
        fi
        if wait_for_state stopped 60 && unit_log_since "$T0" | grep -q "Guest shut down."; then
            _pass "Guest shuts down cleanly on stop"
        else
            _fail "Guest shuts down cleanly on stop" "state=$(vm_state); $(unit_log_since "$T0" | tail -5)"
        fi

        assert_rpc "setVm (shutdown_timeout 0)" "MicroVm" "setVm" "$(vm_set shutdown_timeout 0)"
        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}" >/dev/null 2>&1
        wait_for_state running 60 || true
        T0=$(date +%s)
        omv-rpc -u admin "MicroVm" "doCommand" "{\"uuid\":\"$VM_UUID\",\"command\":\"stop\"}" >/dev/null 2>&1
        if wait_for_state stopped 20 && unit_log_since "$T0" | grep -q "Graceful shutdown disabled"; then
            _pass "shutdown_timeout 0 stops hard right away"
        else
            _fail "shutdown_timeout 0 stops hard right away" "state=$(vm_state); $(unit_log_since "$T0" | tail -5)"
        fi
    else
        for t in "doCommand start (for graceful stop)" "doCommand stop (graceful)" \
            "doCommand stop returns without waiting for the guest" "Guest shuts down cleanly on stop" \
            "setVm (shutdown_timeout 0)" "shutdown_timeout 0 stops hard right away"; do
            _skip "$t" "needs a real image on x86_64"
        done
    fi

    assert_rpc "setVm (shutdown_timeout back to 30)" "MicroVm" "setVm" "$(vm_set shutdown_timeout 30)"
else
    _skip "Graceful shutdown" "no vm uuid"
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
        wait_for_state stopped 60 || true

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
