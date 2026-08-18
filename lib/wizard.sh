#!/usr/bin/env bash

# Interactive first-run/setup experience. Runtime changes are deliberately
# delegated to cmd_setup so the wizard cannot bypass live validation or rollback.

ptp_wizard_number() {
    local variable=$1 label=$2 default=$3 minimum=$4 maximum=$5 answer
    while true; do
        ptp_prompt_read "$label${default:+ [$default]}: " answer || {
            ptp_error "Input ended; setup was cancelled."
            return 1
        }
        answer=${answer:-$default}
        if [[ $answer =~ ^[0-9]+$ ]] && (( 10#$answer >= minimum && 10#$answer <= maximum )); then
            answer=$((10#$answer))
            printf -v "$variable" '%s' "$answer"
            return 0
        fi
        echo "Enter a whole number from $minimum to $maximum."
    done
}

ptp_wizard_text() {
    local variable=$1 label=$2 default=$3 pattern=$4 answer
    while true; do
        ptp_prompt_read "$label${default:+ [$default]}: " answer || {
            ptp_error "Input ended; setup was cancelled."
            return 1
        }
        answer=${answer:-$default}
        if [[ -n $answer && $answer =~ $pattern && $answer != *'$('* && $answer != *'`'* ]]; then
            printf -v "$variable" '%s' "$answer"
            return 0
        fi
        echo "Enter a non-empty value using letters, numbers, spaces, '.', '_', '/', ':', '+' or '-'."
    done
}

ptp_wizard_menu_choice() {
    local variable=$1 default=$2 maximum=$3 answer
    while true; do
        ptp_prompt_read "Selection${default:+ [$default]}: " answer || {
            ptp_error "Input ended; setup was cancelled."
            return 1
        }
        answer=${answer:-$default}
        if [[ $answer =~ ^[0-9]+$ ]] && (( 10#$answer >= 1 && 10#$answer <= maximum )); then
            answer=$((10#$answer))
            printf -v "$variable" '%s' "$answer"
            return 0
        fi
        echo "Enter a number from 1 to $maximum."
    done
}

ptp_wizard_transport() {
    local choice default=1
    case ${PTP_TRANSPORT:-} in UDPv4) default=2 ;; UDPv6) default=3 ;; esac
    echo
    echo "PTP transport:"
    echo
    echo "[1] L2"
    echo "[2] UDPv4"
    echo "[3] UDPv6"
    echo
    ptp_wizard_menu_choice choice "$default" 3 || return
    case $choice in 1) PTP_TRANSPORT=L2 ;; 2) PTP_TRANSPORT=UDPv4 ;; 3) PTP_TRANSPORT=UDPv6 ;; esac
}

ptp_wizard_delay() {
    local choice default=1
    case ${PTP_DELAY_MECHANISM:-} in P2P) default=2 ;; Auto) default=3 ;; esac
    echo
    echo "Delay mechanism:"
    echo
    echo "[1] E2E"
    echo "[2] P2P"
    echo "[3] Auto"
    echo
    ptp_wizard_menu_choice choice "$default" 3 || return
    case $choice in 1) PTP_DELAY_MECHANISM=E2E ;; 2) PTP_DELAY_MECHANISM=P2P ;; 3) PTP_DELAY_MECHANISM=Auto ;; esac
}

ptp_wizard_profile() {
    local choice default=1 profile_default=""
    if ! ptp_is_todo "${PTP_PROFILE:-}" && [[ $PTP_PROFILE != IEEE1588_DEFAULT ]]; then
        default=2
        profile_default=$PTP_PROFILE
    fi
    echo
    echo "PTP profile:"
    echo
    echo "[1] IEEE 1588 default profile"
    echo "[2] Other site-specific profile (reviewed extra config required)"
    echo
    ptp_wizard_menu_choice choice "$default" 2 || return
    if [[ $choice == 1 ]]; then
        PTP_PROFILE=IEEE1588_DEFAULT
    else
        ptp_wizard_text PTP_PROFILE "Profile name" "$profile_default" '^[A-Za-z0-9_.-]+$' || return
    fi
}

ptp_wizard_extra_config() {
    local default="" candidate resolved
    if [[ ${PROFILE_EXTRA_CONFIG:-NONE} != NONE ]] && ! ptp_is_todo "${PROFILE_EXTRA_CONFIG:-}"; then
        default=$PROFILE_EXTRA_CONFIG
    fi
    while true; do
        ptp_prompt_read "Reviewed linuxptp extra-config path${default:+ [$default]}: " candidate || {
            ptp_error "Input ended; setup was cancelled."
            return 1
        }
        candidate=${candidate:-$default}
        if [[ $candidate == *'$('* || $candidate == *'`'* ]]; then
            echo "That path contains unsupported characters."
            continue
        fi
        if [[ $candidate == /* ]]; then resolved=$candidate; else resolved="$PTPCTL_ROOT/$candidate"; fi
        if [[ -r $resolved ]]; then
            PROFILE_EXTRA_CONFIG=$resolved
            ptp_validate_profile_extra
            return
        fi
        echo "That reviewed config file is not readable."
    done
}

ptp_wizard_grandmaster() {
    local choice default=1
    [[ ${GRANDMASTER_DISCOVERY:-} == UNICAST_CONFIGURED ]] && default=2
    echo
    echo "Grandmaster discovery mode:"
    echo
    echo "[1] Multicast discovery"
    echo "[2] Configured unicast (reviewed extra config required)"
    echo
    ptp_wizard_menu_choice choice "$default" 2 || return
    case $choice in 1) GRANDMASTER_DISCOVERY=MULTICAST ;; 2) GRANDMASTER_DISCOVERY=UNICAST_CONFIGURED ;; esac
}

ptp_wizard_master_policy() {
    local choice default=1
    [[ ${MASTER_TIME_POLICY:-} == ALLOW_LAB_FREERUN ]] && default=2
    echo
    if ptp_system_clock_synchronized; then
        echo "Current system clock: synchronized to an upstream source"
    else
        echo "Current system clock: free-running laboratory time (no upstream synchronization proven)"
    fi
    echo
    echo "Master upstream-time policy:"
    echo
    echo "[1] Require a synchronized system clock"
    echo "[2] Allow free-running laboratory time"
    echo
    ptp_wizard_menu_choice choice "$default" 2 || return
    case $choice in
        1) MASTER_TIME_POLICY=REQUIRE_SYNCED_SYSTEM ;;
        2)
            MASTER_TIME_POLICY=ALLOW_LAB_FREERUN
            echo
            ptp_warn "This server will act as a PTP protocol master, but its time is not traceable or guaranteed accurate."
            ;;
    esac
}

ptp_wizard_site_values() {
    local site_file=${PTPCTL_SITE_CONFIG:-$PTPCTL_ROOT/configs/site.env}
    local default_domain default_transport default_delay default_profile default_ts
    if [[ -r $site_file ]]; then
        echo
        echo "Existing site configuration found: $site_file"
        if ! ptp_load_site_config "$site_file"; then
            ptp_warn "The existing file could not be safely parsed; the wizard will rebuild it from validated answers."
            ptp_config_reset
        fi
    else
        echo
        echo "No existing site configuration was found; the wizard will create $site_file."
        ptp_config_reset
    fi

    default_domain=$([[ ${PTP_DOMAIN:-TODO} =~ ^[0-9]+$ ]] && echo "$PTP_DOMAIN" || echo 0)
    default_transport=$([[ ${PTP_TRANSPORT:-} =~ ^(L2|UDPv4|UDPv6)$ ]] && echo "$PTP_TRANSPORT" || echo L2)
    default_delay=$([[ ${PTP_DELAY_MECHANISM:-} =~ ^(E2E|P2P|Auto)$ ]] && echo "$PTP_DELAY_MECHANISM" || echo E2E)
    default_profile=$([[ -n ${PTP_PROFILE:-} ]] && ! ptp_is_todo "$PTP_PROFILE" && echo "$PTP_PROFILE" || echo IEEE1588_DEFAULT)
    default_ts=$([[ ${TRANSPORT_SPECIFIC:-TODO} =~ ^[0-9]+$ ]] && echo "$TRANSPORT_SPECIFIC" || echo 0)
    PTP_DOMAIN=$default_domain
    PTP_TRANSPORT=$default_transport
    PTP_DELAY_MECHANISM=$default_delay
    PTP_PROFILE=$default_profile
    TRANSPORT_SPECIFIC=$default_ts

    echo
    echo "Site PTP values (press Enter to accept a value in brackets)"
    echo
    ptp_wizard_number PTP_DOMAIN "PTP Domain" "$PTP_DOMAIN" 0 255 || return
    ptp_wizard_transport || return
    ptp_wizard_delay || return
    ptp_wizard_profile || return
    echo
    echo "transportSpecific is profile-owned; confirm it with the network owner."
    ptp_wizard_number TRANSPORT_SPECIFIC "transportSpecific" "$TRANSPORT_SPECIFIC" 0 255 || return

    if [[ $PTP_ROLE == slave ]]; then
        ptp_wizard_grandmaster || return
        SLAVE_CLOCK_POLICY=REQUIRE_NO_OTHER_DISCIPLINER
        SLAVE_TAI_UTC_POLICY=REQUIRE_VALID_GM
    else
        ptp_wizard_master_policy || return
        local offset_default="" authority_default=""
        [[ ${MASTER_UTC_OFFSET:-} =~ ^[0-9]+$ ]] && offset_default=$MASTER_UTC_OFFSET
        ! ptp_is_todo "${MASTER_UTC_OFFSET_AUTHORITY:-}" && authority_default=$MASTER_UTC_OFFSET_AUTHORITY
        echo
        echo "Confirm the current TAI-minus-UTC offset with an authoritative source."
        ptp_wizard_number MASTER_UTC_OFFSET "TAI-UTC offset seconds" "$offset_default" 0 255 || return
        ptp_wizard_text MASTER_UTC_OFFSET_AUTHORITY "UTC-offset authority" "$authority_default" \
            '^[A-Za-z0-9][A-Za-z0-9 ._/:+-]*$' || return
    fi

    if [[ $PTP_PROFILE != IEEE1588_DEFAULT || $GRANDMASTER_DISCOVERY == UNICAST_CONFIGURED ]]; then
        echo
        ptp_wizard_extra_config || return
    else
        PROFILE_EXTRA_CONFIG=NONE
    fi

    ptp_config_require_role "$PTP_ROLE" || return
    ptp_validate_profile_extra || return
    ptp_write_site_config "$site_file" || {
        ptp_error "Could not update site configuration: $site_file"
        return 1
    }
    ptp_ok "Saved validated site configuration: $site_file"
}

ptp_wizard_mode() {
    local choice
    echo
    echo "Supported PTP modes:"
    echo
    echo "[1] I350 Master"
    echo "[2] I350 Slave"
    echo "[3] X710 Master"
    echo "[4] X710 Slave"
    echo
    ptp_wizard_menu_choice choice "" 4 || return
    case $choice in
        1) ptp_mode_parse I350-master ;;
        2) ptp_mode_parse I350-slave ;;
        3) ptp_mode_parse X710-master ;;
        4) ptp_mode_parse X710-slave ;;
    esac
}

ptp_wizard_confirm_start() {
    local answer
    while true; do
        ptp_prompt_read "Start PTP synchronization now? [Y/n] " answer || {
            echo
            echo "Setup cancelled before start; no PTP process was started."
            return 1
        }
        case ${answer:-Y} in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No)
                echo "Setup cancelled before start; no PTP process was started."
                return 1
                ;;
            *) echo "Enter y or n." ;;
        esac
    done
}

cmd_wizard() {
    local inventory_file="$PTP_STATE_DIR/server_inventory.txt" record
    unset PTP_REQUESTED_PCI
    echo "PTP Interactive Setup Wizard"
    echo
    ptp_require_linux || return
    ptp_require_commands lspci ip ethtool ptp4l phc2sys pmc systemctl timedatectl setsid flock pgrep || return
    ptp_require_root || return
    ptp_discover_candidates || return
    if ! ptp_write_inventory "$inventory_file"; then
        ptp_error "Could not write live hardware inventory: $inventory_file"
        return 1
    fi
    ptp_ok "Live hardware inventory: $inventory_file"
    echo
    echo "Detected Intel I350/X710 ports:"
    if [[ ${#PTP_CANDIDATES[@]} -eq 0 ]]; then
        echo "  none"
    else
        for record in "${PTP_CANDIDATES[@]}"; do ptp_print_candidate "$record" "  "; done
    fi
    echo
    echo "Detected clock services and PTP processes:"
    ptp_clock_service_report

    ptp_wizard_mode || return
    ptp_select_candidate "$PTP_FAMILY" || return
    ptp_validate_selected_candidate "$PTP_SELECTED_CANDIDATE" yes || return
    ptp_selected_unpack
    PTP_REQUESTED_PCI=$PTP_PCI
    ptp_wizard_site_values || return

    # cmd_setup repeats dependency, PCI/netdev, timestamp, PHC, link, process,
    # and clock-policy checks. The remembered PCI function only identifies the
    # user's menu choice; no cached interface or PHC value is trusted.
    PTP_SETUP_CONFIRM=1 cmd_setup "$PTP_MODE"
}
