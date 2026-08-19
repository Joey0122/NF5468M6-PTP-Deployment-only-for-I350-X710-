#!/usr/bin/env bash

# Shared primitives for ptpctl. This file is sourced by the CLI and tests.

PTPCTL_ROOT="${PTPCTL_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
PTP_SYS_ROOT="${PTPCTL_SYS_ROOT:-/sys}"
PTP_DEV_ROOT="${PTPCTL_DEV_ROOT:-/dev}"
PTP_RUN_DIR="${PTPCTL_RUN_DIR:-$PTPCTL_ROOT/run}"
PTP_LOG_DIR="${PTPCTL_LOG_DIR:-$PTPCTL_ROOT/logs}"
PTP_STATE_DIR="${PTPCTL_STATE_DIR:-$PTPCTL_ROOT/state}"

ptp_info() { printf '%s\n' "$*"; }
ptp_ok() { printf '[OK] %s\n' "$*"; }
ptp_warn() { printf '[WARN] %s\n' "$*" >&2; }
ptp_error() { printf '[ERROR] %s\n' "$*" >&2; }
ptp_die() { ptp_error "$*"; return 1; }

ptp_is_todo() {
    [[ -z ${1:-} || ${1:-} == TODO || ${1:-} == TODO:* ]]
}

ptp_dependency_package() {
    case "$1" in
        lspci) echo pciutils ;;
        ip) echo iproute2 ;;
        ethtool) echo ethtool ;;
        ptp4l|phc2sys|pmc|timemaster) echo linuxptp ;;
        chronyd|chronyc) echo chrony ;;
        getent) echo libc-bin ;;
        systemctl|timedatectl) echo systemd ;;
        setsid|flock) echo util-linux ;;
        pgrep) echo procps ;;
        *) echo "$1" ;;
    esac
}

ptp_require_commands() {
    local command_name package missing=0
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            package="$(ptp_dependency_package "$command_name")"
            ptp_error "Missing dependency: $command_name"
            printf 'Suggested command:\n  sudo apt install %s\n' "$package" >&2
            missing=1
        fi
    done
    (( missing == 0 ))
}

ptp_require_linux() {
    local kernel release
    kernel="$(uname -s 2>/dev/null || true)"
    [[ $kernel == Linux ]] || ptp_die "ptpctl requires native Linux (detected: ${kernel:-unknown})" || return
    release="$(uname -r 2>/dev/null || true)"
    if [[ ${PTPCTL_TEST_MODE:-0} != 1 && ${release,,} == *microsoft* ]]; then
        ptp_die "WSL is not supported; run ptpctl on the native Linux NF5468M6 host"
    fi
}

ptp_prompt_read() {
    local prompt=$1 variable=$2 _ptp_prompt_value
    printf '%s' "$prompt"
    IFS= read -r _ptp_prompt_value || return 1
    printf -v "$variable" '%s' "$_ptp_prompt_value"
}

ptp_require_root() {
    if [[ ${PTPCTL_TEST_MODE:-0} == 1 && ${PTPCTL_TEST_ALLOW_ROOT:-0} == 1 ]]; then
        return 0
    fi
    [[ ${EUID:-$(id -u)} -eq 0 ]] || ptp_die "This operation requires root; rerun with sudo"
}

ptp_iface_path() { printf '%s/class/net/%s\n' "$PTP_SYS_ROOT" "$1"; }

ptp_iface_exists() {
    [[ -d "$(ptp_iface_path "$1")" ]]
}

ptp_iface_bus() {
    basename "$(readlink -f "$(ptp_iface_path "$1")/device/subsystem" 2>/dev/null)" 2>/dev/null || true
}

ptp_iface_is_physical_pci_ethernet() {
    local path
    path="$(ptp_iface_path "$1")"
    [[ -d "$path/device" && -r "$path/type" ]] || return 1
    [[ "$(< "$path/type")" == 1 ]] || return 1
    [[ $(ptp_iface_bus "$1") == pci ]]
}

ptp_iface_driver() {
    ethtool -i "$1" 2>/dev/null | awk -F': ' '/^driver:/ {print $2; exit}'
}

ptp_iface_firmware() {
    ethtool -i "$1" 2>/dev/null | awk -F': ' '/^firmware-version:/ {print $2; exit}'
}

ptp_timestamp_output() {
    ethtool -T "$1" 2>&1
}

ptp_phc_index_from_output() {
    awk -F': ' '/^(PTP Hardware Clock|Hardware timestamp provider index):/ {print $2; exit}' <<<"$1"
}

ptp_iface_has_timestamp_capability() {
    local output=$1 capability=$2
    grep -Eq "^[[:space:]]*$capability[[:space:]]*$" <<<"$output"
}

ptp_is_phc_device() {
    [[ -c "$1" ]] || [[ ${PTPCTL_TEST_MODE:-0} == 1 && -e "$1" ]]
}

ptp_phc_for_iface() {
    local output index
    output="$(ptp_timestamp_output "$1")" || return 1
    index="$(ptp_phc_index_from_output "$output")"
    [[ $index =~ ^[0-9]+$ ]] || return 1
    ptp_is_phc_device "$PTP_DEV_ROOT/ptp$index" || return 1
    printf '/dev/ptp%s\n' "$index"
}

ptp_phc_sysfs_for_index() {
    readlink -f "$PTP_SYS_ROOT/class/ptp/ptp$1" 2>/dev/null || true
}

ptp_carrier_state() {
    local path
    path="$(ptp_iface_path "$1")/carrier"
    if [[ -r $path ]]; then
        cat "$path" 2>/dev/null || echo unknown
    else
        echo unknown
    fi
}

ptp_operstate() {
    cat "$(ptp_iface_path "$1")/operstate" 2>/dev/null || echo unknown
}

ptp_mac_address() {
    cat "$(ptp_iface_path "$1")/address" 2>/dev/null || echo unknown
}

ptp_validate_domain() {
    [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 <= 255 ))
}

ptp_validate_transport() {
    [[ $1 == L2 || $1 == UDPv4 || $1 == UDPv6 ]]
}

ptp_validate_delay() {
    [[ $1 == E2E || $1 == P2P || $1 == Auto ]]
}

ptp_process_lines() {
    local name=$1
    pgrep -a -x "$name" 2>/dev/null || true
}

ptp_service_active() {
    systemctl is-active --quiet "$1" >/dev/null 2>&1
}

ptp_clock_service_report() {
    local service active
    printf '%-27s %s\n' "Service" "State"
    for service in chronyd.service chrony.service systemd-timesyncd.service ntp.service ntpd.service ntpsec.service openntpd.service; do
        active="$(systemctl is-active "$service" 2>/dev/null || true)"
        printf '%-27s %s\n' "$service" "${active:-unavailable}"
    done
    for service in chronyd ntpd ntpsec openntpd systemd-timesyncd ptp4l phc2sys; do
        if pgrep -x "$service" >/dev/null 2>&1; then
            printf '%-27s %s\n' "process:$service" "running"
            ptp_process_lines "$service" | sed 's/^/  /'
        fi
    done
}

ptp_other_system_discipliner() {
    pgrep -x 'chronyd|ntpd|ntpsec|openntpd|systemd-timesyncd' >/dev/null 2>&1 && return 0
    ptp_service_active chronyd.service && return 0
    ptp_service_active chrony.service && return 0
    ptp_service_active systemd-timesyncd.service && return 0
    ptp_service_active ntp.service && return 0
    ptp_service_active ntpd.service && return 0
    ptp_service_active ntpsec.service && return 0
    ptp_service_active openntpd.service && return 0
    return 1
}

ptp_active_clock_service_units() {
    local service
    for service in chronyd.service chrony.service; do
        if ptp_service_active "$service"; then printf '%s\n' "$service"; break; fi
    done
    ptp_service_active systemd-timesyncd.service && printf '%s\n' systemd-timesyncd.service
    for service in ntp.service ntpd.service ntpsec.service openntpd.service; do
        if ptp_service_active "$service"; then printf '%s\n' "$service"; break; fi
    done
}

ptp_active_clock_process_families() {
    pgrep -x chronyd >/dev/null 2>&1 && echo chrony
    pgrep -x systemd-timesyncd >/dev/null 2>&1 && echo systemd-timesyncd
    if pgrep -x 'ntpd|ntpsec|openntpd' >/dev/null 2>&1; then echo ntp; fi
}

ptp_system_clock_synchronized() {
    local value
    value="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
    [[ $value == yes ]] && return 0
    if command -v chronyc >/dev/null 2>&1; then
        chronyc tracking 2>/dev/null | grep -Eq '^Leap status[[:space:]]*:[[:space:]]*Normal' && return 0
    fi
    return 1
}

ptp_atomic_write_state() {
    local target=$1 temporary
    mkdir -p "$(dirname "$target")"
    temporary="$target.tmp.$$"
    cat > "$temporary"
    chmod 0644 "$temporary"
    mv -f "$temporary" "$target"
}

ptp_read_state_value() {
    local state_file=$1 wanted=$2 key value
    [[ -r $state_file ]] || return 1
    while IFS='=' read -r key value; do
        [[ $key == "$wanted" ]] && { printf '%s\n' "$value"; return 0; }
    done < "$state_file"
    return 1
}
