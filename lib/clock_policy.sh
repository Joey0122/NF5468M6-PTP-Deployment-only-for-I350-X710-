#!/usr/bin/env bash

# The policy matrix is the single source of truth for clock ownership. Runtime
# code must consume these derived values instead of independently deciding
# whether chronyd or phc2sys can touch CLOCK_REALTIME.

ptp_derive_clock_policy() {
    local role=$1 key
    key="$role:${PTP_SLAVE_SYSTEM_CLOCK:-YES}:${NTP_ENABLED:-NO}"
    PTP_SYSTEM_PHC2SYS=NO
    PTP_MASTER_PHC2SYS=NO
    PTP_PHC_OWNER="PTP / ptp4l"

    case "$key" in
        slave:YES:NO)
            PTP_CLOCK_OWNER=PHC2SYS
            PTP_CHRONY_MODE=OFF
            PTP_SYSTEM_PHC2SYS=YES
            PTP_ARCHITECTURE="PTP slave; PTP controls NIC PHC and phc2sys controls CLOCK_REALTIME"
            ;;
        slave:YES:YES)
            PTP_CLOCK_OWNER=PHC2SYS
            PTP_CHRONY_MODE=MONITOR_ONLY
            PTP_SYSTEM_PHC2SYS=YES
            PTP_ARCHITECTURE="PTP slave controls CLOCK_REALTIME; private chronyd -x monitors NTP"
            ;;
        slave:NO:NO)
            PTP_CLOCK_OWNER=UNCHANGED
            PTP_CHRONY_MODE=OFF
            PTP_ARCHITECTURE="PTP slave synchronizes the NIC PHC only; CLOCK_REALTIME remains independent"
            ;;
        slave:NO:YES)
            PTP_CLOCK_OWNER=CHRONYD
            PTP_CHRONY_MODE=DISCIPLINE
            PTP_ARCHITECTURE="PTP slave synchronizes the NIC PHC; private chronyd controls CLOCK_REALTIME"
            ;;
        master:*:YES)
            PTP_CLOCK_OWNER=CHRONYD
            PTP_CHRONY_MODE=DISCIPLINE
            PTP_MASTER_PHC2SYS=YES
            PTP_PHC_OWNER="CLOCK_REALTIME / phc2sys"
            PTP_ARCHITECTURE="NTP-backed PTP Master"
            ;;
        master:*:NO)
            PTP_CLOCK_OWNER=EXISTING_OR_UNCHANGED
            PTP_CHRONY_MODE=OFF
            PTP_MASTER_PHC2SYS=YES
            PTP_PHC_OWNER="CLOCK_REALTIME / phc2sys"
            PTP_ARCHITECTURE="PTP Master using existing synchronized system time or laboratory free-run policy"
            ;;
        *)
            ptp_die "Unsupported PTP/NTP policy combination: $key" || return
            ;;
    esac
    ptp_assert_single_clock_owner
}

ptp_assert_single_clock_owner() {
    local owners=0
    [[ ${PTP_SYSTEM_PHC2SYS:-NO} == YES ]] && ((owners += 1))
    [[ ${PTP_CHRONY_MODE:-OFF} == DISCIPLINE ]] && ((owners += 1))
    (( owners <= 1 )) || {
        ptp_die "Unsafe policy rejected: chronyd and phc2sys would both control CLOCK_REALTIME" || return
    }
    if [[ ${PTP_CHRONY_MODE:-OFF} == MONITOR_ONLY && ${PTP_CLOCK_OWNER:-} != PHC2SYS ]]; then
        ptp_die "Unsafe policy rejected: monitor-only NTP is valid only when PTP owns CLOCK_REALTIME" || return
    fi
}

ptp_clock_owner_display() {
    case "${PTP_CLOCK_OWNER:-unknown}" in
        PHC2SYS) echo "PTP / phc2sys" ;;
        CHRONYD) echo "NTP / chronyd" ;;
        UNCHANGED) echo "unchanged / external to ptpctl" ;;
        EXISTING_OR_UNCHANGED)
            if [[ ${PTP_MASTER_SOURCE_STATUS:-} == synchronized ]]; then
                echo "existing synchronized system-time service"
            else
                echo "unchanged / laboratory free-running"
            fi
            ;;
        *) echo unknown ;;
    esac
}

ptp_ntp_mode_display() {
    case "${PTP_CHRONY_MODE:-OFF}" in
        DISCIPLINE) echo "CLIENT / DISCIPLINE" ;;
        MONITOR_ONLY) echo "MONITOR ONLY (chronyd -x)" ;;
        *) echo "DISABLED" ;;
    esac
}

ptp_policy_matrix_report() {
    cat <<'EOF'
SLAVE + PTP system YES + NTP OFF : CLOCK_REALTIME=phc2sys, PHC=ptp4l
SLAVE + PTP system YES + NTP ON  : CLOCK_REALTIME=phc2sys, NTP=chronyd -x monitor
SLAVE + PTP system NO  + NTP OFF : CLOCK_REALTIME=unchanged, PHC=ptp4l
SLAVE + PTP system NO  + NTP ON  : CLOCK_REALTIME=chronyd, PHC=ptp4l
MASTER + NTP ON                   : CLOCK_REALTIME=chronyd, PHC=phc2sys, PTP=ptp4l
MASTER + NTP OFF                  : existing/lab system time, PHC=phc2sys, PTP=ptp4l
EOF
}
