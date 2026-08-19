#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
TEMP="$(mktemp -d)"
MOCK_TRACE="$TEMP/mock-trace.log"
MOCK_PID_FILE="$TEMP/mock-pids"
MOCK_SERVICE_FILE="$TEMP/active-services"
MOCK_SERVICE_TRACE="$TEMP/service-trace.log"

cleanup() {
    local pid
    if [[ -r $MOCK_PID_FILE ]]; then
        while IFS= read -r pid; do
            [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
        done < "$MOCK_PID_FILE"
    fi
    if [[ ${PTPCTL_KEEP_TEST_TEMP:-0} == 1 ]]; then
        echo "test temp preserved: $TEMP"
    else
        rm -rf "$TEMP"
    fi
}
trap cleanup EXIT
mkdir -p "$TEMP/bin" "$TEMP/logs" "$TEMP/run" "$TEMP/state" "$TEMP/sites"
: > "$MOCK_TRACE"
: > "$MOCK_PID_FILE"
: > "$MOCK_SERVICE_FILE"
: > "$MOCK_SERVICE_TRACE"

for tool in lspci ip ethtool timemaster; do
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
printf 'ptp4l %s\n' "$*" >> "$MOCK_TRACE"
[[ ${MOCK_FAIL_COMPONENT:-} == ptp4l ]] && exit 1
printf '%s\n' "$$" >> "$MOCK_PID_FILE"
exec sleep 300
EOF

cat > "$TEMP/bin/phc2sys" <<'EOF'
#!/usr/bin/env bash
printf 'phc2sys %s\n' "$*" >> "$MOCK_TRACE"
[[ ${MOCK_FAIL_COMPONENT:-} == phc2sys ]] && exit 1
echo "phc2sys[fixture]: CLOCK_REALTIME offset 12 s0 freq +1 delay 2"
printf '%s\n' "$$" >> "$MOCK_PID_FILE"
exec sleep 300
EOF

cat > "$TEMP/bin/chronyd" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" -p "*)
        [[ ${MOCK_CHRONY_CONFIG_FAIL:-0} == 1 ]] && { echo "bad chrony config"; exit 1; }
        echo "private chrony config valid"
        exit 0
        ;;
    *" -Q "*)
        [[ ${MOCK_NTP_PROBE_FAIL:-0} == 1 ]] && { echo "No suitable source"; exit 1; }
        echo "2026-01-01T00:00:00Z System clock wrong by 0.001 seconds"
        exit 0
        ;;
esac
printf 'chronyd %s\n' "$*" >> "$MOCK_TRACE"
[[ ${MOCK_FAIL_COMPONENT:-} == chronyd ]] && exit 1
printf '%s\n' "$$" >> "$MOCK_PID_FILE"
exec sleep 300
EOF

cat > "$TEMP/bin/chronyc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *sources*)
        echo "MS Name/IP address         Stratum Poll Reach LastRx Last sample"
        echo "^* 192.0.2.10                    1   6   377     8   +15us[ +10us] +/- 2ms"
        ;;
    *tracking*)
        cat <<'TRACKING'
Reference ID    : C000020A (192.0.2.10)
Stratum         : 2
System time     : 0.000015 seconds fast of NTP time
Last offset     : +0.000010 seconds
Frequency       : 1.250 ppm fast
Leap status     : Normal
TRACKING
        ;;
    *waitsync*) echo "try: 1, refid: C000020A, correction: 0.000015, skew: 0.100" ;;
    *) exit 1 ;;
esac
EOF

cat > "$TEMP/bin/pmc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"GET PORT_DATA_SET"*) echo "portState ${MOCK_PTP_STATE:-SLAVE}" ;;
    *"GET CURRENT_DATA_SET"*)
        echo "offsetFromMaster 42"
        echo "meanPathDelay 17"
        ;;
    *"GET TIME_PROPERTIES_DATA_SET"*)
        echo "currentUtcOffset 37"
        echo "currentUtcOffsetValid 1"
        echo "ptpTimescale 1"
        ;;
    *"GET TIME_STATUS_NP"*) echo "master_offset 42" ;;
    *) exit 1 ;;
esac
EOF

cat > "$TEMP/bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ ${MOCK_NAME_LOOKUP_FAIL:-0} == 1 ]] && exit 2
echo "192.0.2.10 STREAM $2"
EOF

cat > "$TEMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
command_name=${1:-}
shift || true
case "$command_name" in
    is-active)
        [[ ${1:-} == --quiet ]] && shift
        service=${1:-}
        if grep -Fxq "$service" "$MOCK_SERVICE_FILE"; then
            [[ ${1:-} == --quiet ]] || echo active
            exit 0
        fi
        [[ ${1:-} == --quiet ]] || echo inactive
        exit 3
        ;;
    stop)
        printf 'stop %s\n' "$1" >> "$MOCK_SERVICE_TRACE"
        grep -Fxv "$1" "$MOCK_SERVICE_FILE" > "$MOCK_SERVICE_FILE.tmp" || true
        mv "$MOCK_SERVICE_FILE.tmp" "$MOCK_SERVICE_FILE"
        ;;
    start)
        printf 'start %s\n' "$1" >> "$MOCK_SERVICE_TRACE"
        grep -Fxq "$1" "$MOCK_SERVICE_FILE" || printf '%s\n' "$1" >> "$MOCK_SERVICE_FILE"
        ;;
    *) exit 0 ;;
esac
EOF

cat > "$TEMP/bin/timedatectl" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == show ]] && echo "${MOCK_NTP_SYNCHRONIZED:-no}"
exit 0
EOF

cat > "$TEMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

chmod +x "$TEMP/bin"/*

run_fixture() {
    env PATH="$TEMP/bin:$PATH" \
        MOCK_TRACE="$MOCK_TRACE" MOCK_PID_FILE="$MOCK_PID_FILE" \
        MOCK_SERVICE_FILE="$MOCK_SERVICE_FILE" MOCK_SERVICE_TRACE="$MOCK_SERVICE_TRACE" \
        MOCK_FAIL_COMPONENT="${MOCK_FAIL_COMPONENT:-}" \
        MOCK_NTP_PROBE_FAIL="${MOCK_NTP_PROBE_FAIL:-0}" \
        MOCK_CHRONY_CONFIG_FAIL="${MOCK_CHRONY_CONFIG_FAIL:-0}" \
        MOCK_NAME_LOOKUP_FAIL="${MOCK_NAME_LOOKUP_FAIL:-0}" \
        MOCK_PTP_STATE="${MOCK_PTP_STATE:-SLAVE}" \
        MOCK_NTP_SYNCHRONIZED="${MOCK_NTP_SYNCHRONIZED:-no}" \
        PTPCTL_TEST_MODE=1 PTPCTL_TEST_RUNTIME_MOCK=1 \
        PTPCTL_FIXTURE_FILE="${PTPCTL_FIXTURE_FILE:-$FIXTURES/nics.tsv}" \
        PTPCTL_SITE_CONFIG="${PTPCTL_SITE_CONFIG:-$FIXTURES/site-valid.env}" \
        PTPCTL_LOG_DIR="$TEMP/logs" PTPCTL_RUN_DIR="$TEMP/run" PTPCTL_STATE_DIR="$TEMP/state" \
        PTPCTL_TEST_ALLOW_ROOT="${PTPCTL_TEST_ALLOW_ROOT:-0}" \
        PTPCTL_TEST_CLOCK_CONFLICT="${PTPCTL_TEST_CLOCK_CONFLICT:-0}" \
        PTPCTL_TEST_CLOCK_POLICY_LIVE="${PTPCTL_TEST_CLOCK_POLICY_LIVE:-0}" \
        PTP_SETUP_MAY_STOP_SERVICES="${PTP_SETUP_MAY_STOP_SERVICES:-0}" \
        PTPCTL_ASSUME_YES="${PTPCTL_ASSUME_YES:-0}" \
        "$ROOT/ptpctl" "$@"
}

wizard_fixture() {
    local fixture=$1 site_file=$2
    shift 2
    printf '%s\n' "$@" | PTPCTL_FIXTURE_FILE="$fixture" PTPCTL_SITE_CONFIG="$site_file" \
        PTPCTL_TEST_ALLOW_ROOT=1 run_fixture
}

clear_runtime() {
    if [[ -r $TEMP/run/state.env ]]; then
        PTPCTL_TEST_ALLOW_ROOT=1 run_fixture stop >/dev/null 2>&1 || true
    fi
    : > "$MOCK_TRACE"
    : > "$MOCK_PID_FILE"
    : > "$MOCK_SERVICE_FILE"
    : > "$MOCK_SERVICE_TRACE"
}

test_number=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $*"; }
fail() { test_number=$((test_number + 1)); echo "not ok $test_number - $*"; exit 1; }

echo "TAP version 13"

bash -n "$ROOT/ptpctl" "$ROOT"/lib/*.sh "$ROOT/tests/run.sh" && ok "bash syntax" || fail "bash syntax"

combo_test() {
    local mode=$1 ptp_system=$2 ntp=$3 expected_owner=$4 expected_ntp=$5 output
    local -a args=(setup "$mode" --dry-run)
    [[ $mode == *-slave ]] && args+=("--ptp-system-clock=${ptp_system,,}")
    [[ $ntp == YES ]] && args+=(--ntp-server=192.0.2.10)
    [[ $ntp == NO ]] && args+=(--ntp=off)
    output="$TEMP/combo-$mode-$ptp_system-$ntp.out"
    if run_fixture "${args[@]}" > "$output" 2>&1 &&
        grep -q "Mode:.*$mode" "$output" &&
        grep -q "CLOCK_REALTIME:.*$expected_owner" "$output" &&
        grep -q "NTP mode:.*$expected_ntp" "$output"; then
        if [[ $mode == *-slave && $ptp_system == NO ]]; then
            grep -q 'PHC-only mode: do not start phc2sys' "$output" || fail "$mode PHC-only plan"
        elif [[ $mode == *-slave ]]; then
            grep -q 'phc2sys -a -r -f' "$output" || fail "$mode system-clock plan"
        fi
        ok "$mode / PTP-system=$ptp_system / NTP=$ntp"
    else
        fail "$mode / PTP-system=$ptp_system / NTP=$ntp"
    fi
}

for family in I350 X710; do
    combo_test "$family-slave" YES NO 'PTP / phc2sys' DISABLED
    combo_test "$family-slave" YES YES 'PTP / phc2sys' 'MONITOR ONLY'
    combo_test "$family-slave" NO NO 'unchanged / external' DISABLED
    combo_test "$family-slave" NO YES 'NTP / chronyd' 'CLIENT / DISCIPLINE'
done
combo_test I350-master YES YES 'NTP / chronyd' 'CLIENT / DISCIPLINE'
combo_test I350-master YES NO 'unchanged / laboratory' DISABLED
combo_test X710-master YES YES 'NTP / chronyd' 'CLIENT / DISCIPLINE'
combo_test X710-master YES NO 'unchanged / laboratory' DISABLED

if (
    export PTPCTL_ROOT="$ROOT"
    source "$ROOT/lib/ptp_common.sh"
    source "$ROOT/lib/clock_policy.sh"
    [[ $(ptp_policy_matrix_report | wc -l) == 6 ]]
); then ok "explicit six-row policy matrix"; else fail "policy matrix"; fi

if (
    export PTPCTL_ROOT="$ROOT"
    source "$ROOT/lib/ptp_common.sh"
    source "$ROOT/lib/clock_policy.sh"
    PTP_SYSTEM_PHC2SYS=YES PTP_CHRONY_MODE=DISCIPLINE PTP_CLOCK_OWNER=CHRONYD
    ! ptp_assert_single_clock_owner
); then ok "chronyd plus system-target phc2sys conflict rejection"; else fail "single-owner invariant"; fi

grep -q 'chronyd -d -x -f' "$TEMP/combo-I350-slave-YES-YES.out" &&
! grep -q 'chronyd -d -x' "$TEMP/combo-I350-slave-NO-YES.out" &&
! grep -q '^makestep' "$TEMP/combo-I350-slave-YES-YES.out" &&
grep -q '^makestep' "$TEMP/combo-I350-slave-NO-YES.out" &&
ok "monitor-only plan always uses chronyd -x" || fail "monitor-only -x enforcement"

grep -q 'continue explicit CLOCK_REALTIME -> NIC PHC' "$TEMP/combo-X710-master-YES-YES.out" &&
! grep -q 'phc2sys -a -r -r' "$TEMP/combo-X710-master-YES-YES.out" &&
ok "master phc2sys has explicit PHC-only target direction" || fail "master PHC direction"

grep -q 'Interface:.*mocki350' "$TEMP/combo-I350-slave-YES-NO.out" &&
grep -q 'Driver:.*igb' "$TEMP/combo-I350-slave-YES-NO.out" &&
grep -q 'PHC:.*\/dev\/ptp4' "$TEMP/combo-I350-slave-YES-NO.out" &&
ok "I350 live interface/driver/PHC discovery" || fail "I350 discovery"

grep -q 'Interface:.*mockx710' "$TEMP/combo-X710-slave-YES-NO.out" &&
grep -q 'Driver:.*i40e' "$TEMP/combo-X710-slave-YES-NO.out" &&
grep -q 'PHC:.*\/dev\/ptp7' "$TEMP/combo-X710-slave-YES-NO.out" &&
ok "X710 live interface/driver/PHC discovery" || fail "X710 discovery"

clear_runtime
run_fixture setup X710-slave --dry-run --ptp-system-clock=no --ntp-server=192.0.2.10 > "$TEMP/dry-safe.out" 2>&1 || fail "dry-run execution"
[[ ! -s $MOCK_TRACE && ! -e $TEMP/run/state.env ]] &&
ok "dry-run starts no service and commits no state" || fail "dry-run safety"

if PTPCTL_FIXTURE_FILE="$FIXTURES/nics-invalid.tsv" run_fixture setup X710-slave --dry-run > "$TEMP/invalid-hw.out" 2>&1; then
    fail "invalid hardware rejected"
else
    grep -q 'No hardware-valid X710 port' "$TEMP/invalid-hw.out" && ok "invalid hardware rejected" || fail "invalid hardware diagnostic"
fi

if PTPCTL_SITE_CONFIG="$ROOT/configs/site.env.example" run_fixture setup I350-master --dry-run > "$TEMP/todo.out" 2>&1; then
    fail "TODO configuration rejected"
else
    grep -q 'PTP_DOMAIN is TODO' "$TEMP/todo.out" && ok "TODO configuration rejected" || fail "TODO diagnostic"
fi

for reject_spec in \
    "nics-empty.tsv:3:No Intel X710 NIC port" \
    "nics-wrong-driver.tsv:4:expected_driver_i40e" \
    "nics-missing-timestamp.tsv:2:no_hardware_tx" \
    "nics-missing-phc.tsv:4:no_valid_phc" \
    "nics-link-down.tsv:4:has no carrier"; do
    IFS=: read -r fixture selection diagnostic <<<"$reject_spec"
    site_file="$TEMP/sites/reject-${fixture%.tsv}.env"
    cp "$FIXTURES/site-valid.env" "$site_file"
    if wizard_fixture "$FIXTURES/$fixture" "$site_file" "$selection" > "$TEMP/$fixture.out" 2>&1; then
        fail "$fixture rejection"
    else
        grep -q "$diagnostic" "$TEMP/$fixture.out" && ok "$fixture rejection" || fail "$fixture diagnostic"
    fi
done

site_file="$TEMP/sites/multiple.env"
cp "$FIXTURES/site-valid.env" "$site_file"
wizard_fixture "$FIXTURES/nics-multiple.tsv" "$site_file" \
    4 2 1 1 "" "" "" "" "" "" n > "$TEMP/multiple.out" 2>&1 || fail "multiple-port wizard"
grep -q 'Found 2 X710 ports' "$TEMP/multiple.out" &&
grep -q 'Interface:.*enp65s0f1' "$TEMP/multiple.out" &&
grep -q 'PHC shared:.*YES' "$TEMP/multiple.out" &&
ok "multiple-port selection preserves live PHC discovery" || fail "multiple-port selection"

for mode_spec in "1:I350-master:master" "2:I350-slave:slave" "3:X710-master:master" "4:X710-slave:slave"; do
    IFS=: read -r menu_mode mode_name role <<<"$mode_spec"
    site_file="$TEMP/sites/wizard-$mode_name.env"
    cp "$FIXTURES/site-valid.env" "$site_file"
    if [[ $role == master ]]; then
        wizard_fixture "$FIXTURES/nics.tsv" "$site_file" \
            "$menu_mode" 1 "" "" "" "" "" "" "" "" n > "$TEMP/wizard-$mode_name.out" 2>&1 || fail "$mode_name wizard"
    else
        wizard_fixture "$FIXTURES/nics.tsv" "$site_file" \
            "$menu_mode" 1 1 "" "" "" "" "" "" n > "$TEMP/wizard-$mode_name.out" 2>&1 || fail "$mode_name wizard"
    fi
    grep -q "Mode:.*$mode_name" "$TEMP/wizard-$mode_name.out" &&
    grep -q 'no PTP or NTP process was started' "$TEMP/wizard-$mode_name.out" &&
    ok "$mode_name interactive wizard" || fail "$mode_name wizard output"
done

site_file="$TEMP/sites/cancel.env"
cp "$FIXTURES/site-valid.env" "$site_file"
wizard_fixture "$FIXTURES/nics.tsv" "$site_file" \
    2 1 1 "" "" "" "" "" "" n > "$TEMP/cancel.out" 2>&1 || fail "wizard cancellation"
[[ ! -e $TEMP/run/state.env ]] && ! grep -q '^ptp4l ' "$MOCK_TRACE" &&
grep -q 'no PTP or NTP process was started' "$TEMP/cancel.out" &&
ok "user cancellation starts nothing" || fail "user cancellation safety"

site_file="$TEMP/sites/saved-defaults.env"
cp "$FIXTURES/site-valid.env" "$site_file"
sed -i 's/^NTP_ENABLED=.*/NTP_ENABLED=YES/; s/^NTP_SERVERS=.*/NTP_SERVERS=ntp-a.test ntp-b.test/; s/^PTP_SLAVE_SYSTEM_CLOCK=.*/PTP_SLAVE_SYSTEM_CLOCK=NO/' "$site_file"
wizard_fixture "$FIXTURES/nics.tsv" "$site_file" \
    4 "" "" "" "" "" "" "" "" "" n > "$TEMP/saved-defaults.out" 2>&1 || fail "saved defaults wizard"
grep -Fq 'Selection [2]' "$TEMP/saved-defaults.out" &&
grep -Fq 'NTP server hostname/IP [ntp-a.test ntp-b.test]' "$TEMP/saved-defaults.out" &&
grep -q '^PTP_SLAVE_SYSTEM_CLOCK=NO$' "$site_file" &&
ok "saved NTP and slave clock defaults" || fail "saved defaults"

run_fixture setup X710-slave --dry-run --ptp-system-clock=no \
    --ntp-server=ntp-a.test --ntp-server=192.0.2.20 > "$TEMP/multi-ntp.out" 2>&1 || fail "multiple NTP dry-run"
grep -q '^server ntp-a.test iburst' "$TEMP/multi-ntp.out" &&
grep -q '^server 192.0.2.20 iburst' "$TEMP/multi-ntp.out" &&
ok "multiple NTP servers in private config" || fail "multiple NTP servers"

if run_fixture setup X710-slave --dry-run --ntp-server='bad/value' > "$TEMP/invalid-ntp.out" 2>&1; then
    fail "invalid NTP address rejected"
else
    grep -q 'Invalid NTP server' "$TEMP/invalid-ntp.out" && ok "invalid NTP address/config rejected" || fail "invalid NTP diagnostic"
fi

clear_runtime
if MOCK_CHRONY_CONFIG_FAIL=1 PTPCTL_TEST_ALLOW_ROOT=1 \
    run_fixture setup X710-slave --ptp-system-clock=no --ntp-server=192.0.2.10 > "$TEMP/invalid-chrony-config.out" 2>&1; then
    fail "invalid generated chrony config rejected"
else
    grep -q 'Private chrony configuration validation failed' "$TEMP/invalid-chrony-config.out" &&
    [[ ! -s $MOCK_TRACE && ! -e $TEMP/run/state.env ]] &&
    ok "invalid chrony config is rejected before startup" || fail "chrony config validation gate"
fi

if (
    export PTPCTL_ROOT="$ROOT"
    source "$ROOT/lib/ptp_common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/discovery.sh"
    source "$ROOT/lib/clock_policy.sh"
    source "$ROOT/lib/ntp.sh"
    source "$ROOT/lib/runtime.sh"
    PTP_DOMAIN=24
    ptp_pmc_query() { printf '%s\n' 'ptpTimescale 1' 'currentUtcOffset invalid' 'currentUtcOffsetValid 1'; }
    ptp_validate_slave_management /mock/socket /mock/log
) > "$TEMP/invalid-utc.out" 2>&1; then
    fail "invalid UTC offset rejected"
else
    grep -q 'currentUtcOffset is not numeric' "$TEMP/invalid-utc.out" && ok "invalid UTC offset rejected" || fail "invalid UTC diagnostic"
fi

clear_runtime
if MOCK_NTP_PROBE_FAIL=1 PTPCTL_TEST_ALLOW_ROOT=1 MOCK_PTP_STATE=MASTER \
    run_fixture setup I350-master --ntp-server=192.0.2.10 > "$TEMP/ntp-fail-master.out" 2>&1; then
    fail "NTP failure blocks master"
else
    ! grep -q '^phc2sys ' "$MOCK_TRACE" && ! grep -q '^ptp4l ' "$MOCK_TRACE" &&
    grep -q 'NTP reachability validation failed before startup' "$TEMP/ntp-fail-master.out" &&
    ok "NTP failure prevents NTP-backed master startup" || fail "NTP-backed master failure ordering"
fi

clear_runtime
if MOCK_FAIL_COMPONENT=ptp4l PTPCTL_TEST_ALLOW_ROOT=1 run_fixture setup I350-slave > "$TEMP/ptp-fail-slave.out" 2>&1; then
    fail "PTP failure runtime"
else
    grep -q '^ptp4l ' "$MOCK_TRACE" && ! grep -q '^phc2sys ' "$MOCK_TRACE" &&
    grep -q 'phc2sys was not started\|ptp4l failed to start' "$TEMP/ptp-fail-slave.out" &&
    ok "PTP failure prevents slave phc2sys startup" || fail "PTP failure ordering"
fi

clear_runtime
printf '%s\n' chronyd.service > "$MOCK_SERVICE_FILE"
if run_fixture setup I350-slave --dry-run > "$TEMP/conflict-reject.out" 2>&1; then
    fail "advanced conflict rejection"
else
    grep -q 'temporary stop' "$TEMP/conflict-reject.out" &&
    grep -q 'interactive wizard' "$TEMP/conflict-reject.out" &&
    ok "existing clock-service conflict requires approval" || fail "clock-service conflict diagnostic"
fi

clear_runtime
printf '%s\n' chronyd.service > "$MOCK_SERVICE_FILE"
if MOCK_FAIL_COMPONENT=ptp4l PTPCTL_TEST_ALLOW_ROOT=1 PTP_SETUP_MAY_STOP_SERVICES=1 PTPCTL_ASSUME_YES=1 \
    run_fixture setup X710-slave > "$TEMP/service-rollback.out" 2>&1; then
    fail "service rollback setup should fail"
else
    grep -q '^stop chronyd.service$' "$MOCK_SERVICE_TRACE" &&
    grep -q '^start chronyd.service$' "$MOCK_SERVICE_TRACE" &&
    grep -Fxq chronyd.service "$MOCK_SERVICE_FILE" &&
    ok "approved temporary service stop is restored on rollback" || fail "service rollback restoration"
fi
[[ ! -e $TEMP/run/state.env && ! -e $TEMP/run/ptp4l-X710-slave.conf ]] &&
ok "rollback removes transient runtime state and preserves logs" || fail "rollback artifacts"

clear_runtime
PTPCTL_TEST_ALLOW_ROOT=1 run_fixture setup I350-slave --ntp-server=192.0.2.10 > "$TEMP/runtime-monitor.out" 2>&1 || fail "monitor runtime setup"
grep -q '^chronyd -d -x -f ' "$MOCK_TRACE" &&
grep -q '^phc2sys -a -r ' "$MOCK_TRACE" &&
grep -q '^CLOCK_OWNER=PHC2SYS$' "$TEMP/run/state.env" &&
grep -q '^CHRONY_MODE=MONITOR_ONLY$' "$TEMP/run/state.env" &&
ok "slave PTP owner plus NTP monitor runtime" || fail "monitor runtime architecture"

run_fixture status > "$TEMP/combined-status.out" 2>&1 || fail "combined status command"
grep -q '^PTP$' "$TEMP/combined-status.out" && grep -q '^NTP$' "$TEMP/combined-status.out" &&
grep -q '^Clock Control$' "$TEMP/combined-status.out" &&
grep -q 'Reachability:.*OK' "$TEMP/combined-status.out" &&
grep -q 'Reference ID:.*C000020A' "$TEMP/combined-status.out" &&
grep -q 'CLOCK_REALTIME:.*PTP / phc2sys' "$TEMP/combined-status.out" &&
grep -q 'NTP:.*MONITOR ONLY' "$TEMP/combined-status.out" &&
grep -q 'Conflict:.*NONE' "$TEMP/combined-status.out" &&
ok "combined PTP/NTP status and ownership" || fail "combined status output"

compgen -G "$TEMP/logs/chronyd-I350-slave-*" >/dev/null &&
compgen -G "$TEMP/logs/ntp-status-I350-slave-*" >/dev/null &&
compgen -G "$TEMP/logs/setup-I350-slave-*" >/dev/null &&
ok "dedicated NTP and combined setup logs" || fail "NTP logs"

PTPCTL_TEST_ALLOW_ROOT=1 run_fixture stop > "$TEMP/stop.out" 2>&1 || fail "stop monitor runtime"
[[ ! -e $TEMP/run/state.env && ! -e $TEMP/run/chrony.conf ]] &&
ok "stop removes only private runtime state" || fail "stop runtime cleanup"

clear_runtime
PTPCTL_TEST_ALLOW_ROOT=1 run_fixture setup X710-slave --ptp-system-clock=no --ntp-server=192.0.2.10 > "$TEMP/runtime-ntp-discipline.out" 2>&1 || fail "NTP discipline runtime"
grep -q '^chronyd -d -f ' "$MOCK_TRACE" && ! grep -q '^chronyd -d -x ' "$MOCK_TRACE" &&
! grep -q '^phc2sys ' "$MOCK_TRACE" && grep -q '^CLOCK_OWNER=CHRONYD$' "$TEMP/run/state.env" &&
ok "slave PHC-only plus NTP discipline runtime" || fail "NTP discipline runtime architecture"
PTPCTL_TEST_ALLOW_ROOT=1 run_fixture stop >/dev/null 2>&1

clear_runtime
MOCK_PTP_STATE=MASTER PTPCTL_TEST_ALLOW_ROOT=1 run_fixture setup I350-master --ntp-server=192.0.2.10 > "$TEMP/runtime-master-ntp.out" 2>&1 || fail "NTP-backed master runtime"
chrony_line=$(grep -n '^chronyd -d -f ' "$MOCK_TRACE" | cut -d: -f1)
phc_line=$(grep -n '^phc2sys -s CLOCK_REALTIME' "$MOCK_TRACE" | cut -d: -f1)
ptp_line=$(grep -n '^ptp4l ' "$MOCK_TRACE" | cut -d: -f1)
[[ $chrony_line -lt $phc_line && $phc_line -lt $ptp_line ]] &&
grep -q 'RESULT: READY — NTP-BACKED PTP MASTER' "$TEMP/runtime-master-ntp.out" &&
ok "NTP-backed master synchronizes NTP then PHC then advertises PTP" || fail "NTP-backed master ordering"
PTPCTL_TEST_ALLOW_ROOT=1 run_fixture stop >/dev/null 2>&1

clear_runtime
MOCK_PTP_STATE=MASTER PTPCTL_TEST_ALLOW_ROOT=1 run_fixture setup X710-master --ntp=off > "$TEMP/runtime-master-lab.out" 2>&1 || fail "lab master runtime"
! grep -q '^chronyd ' "$MOCK_TRACE" && grep -q '^phc2sys -s CLOCK_REALTIME' "$MOCK_TRACE" &&
grep -q 'MASTER' "$TEMP/runtime-master-lab.out" &&
ok "laboratory free-running master remains supported" || fail "lab master runtime"
PTPCTL_TEST_ALLOW_ROOT=1 run_fixture stop >/dev/null 2>&1

clear_runtime
if MOCK_FAIL_COMPONENT=ptp4l PTPCTL_TEST_ALLOW_ROOT=1 run_fixture setup X710-slave --ntp-server=192.0.2.10 > "$TEMP/ntp-rollback.out" 2>&1; then
    fail "PTP failure after NTP should rollback"
else
    live_mock=0
    while IFS= read -r pid; do kill -0 "$pid" 2>/dev/null && live_mock=1 || true; done < "$MOCK_PID_FILE"
    [[ $live_mock == 0 && ! -e $TEMP/run/state.env ]] &&
    ok "PTP failure rolls back private monitor chronyd" || fail "private chronyd rollback"
fi

site_file="$TEMP/sites/first-run.env"
wizard_fixture "$FIXTURES/nics.tsv" "$site_file" \
    4 2 1 0 1 1 1 0 1 n > "$TEMP/first-run.out" 2>&1 || fail "first-run wizard"
grep -q '^NTP_ENABLED=NO$' "$site_file" && grep -q '^PTP_SLAVE_SYSTEM_CLOCK=NO$' "$site_file" &&
! grep -Eq '^(INTERFACE|PCI|PHC|DRIVER)=' "$site_file" &&
ok "first run persists only site-owned PTP/NTP choices" || fail "first-run persistence"

site_file="$TEMP/sites/inventory.env"
cp "$FIXTURES/site-valid.env" "$site_file"
wizard_fixture "$FIXTURES/nics-multiple.tsv" "$site_file" \
    4 1 1 1 "" "" "" "" "" "" n > "$TEMP/inventory.out" 2>&1 || fail "inventory wizard"
inventory="$TEMP/state/server_inventory.txt"
grep -q '^Kernel:' "$inventory" && grep -q '^linuxptp:.*test-fixture' "$inventory" &&
grep -q 'PHC shared:.*YES' "$inventory" &&
ok "human-readable live hardware inventory" || fail "inventory contents"

run_fixture doctor > "$TEMP/doctor.out" 2>&1 || true
grep -q 'timemaster:.*available' "$TEMP/doctor.out" &&
ok "optional linuxptp timemaster detection" || fail "timemaster detection"

mkdir -p "$TEMP/missing-bin"
for tool in bash dirname uname lspci ip ethtool ptp4l phc2sys pmc systemctl timedatectl setsid flock pgrep; do
    if [[ -x $TEMP/bin/$tool ]]; then
        command_path="$TEMP/bin/$tool"
    else
        command_path=$(command -v "$tool")
    fi
    ln -s "$command_path" "$TEMP/missing-bin/$tool"
done
if env PATH="$TEMP/missing-bin" PTPCTL_TEST_MODE=1 PTPCTL_FIXTURE_FILE="$FIXTURES/nics.tsv" \
    PTPCTL_SITE_CONFIG="$FIXTURES/site-valid.env" PTPCTL_LOG_DIR="$TEMP/logs" PTPCTL_RUN_DIR="$TEMP/run" \
    "$ROOT/ptpctl" setup X710-slave --dry-run --ntp-server=192.0.2.10 > "$TEMP/missing-chrony.out" 2>&1; then
    fail "missing chrony dependency rejected"
else
    grep -q 'Missing dependency: chronyd' "$TEMP/missing-chrony.out" &&
    grep -q 'sudo apt install chrony' "$TEMP/missing-chrony.out" &&
    ok "missing chrony dependency guidance" || fail "chrony dependency diagnostic"
fi

echo "1..$test_number"
