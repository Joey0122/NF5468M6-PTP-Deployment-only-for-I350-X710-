#!/usr/bin/env bash

ptp_config_reset() {
    PTP_DOMAIN=TODO
    PTP_TRANSPORT=TODO
    PTP_DELAY_MECHANISM=TODO
    PTP_PROFILE=TODO
    TRANSPORT_SPECIFIC=TODO
    GRANDMASTER_DISCOVERY=TODO
    PROFILE_EXTRA_CONFIG=NONE
    SLAVE_CLOCK_POLICY=TODO
    SLAVE_TAI_UTC_POLICY=TODO
    MASTER_TIME_POLICY=TODO
    MASTER_UTC_OFFSET=TODO
    MASTER_UTC_OFFSET_AUTHORITY=TODO
    SYNC_TIMEOUT_SECONDS=120
    MASTER_READY_TIMEOUT_SECONDS=30
    PHC2SYS_VERIFY_SECONDS=8
}

ptp_config_reset

ptp_config_known_key() {
    case "$1" in
        PTP_DOMAIN|PTP_TRANSPORT|PTP_DELAY_MECHANISM|PTP_PROFILE|TRANSPORT_SPECIFIC|\
        GRANDMASTER_DISCOVERY|PROFILE_EXTRA_CONFIG|SLAVE_CLOCK_POLICY|\
        SLAVE_TAI_UTC_POLICY|MASTER_TIME_POLICY|MASTER_UTC_OFFSET|MASTER_UTC_OFFSET_AUTHORITY|\
        SYNC_TIMEOUT_SECONDS|MASTER_READY_TIMEOUT_SECONDS|PHC2SYS_VERIFY_SECONDS) return 0 ;;
        *) return 1 ;;
    esac
}

ptp_load_site_config() {
    local file=${1:-${PTPCTL_SITE_CONFIG:-$PTPCTL_ROOT/configs/site.env}} line key value line_number=0
    [[ -r $file ]] || ptp_die "Site configuration is missing: $file" || return
    ptp_config_reset
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        line="${line%$'\r'}"
        [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
        if [[ ! $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            ptp_die "$file:$line_number is not KEY=VALUE syntax" || return
        fi
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"
        ptp_config_known_key "$key" || { ptp_die "$file:$line_number uses unknown key $key" || return; }
        [[ $value != *'$('* && $value != *'`'* && $value != *$'\n'* ]] || {
            ptp_die "$file:$line_number contains an unsafe value" || return
        }
        printf -v "$key" '%s' "$value"
    done < "$file"
    if [[ $PROFILE_EXTRA_CONFIG != NONE && $PROFILE_EXTRA_CONFIG != /* ]]; then
        PROFILE_EXTRA_CONFIG="$PTPCTL_ROOT/$PROFILE_EXTRA_CONFIG"
    fi
}

ptp_write_site_config() {
    local file=${1:-${PTPCTL_SITE_CONFIG:-$PTPCTL_ROOT/configs/site.env}} temporary
    mkdir -p "$(dirname "$file")" || return
    temporary="$file.tmp.$$"
    {
        cat <<EOF
# Site-owned PTP values. The interactive wizard maintains this file.
# Hardware interface, PCI, driver, and /dev/ptp values never belong here:
# ptpctl discovers and validates them live on every setup run.

# Common PTP network/profile values supplied by the experiment or network owner.
# PTP_DOMAIN is 0..255. Transport is L2, UDPv4, or UDPv6.
PTP_DOMAIN=$PTP_DOMAIN
PTP_TRANSPORT=$PTP_TRANSPORT
PTP_DELAY_MECHANISM=$PTP_DELAY_MECHANISM
PTP_PROFILE=$PTP_PROFILE
# Profile-defined transportSpecific byte, decimal 0..255.
TRANSPORT_SPECIFIC=$TRANSPORT_SPECIFIC

# Slave-only discovery and safety policy. Configured unicast requires reviewed
# linuxptp directives in PROFILE_EXTRA_CONFIG.
GRANDMASTER_DISCOVERY=$GRANDMASTER_DISCOVERY
SLAVE_CLOCK_POLICY=$SLAVE_CLOCK_POLICY
SLAVE_TAI_UTC_POLICY=$SLAVE_TAI_UTC_POLICY

# Master-only source policy and confirmed current TAI-minus-UTC offset.
# The authority is documentation (for example IERS Bulletin C or a site authority).
MASTER_TIME_POLICY=$MASTER_TIME_POLICY
MASTER_UTC_OFFSET=$MASTER_UTC_OFFSET
MASTER_UTC_OFFSET_AUTHORITY=$MASTER_UTC_OFFSET_AUTHORITY

# IEEE1588_DEFAULT needs no extra file. Other profiles and configured unicast
# require a reviewed file containing only permitted global linuxptp directives.
PROFILE_EXTRA_CONFIG=$PROFILE_EXTRA_CONFIG

# Runtime verification timeouts in seconds.
SYNC_TIMEOUT_SECONDS=$SYNC_TIMEOUT_SECONDS
MASTER_READY_TIMEOUT_SECONDS=$MASTER_READY_TIMEOUT_SECONDS
PHC2SYS_VERIFY_SECONDS=$PHC2SYS_VERIFY_SECONDS
EOF
    } > "$temporary" || { rm -f "$temporary"; return 1; }
    chmod 0644 "$temporary"
    mv -f "$temporary" "$file"
}

ptp_config_require_common() {
    local key value
    for key in PTP_DOMAIN PTP_TRANSPORT PTP_DELAY_MECHANISM PTP_PROFILE TRANSPORT_SPECIFIC; do
        value=${!key}
        ptp_is_todo "$value" && { ptp_die "$key is TODO in configs/site.env" || return; }
    done
    ptp_validate_domain "$PTP_DOMAIN" || ptp_die "PTP_DOMAIN must be 0..255" || return
    ptp_validate_transport "$PTP_TRANSPORT" || ptp_die "PTP_TRANSPORT must be L2, UDPv4, or UDPv6" || return
    ptp_validate_delay "$PTP_DELAY_MECHANISM" || ptp_die "PTP_DELAY_MECHANISM must be E2E, P2P, or Auto" || return
    [[ $TRANSPORT_SPECIFIC =~ ^[0-9]+$ ]] && (( 10#$TRANSPORT_SPECIFIC <= 255 )) ||
        { ptp_die "TRANSPORT_SPECIFIC must be 0..255" || return; }
    [[ $SYNC_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || ptp_die "SYNC_TIMEOUT_SECONDS must be positive" || return
    [[ $MASTER_READY_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || ptp_die "MASTER_READY_TIMEOUT_SECONDS must be positive" || return
    [[ $PHC2SYS_VERIFY_SECONDS =~ ^[1-9][0-9]*$ ]] || ptp_die "PHC2SYS_VERIFY_SECONDS must be positive" || return

    if [[ $PTP_PROFILE != IEEE1588_DEFAULT ]]; then
        [[ $PROFILE_EXTRA_CONFIG != NONE && -r $PROFILE_EXTRA_CONFIG ]] || {
            ptp_die "Profile $PTP_PROFILE requires a reviewed PROFILE_EXTRA_CONFIG file" || return
        }
    fi
}

ptp_config_require_role() {
    local role=$1
    ptp_config_require_common || return
    case "$role" in
        slave)
            ptp_is_todo "$GRANDMASTER_DISCOVERY" && { ptp_die "GRANDMASTER_DISCOVERY is TODO" || return; }
            [[ $GRANDMASTER_DISCOVERY == MULTICAST || $GRANDMASTER_DISCOVERY == UNICAST_CONFIGURED ]] ||
                { ptp_die "GRANDMASTER_DISCOVERY must be MULTICAST or UNICAST_CONFIGURED" || return; }
            if [[ $GRANDMASTER_DISCOVERY == UNICAST_CONFIGURED && $PROFILE_EXTRA_CONFIG == NONE ]]; then
                ptp_die "UNICAST_CONFIGURED requires a reviewed PROFILE_EXTRA_CONFIG" || return
            fi
            [[ $SLAVE_CLOCK_POLICY == REQUIRE_NO_OTHER_DISCIPLINER ]] ||
                { ptp_die "SLAVE_CLOCK_POLICY must explicitly be REQUIRE_NO_OTHER_DISCIPLINER" || return; }
            [[ $SLAVE_TAI_UTC_POLICY == REQUIRE_VALID_GM ]] ||
                { ptp_die "SLAVE_TAI_UTC_POLICY must explicitly be REQUIRE_VALID_GM" || return; }
            ;;
        master)
            [[ $MASTER_TIME_POLICY == REQUIRE_SYNCED_SYSTEM || $MASTER_TIME_POLICY == ALLOW_LAB_FREERUN ]] ||
                { ptp_die "MASTER_TIME_POLICY must be REQUIRE_SYNCED_SYSTEM or ALLOW_LAB_FREERUN" || return; }
            [[ $MASTER_UTC_OFFSET =~ ^[0-9]+$ ]] && (( 10#$MASTER_UTC_OFFSET <= 255 )) ||
                { ptp_die "MASTER_UTC_OFFSET must be a confirmed value from 0..255" || return; }
            ;;
        *) ptp_die "Internal error: unknown role $role" || return ;;
    esac
}

ptp_validate_profile_extra() {
    [[ $PROFILE_EXTRA_CONFIG == NONE ]] && return 0
    local line key number=0
    while IFS= read -r line || [[ -n $line ]]; do
        ((number += 1))
        [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
        [[ $line != *'['* && $line =~ ^[A-Za-z0-9_.-]+[[:space:]]+[^[:space:]].*$ ]] || {
            ptp_die "$PROFILE_EXTRA_CONFIG:$number must contain only reviewed global key/value directives" || return
        }
        key=${line%%[[:space:]]*}
        case "$key" in
            time_stamping|clientOnly|serverOnly|domainNumber|network_transport|delay_mechanism|transportSpecific|uds_address|uds_ro_address)
                ptp_die "$PROFILE_EXTRA_CONFIG:$number may not override safety-critical key $key" || return ;;
        esac
    done < "$PROFILE_EXTRA_CONFIG"
}
