#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-microvm RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises the MicroVm RPC service against the live OMV configuration
# database. Creates a test VM object and removes it on exit. Does NOT
# actually start a Firecracker VM (that requires a real kernel/rootfs
# image and the firecracker binary) — lifecycle command tests are
# limited to what is safe against a VM with no image configured.
#
# Requirements:
#   - Run as root
#   - OMV with the microvm plugin installed and configured
#   - A shared folder must already be set in plugin settings

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

OMV_NEW_UUID=$(grep -oP 'OMV_CONFIGOBJECT_NEW_UUID="\K[^"]+' /etc/default/openmediavault 2>/dev/null \
    || echo "fa4b1c66-ef79-11e5-87a0-0002b3a176b4")

VM_UUID=""

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

CREATE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'omvtest_microvm',
    'enable': True,
    'autostart': False,
    'vcpus': 1,
    'memory_mib': 512,
    'imageref': 'omvtest-nonexistent-image-x86_64',
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
    'imageref': 'omvtest-nonexistent-image-x86_64',
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

    # A Type=simple unit's start job completes as soon as the process is
    # forked, not once it's confirmed to stay running — so this RPC call
    # itself succeeds even with no real image configured. What must fail
    # cleanly (not hang, not crash the RPC) is the VM itself moments later,
    # which shows up as the unit landing in the 'error' state.
    assert_rpc "doCommand start (no image files)" "MicroVm" "doCommand" \
        "{\"uuid\":\"$VM_UUID\",\"command\":\"start\"}"

    STATE=""
    for _ in $(seq 1 20); do
        STATE=$(omv-rpc -u admin "MicroVm" "getVmDetails" '{"name":"omvtest_microvm"}' 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
        [ "$STATE" = "error" ] && break
        sleep 0.5
    done
    if [ "$STATE" = "error" ]; then
        _pass "VM without a real image lands in 'error' state"
    else
        _fail "VM without a real image lands in 'error' state" "state=${STATE:-<empty>} after waiting"
    fi

    assert_rpc "getVmDetails" "MicroVm" "getVmDetails" '{"name":"omvtest_microvm"}' '"consolelog"'
    assert_rpc "getConsoleLog" "MicroVm" "getConsoleLog" '{"name":"omvtest_microvm"}'
else
    _skip "getVm" "no vm uuid"
    _skip "setVm (update)" "no vm uuid"
    _skip "setVm (change image on existing VM)" "no vm uuid"
    _skip "doCommand autostartenable" "no vm uuid"
    _skip "doCommand autostartdisable" "no vm uuid"
    _skip "doCommand start (no image files)" "no vm uuid"
    _skip "VM without a real image lands in 'error' state" "no vm uuid"
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
