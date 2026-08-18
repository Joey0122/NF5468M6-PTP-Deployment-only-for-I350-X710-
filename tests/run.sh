#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
TEMP="$(mktemp -d)"
trap 'if [[ ${PTPCTL_KEEP_TEST_TEMP:-0} == 1 ]]; then echo "test temp preserved: $TEMP"; else rm -rf "$TEMP"; fi' EXIT
mkdir -p "$TEMP/bin" "$TEMP/logs" "$TEMP/run" "$TEMP/state" "$TEMP/sites"

# lspci is required on native Linux; the fixture bypasses its output but keeps
# the dependency check realistic in this WSL development environment.
for tool in lspci ip ethtool phc2sys pmc; do
cat > "$TEMP/bin/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEMP/bin/$tool"
done

cat > "$TEMP/bin/ptp4l" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -v ]]; then
    echo "ptp4l test-fixture 4.0"
    exit 0
fi
# Runtime tests deliberately model a daemon that fails immediately.
exit 1
EOF
chmod +x "$TEMP/bin/ptp4l"

cat > "$TEMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == is-active ]] && echo inactive
exit 3
EOF
chmod +x "$TEMP/bin/systemctl"

cat > "$TEMP/bin/timedatectl" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == show ]] && echo no
exit 0
EOF
chmod +x "$TEMP/bin/timedatectl"

cat > "$TEMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TEMP/bin/pgrep"

run_fixture() {
    env PATH="$TEMP/bin:$PATH" \
        PTPCTL_TEST_MODE=1 \
        PTPCTL_FIXTURE_FILE="$FIXTURES/nics.tsv" \
        PTPCTL_SITE_CONFIG="$FIXTURES/site-valid.env" \
        PTPCTL_LOG_DIR="$TEMP/logs" \
        PTPCTL_RUN_DIR="$TEMP/run" \
        PTPCTL_STATE_DIR="$TEMP/state" \
        PTPCTL_TEST_ALLOW_ROOT="${PTPCTL_TEST_ALLOW_ROOT:-0}" \
        PTPCTL_TEST_CLOCK_CONFLICT="${PTPCTL_TEST_CLOCK_CONFLICT:-0}" \
        "$ROOT/ptpctl" "$@"
}

wizard_fixture() {
    local fixture=$1 site_file=$2
    shift 2
    printf '%s\n' "$@" | env PATH="$TEMP/bin:$PATH" \
        PTPCTL_TEST_MODE=1 \
        PTPCTL_FIXTURE_FILE="$fixture" \
        PTPCTL_SITE_CONFIG="$site_file" \
        PTPCTL_LOG_DIR="$TEMP/logs" \
        PTPCTL_RUN_DIR="$TEMP/run" \
        PTPCTL_STATE_DIR="$TEMP/state" \
        PTPCTL_TEST_ALLOW_ROOT=1 \
        PTPCTL_TEST_CLOCK_CONFLICT="${PTPCTL_TEST_CLOCK_CONFLICT:-0}" \
        "$ROOT/ptpctl"
}

echo "1..31"
test_number=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $*"; }
fail() { test_number=$((test_number + 1)); echo "not ok $test_number - $*"; exit 1; }

bash -n "$ROOT/ptpctl" "$ROOT"/lib/*.sh && ok "bash syntax" || fail "bash syntax"

for mode in I350-master I350-slave X710-master X710-slave; do
    output="$TEMP/$mode.out"
    run_fixture setup "$mode" --dry-run > "$output" 2>&1 || fail "$mode dry-run exits successfully"
    grep -q "Mode:.*$mode" "$output" || fail "$mode reports selected mode"
    grep -q 'No process, clock, link, service, runtime state, or persistent configuration was changed' "$output" || fail "$mode is non-mutating"
    ok "$mode dry-run"
done

grep -q '^clientOnly[[:space:]]*1' "$TEMP/I350-slave.out" &&
grep -q 'wait for pmc PORT_DATA_SET state SLAVE' "$TEMP/I350-slave.out" &&
grep -q 'phc2sys -a -r -f' "$TEMP/I350-slave.out" && ok "slave role plan" || fail "slave role plan"

grep -q '^serverOnly[[:space:]]*1' "$TEMP/X710-master.out" &&
grep -q 'pre-align PHC: phc2sys -s CLOCK_REALTIME -c mockx710 -O 37' "$TEMP/X710-master.out" &&
grep -q 'wait for pmc PORT_DATA_SET state MASTER' "$TEMP/X710-master.out" &&
grep -q 'phc2sys -a -r -r -f' "$TEMP/X710-master.out" &&
grep -q 'LAB WARNING' "$TEMP/X710-master.out" && ok "master role plan" || fail "master role plan"

grep -q 'Interface:.*mocki350' "$TEMP/I350-master.out" &&
grep -q 'PHC:.*\/dev\/ptp4' "$TEMP/I350-master.out" &&
grep -q 'Driver:.*igb' "$TEMP/I350-master.out" && ok "I350 automatic discovery" || fail "I350 automatic discovery"

grep -q 'Interface:.*mockx710' "$TEMP/X710-slave.out" &&
grep -q 'PHC:.*\/dev\/ptp7' "$TEMP/X710-slave.out" &&
grep -q 'Driver:.*i40e' "$TEMP/X710-slave.out" && ok "X710 automatic discovery" || fail "X710 automatic discovery"

if env PATH="$TEMP/bin:$PATH" PTPCTL_TEST_MODE=1 PTPCTL_FIXTURE_FILE="$FIXTURES/nics-invalid.tsv" \
    PTPCTL_SITE_CONFIG="$FIXTURES/site-valid.env" PTPCTL_LOG_DIR="$TEMP/logs" PTPCTL_RUN_DIR="$TEMP/run" \
    "$ROOT/ptpctl" setup X710-slave --dry-run > "$TEMP/invalid.out" 2>&1; then
    fail "invalid hardware rejected"
else
    grep -q 'No hardware-valid X710 port' "$TEMP/invalid.out" && ok "invalid hardware rejected" || fail "invalid hardware diagnostic"
fi

if env PATH="$TEMP/bin:$PATH" PTPCTL_TEST_MODE=1 PTPCTL_FIXTURE_FILE="$FIXTURES/nics.tsv" \
    PTPCTL_SITE_CONFIG="$ROOT/configs/site.env.example" PTPCTL_LOG_DIR="$TEMP/logs" PTPCTL_RUN_DIR="$TEMP/run" \
    "$ROOT/ptpctl" setup I350-master --dry-run > "$TEMP/todo.out" 2>&1; then
    fail "TODO configuration rejected"
else
    grep -q 'PTP_DOMAIN is TODO' "$TEMP/todo.out" && ok "TODO configuration rejected" || fail "TODO diagnostic"
fi

run_fixture status > "$TEMP/status.out" 2>&1
grep -q 'PTP status: STOPPED' "$TEMP/status.out" && ok "dry-runs commit no runtime state" || fail "dry-run state safety"

for mode_spec in "1:I350-master:master" "2:I350-slave:slave" "3:X710-master:master" "4:X710-slave:slave"; do
    IFS=: read -r menu_mode mode_name role <<<"$mode_spec"
    site_file="$TEMP/sites/$mode_name.env"
    cp "$FIXTURES/site-valid.env" "$site_file"
    output="$TEMP/wizard-$mode_name.out"
    if [[ $role == master ]]; then
        wizard_fixture "$FIXTURES/nics.tsv" "$site_file" \
            "$menu_mode" "" "" "" "" "" "" "" "" n > "$output" 2>&1 || fail "$mode_name wizard cancellation is clean"
    else
        wizard_fixture "$FIXTURES/nics.tsv" "$site_file" \
            "$menu_mode" "" "" "" "" "" "" n > "$output" 2>&1 || fail "$mode_name wizard cancellation is clean"
    fi
    grep -q "Mode:.*$mode_name" "$output" &&
    grep -q 'Setup cancelled before start; no PTP process was started' "$output" &&
    ok "$mode_name interactive wizard" || fail "$mode_name interactive wizard"
done

site_file="$TEMP/sites/multiple.env"
cp "$FIXTURES/site-valid.env" "$site_file"
wizard_fixture "$FIXTURES/nics-multiple.tsv" "$site_file" \
    4 2 "" "" "" "" "" "" n > "$TEMP/multiple.out" 2>&1 || fail "multiple-port wizard succeeds"
grep -q 'Found 2 X710 ports' "$TEMP/multiple.out" &&
grep -q 'Interface:.*enp65s0f1' "$TEMP/multiple.out" &&
grep -q 'PCI:.*0000:41:00.1' "$TEMP/multiple.out" &&
grep -q 'PHC shared:.*YES' "$TEMP/multiple.out" &&
ok "multiple-port selection and shared PHC" || fail "multiple-port selection and shared PHC"

cp "$FIXTURES/site-valid.env" "$TEMP/sites/missing-nic.env"
if wizard_fixture "$FIXTURES/nics-empty.tsv" "$TEMP/sites/missing-nic.env" 3 > "$TEMP/missing-nic.out" 2>&1; then
    fail "missing NIC is rejected"
else
    grep -q 'No Intel X710 NIC port was detected' "$TEMP/missing-nic.out" && ok "missing NIC" || fail "missing NIC diagnostic"
fi

cp "$FIXTURES/site-valid.env" "$TEMP/sites/wrong-driver.env"
if wizard_fixture "$FIXTURES/nics-wrong-driver.tsv" "$TEMP/sites/wrong-driver.env" 4 > "$TEMP/wrong-driver.out" 2>&1; then
    fail "wrong driver is rejected"
else
    grep -q 'expected_driver_i40e' "$TEMP/wrong-driver.out" && ok "wrong driver" || fail "wrong driver diagnostic"
fi

cp "$FIXTURES/site-valid.env" "$TEMP/sites/missing-timestamp.env"
if wizard_fixture "$FIXTURES/nics-missing-timestamp.tsv" "$TEMP/sites/missing-timestamp.env" 2 > "$TEMP/missing-timestamp.out" 2>&1; then
    fail "missing hardware timestamp is rejected"
else
    grep -q 'no_hardware_tx' "$TEMP/missing-timestamp.out" && ok "missing hardware timestamp" || fail "timestamp diagnostic"
fi

cp "$FIXTURES/site-valid.env" "$TEMP/sites/missing-phc.env"
if wizard_fixture "$FIXTURES/nics-missing-phc.tsv" "$TEMP/sites/missing-phc.env" 4 > "$TEMP/missing-phc.out" 2>&1; then
    fail "missing PHC is rejected"
else
    grep -q 'no_valid_phc' "$TEMP/missing-phc.out" && ok "missing PHC" || fail "missing PHC diagnostic"
fi

cp "$FIXTURES/site-valid.env" "$TEMP/sites/link-down.env"
if wizard_fixture "$FIXTURES/nics-link-down.tsv" "$TEMP/sites/link-down.env" 4 > "$TEMP/link-down.out" 2>&1; then
    fail "link down is rejected"
else
    grep -q 'has no carrier' "$TEMP/link-down.out" && ok "link down" || fail "link-down diagnostic"
fi

cp "$FIXTURES/site-valid.env" "$TEMP/sites/clock-conflict.env"
if PTPCTL_TEST_CLOCK_CONFLICT=1 wizard_fixture "$FIXTURES/nics.tsv" "$TEMP/sites/clock-conflict.env" \
    2 "" "" "" "" "" "" n > "$TEMP/clock-conflict.out" 2>&1; then
    fail "clock-service conflict is rejected"
else
    grep -q 'another discipliner is active' "$TEMP/clock-conflict.out" && ok "clock-service conflict" || fail "clock-conflict diagnostic"
fi

site_file="$TEMP/sites/saved-defaults.env"
cp "$FIXTURES/site-valid.env" "$site_file"
wizard_fixture "$FIXTURES/nics.tsv" "$site_file" 4 "" "" "" "" "" "" n > "$TEMP/saved-defaults.out" 2>&1 ||
    fail "saved defaults wizard succeeds"
grep -q '^PTP_DOMAIN=24$' "$site_file" &&
grep -q '^PTP_TRANSPORT=L2$' "$site_file" &&
grep -q '^GRANDMASTER_DISCOVERY=MULTICAST$' "$site_file" &&
grep -q 'PTP Domain \[24\]' "$TEMP/saved-defaults.out" &&
ok "saved site.env defaults" || fail "saved site.env defaults"

site_file="$TEMP/sites/changed-defaults.env"
cp "$FIXTURES/site-valid.env" "$site_file"
wizard_fixture "$FIXTURES/nics.tsv" "$site_file" 4 42 2 2 1 7 1 n > "$TEMP/changed-defaults.out" 2>&1 ||
    fail "changed defaults wizard succeeds"
grep -q '^PTP_DOMAIN=42$' "$site_file" &&
grep -q '^PTP_TRANSPORT=UDPv4$' "$site_file" &&
grep -q '^PTP_DELAY_MECHANISM=P2P$' "$site_file" &&
grep -q '^TRANSPORT_SPECIFIC=7$' "$site_file" &&
grep -q '^# Common PTP network/profile values' "$site_file" &&
ok "user changes site.env defaults" || fail "changed site.env values"

site_file="$TEMP/sites/cancel.env"
cp "$FIXTURES/site-valid.env" "$site_file"
wizard_fixture "$FIXTURES/nics.tsv" "$site_file" 4 "" "" "" "" "" "" n > "$TEMP/cancel.out" 2>&1 ||
    fail "user cancellation exits cleanly"
[[ ! -e $TEMP/run/state.env ]] &&
grep -q 'no PTP process was started' "$TEMP/cancel.out" &&
ok "user cancelling before start" || fail "user cancellation safety"

if (
    export PTPCTL_ROOT="$ROOT"
    # shellcheck source=../lib/ptp_common.sh
    source "$ROOT/lib/ptp_common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/discovery.sh"
    source "$ROOT/lib/runtime.sh"
    PTP_DOMAIN=24
    ptp_pmc_query() {
        printf '%s\n' 'ptpTimescale 1' 'currentUtcOffset invalid' 'currentUtcOffsetValid 1'
    }
    ptp_validate_slave_management /mock/socket /mock/log
) > "$TEMP/invalid-utc.out" 2>&1; then
    fail "invalid UTC offset is rejected"
else
    grep -q 'currentUtcOffset is not numeric' "$TEMP/invalid-utc.out" && ok "invalid UTC offset" || fail "invalid UTC diagnostic"
fi

if PTPCTL_TEST_ALLOW_ROOT=1 run_fixture setup X710-slave > "$TEMP/rollback.out" 2>&1; then
    fail "failed ptp4l setup returns failure"
else
    grep -q 'ptp4l failed to start' "$TEMP/rollback.out" &&
    grep -q 'stopping only processes started by this ptpctl transaction' "$TEMP/rollback.out" &&
    [[ ! -e $TEMP/run/state.env && ! -e $TEMP/run/ptp4l-X710-slave.conf ]] &&
    ok "rollback after failed ptp4l" || fail "rollback after failed ptp4l"
fi

site_file="$TEMP/sites/inventory.env"
cp "$FIXTURES/site-valid.env" "$site_file"
wizard_fixture "$FIXTURES/nics-multiple.tsv" "$site_file" 4 1 "" "" "" "" "" "" n > "$TEMP/inventory-wizard.out" 2>&1 ||
    fail "inventory wizard succeeds"
inventory="$TEMP/state/server_inventory.txt"
grep -q '^Kernel:' "$inventory" &&
grep -q '^Distribution:' "$inventory" &&
grep -q '^linuxptp:.*test-fixture' "$inventory" &&
grep -q 'Interface:.*enp65s0f0' "$inventory" &&
grep -q 'PHC shared:.*YES' "$inventory" &&
grep -q '^Clock services and PTP processes' "$inventory" &&
ok "human-readable live inventory" || fail "hardware inventory contents"

mkdir -p "$TEMP/missing-bin"
for tool in lspci ip ptp4l phc2sys pmc systemctl timedatectl pgrep; do
    ln -s "$TEMP/bin/$tool" "$TEMP/missing-bin/$tool"
done
if env PATH="$TEMP/missing-bin:/usr/bin:/bin" PTPCTL_TEST_MODE=1 \
    PTPCTL_FIXTURE_FILE="$FIXTURES/nics.tsv" PTPCTL_SITE_CONFIG="$FIXTURES/site-valid.env" \
    PTPCTL_STATE_DIR="$TEMP/state" "$ROOT/ptpctl" > "$TEMP/missing-dependency.out" 2>&1; then
    fail "missing dependency is rejected"
else
    grep -q 'Missing dependency: ethtool' "$TEMP/missing-dependency.out" &&
    grep -q 'sudo apt install ethtool' "$TEMP/missing-dependency.out" &&
    ok "missing dependency guidance" || fail "missing dependency guidance"
fi

site_file="$TEMP/sites/created-first-run.env"
wizard_fixture "$FIXTURES/nics.tsv" "$site_file" 4 "" "" "" "" "" "" n > "$TEMP/created-first-run.out" 2>&1 ||
    fail "first-run site.env creation succeeds"
[[ -f $site_file ]] &&
grep -q '^PTP_DOMAIN=0$' "$site_file" &&
grep -q '^PTP_TRANSPORT=L2$' "$site_file" &&
grep -q '^# Site-owned PTP values' "$site_file" &&
ok "wizard creates missing site.env" || fail "first-run site.env creation"
