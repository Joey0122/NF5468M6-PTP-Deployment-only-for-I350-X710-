#!/usr/bin/env bash

# Candidate records are tab-separated:
# iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason
declare -ag PTP_CANDIDATES=()

ptp_expected_driver_for_family() {
    case "$1" in I350) echo igb ;; X710) echo i40e ;; *) echo unknown ;; esac
}

ptp_family_from_model() {
    local model=${1^^}
    [[ $model == *I350* ]] && { echo I350; return; }
    [[ $model == *X710* ]] && { echo X710; return; }
    return 1
}

ptp_discover_candidates() {
    PTP_CANDIDATES=()
    if [[ ${PTPCTL_TEST_MODE:-0} == 1 && -n ${PTPCTL_FIXTURE_FILE:-} ]]; then
        mapfile -t PTP_CANDIDATES < <(grep -Ev '^[[:space:]]*(#|$)' "$PTPCTL_FIXTURE_FILE")
        return 0
    fi

    ptp_require_commands lspci ethtool || return
    local netdev iface path pci model family driver expected firmware link mac ts index phc phc_sysfs
    local tx rx raw valid reason
    for netdev in "$PTP_SYS_ROOT"/class/net/*; do
        [[ -e $netdev ]] || continue
        iface=${netdev##*/}
        ptp_iface_is_physical_pci_ethernet "$iface" || continue
        path="$(readlink -f "$netdev/device")"
        pci=${path##*/}
        model="$(lspci -Dnn -s "$pci" 2>/dev/null | head -n 1)"
        family="$(ptp_family_from_model "$model" 2>/dev/null || true)"
        [[ -n $family ]] || continue
        driver="$(ptp_iface_driver "$iface")"
        expected="$(ptp_expected_driver_for_family "$family")"
        firmware="$(ptp_iface_firmware "$iface")"
        link="$(ptp_carrier_state "$iface")"
        mac="$(ptp_mac_address "$iface")"
        ts="$(ptp_timestamp_output "$iface")"
        tx=no; rx=no; raw=no
        ptp_iface_has_timestamp_capability "$ts" hardware-transmit && tx=yes
        ptp_iface_has_timestamp_capability "$ts" hardware-receive && rx=yes
        ptp_iface_has_timestamp_capability "$ts" hardware-raw-clock && raw=yes
        index="$(ptp_phc_index_from_output "$ts")"
        phc=none; phc_sysfs=none
        if [[ $index =~ ^[0-9]+$ ]] && ptp_is_phc_device "$PTP_DEV_ROOT/ptp$index"; then
            phc="/dev/ptp$index"
            phc_sysfs="$(ptp_phc_sysfs_for_index "$index")"
        fi
        valid=yes; reason=OK
        if [[ $driver != "$expected" ]]; then valid=no; reason="expected_driver_$expected";
        elif [[ $tx != yes ]]; then valid=no; reason=no_hardware_tx;
        elif [[ $rx != yes ]]; then valid=no; reason=no_hardware_rx;
        elif [[ $raw != yes ]]; then valid=no; reason=no_hardware_raw_clock;
        elif [[ $phc == none ]]; then valid=no; reason=no_valid_phc;
        elif [[ -z $phc_sysfs || $phc_sysfs == none ]]; then valid=no; reason=no_phc_sysfs_mapping;
        fi
        model=${model//$'\t'/ }
        PTP_CANDIDATES+=("$iface"$'\t'"$family"$'\t'"$pci"$'\t'"$model"$'\t'"$driver"$'\t'"${firmware:-unknown}"$'\t'"$link"$'\t'"$mac"$'\t'"$phc"$'\t'"$phc_sysfs"$'\t'"$tx"$'\t'"$rx"$'\t'"$raw"$'\t'"$valid"$'\t'"$reason")
    done
}

ptp_candidate_field() {
    local record=$1 field=$2
    awk -F'\t' -v n="$field" '{print $n}' <<<"$record"
}

ptp_candidate_phc_sharing() {
    local wanted=$1 wanted_phc record iface phc count=0 peers=""
    wanted_phc="$(ptp_candidate_field "$wanted" 9)"
    if [[ $wanted_phc == none || -z $wanted_phc ]]; then
        echo NO
        return
    fi
    for record in "${PTP_CANDIDATES[@]}"; do
        phc="$(ptp_candidate_field "$record" 9)"
        [[ $phc == "$wanted_phc" ]] || continue
        iface="$(ptp_candidate_field "$record" 1)"
        peers="${peers:+$peers, }$iface"
        ((count += 1))
    done
    if (( count > 1 )); then
        printf 'YES (%s)\n' "$peers"
    else
        echo NO
    fi
}

ptp_print_candidate() {
    local record=$1 prefix=${2:-}
    local iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason
    IFS=$'\t' read -r iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason <<<"$record"
    printf '%s%-14s PCI %-13s Link %-5s PHC %-10s' "$prefix" "$iface" "$pci" "$([[ $link == 1 ]] && echo UP || echo DOWN)" "$phc"
    [[ $valid == yes ]] || printf '  INVALID(%s)' "$reason"
    printf '\n'
}

ptp_probe_report() {
    ptp_discover_candidates || return
    echo "Intel I350/X710 PTP hardware probe"
    echo "Kernel: $(uname -r)"
    if [[ ${#PTP_CANDIDATES[@]} -eq 0 ]]; then
        echo "No Intel I350 or X710 PCI netdevs were detected."
        return 0
    fi
    local record iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason
    for record in "${PTP_CANDIDATES[@]}"; do
        IFS=$'\t' read -r iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason <<<"$record"
        echo
        echo "Interface              : $iface"
        echo "Family                 : $family"
        echo "PCI                    : $pci"
        echo "Model                  : $model"
        echo "Driver / expected      : $driver / $(ptp_expected_driver_for_family "$family")"
        echo "Firmware               : $firmware"
        echo "Link / MAC             : $([[ $link == 1 ]] && echo UP || echo DOWN) / $mac"
        echo "Hardware TX / RX / raw : $tx / $rx / $raw"
        echo "PHC                    : $phc"
        echo "PHC sysfs              : $phc_sysfs"
        echo "PHC shared             : $(ptp_candidate_phc_sharing "$record")"
        echo "Usable                 : $valid${reason:+ ($reason)}"
    done
}

ptp_select_candidate() {
    local family=$1 record valid pci family_count=0
    local -a valid_records=() pool=()
    for record in "${PTP_CANDIDATES[@]}"; do
        [[ $(ptp_candidate_field "$record" 2) == "$family" ]] || continue
        ((family_count += 1))
        valid=$(ptp_candidate_field "$record" 14)
        [[ $valid == yes ]] || continue
        valid_records+=("$record")
    done

    if [[ -n ${PTP_REQUESTED_PCI:-} ]]; then
        for record in "${PTP_CANDIDATES[@]}"; do
            [[ $(ptp_candidate_field "$record" 2) == "$family" ]] || continue
            pci="$(ptp_candidate_field "$record" 3)"
            [[ $pci == "$PTP_REQUESTED_PCI" ]] || continue
            [[ $(ptp_candidate_field "$record" 14) == yes ]] || {
                ptp_error "Previously selected $family port $pci is no longer hardware-valid: $(ptp_candidate_field "$record" 15)"
                return 1
            }
            PTP_SELECTED_CANDIDATE=$record
            return 0
        done
        ptp_error "Previously selected $family port $PTP_REQUESTED_PCI is no longer present. Live hardware was re-scanned."
        return 1
    fi

    [[ ${#valid_records[@]} -gt 0 ]] || {
        if (( family_count == 0 )); then
            ptp_error "No Intel $family NIC port was detected."
        else
            ptp_error "No hardware-valid $family port was found:"
            for record in "${PTP_CANDIDATES[@]}"; do
                [[ $(ptp_candidate_field "$record" 2) == "$family" ]] || continue
                printf '  %s (PCI %s): %s\n' "$(ptp_candidate_field "$record" 1)" \
                    "$(ptp_candidate_field "$record" 3)" "$(ptp_candidate_field "$record" 15)" >&2
            done
        fi
        ptp_error "Run './ptpctl probe' for the full live report."
        return 1
    }
    if [[ ${#valid_records[@]} -eq 1 ]]; then
        PTP_SELECTED_CANDIDATE=${valid_records[0]}; return 0
    fi
    pool=("${valid_records[@]}")
    echo "Found ${#pool[@]} $family ports:"

    local i choice
    for ((i=0; i<${#pool[@]}; i++)); do ptp_print_candidate "${pool[i]}" "[$((i+1))] "; done
    while true; do
        ptp_prompt_read "Select port [1]: " choice || {
            ptp_error "Multiple ports require a numbered selection."
            return 1
        }
        choice=${choice:-1}
        if [[ $choice =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#pool[@]} )); then
            choice=$((10#$choice))
            break
        fi
        echo "Enter a number from 1 to ${#pool[@]}."
    done
    PTP_SELECTED_CANDIDATE=${pool[choice-1]}
}

ptp_validate_selected_candidate() {
    local record=$1 require_link=${2:-yes}
    local iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason
    IFS=$'\t' read -r iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason <<<"$record"
    [[ $valid == yes ]] || ptp_die "$iface failed hardware validation: $reason" || return
    [[ $driver == "$(ptp_expected_driver_for_family "$family")" ]] || ptp_die "$iface has unexpected driver $driver" || return
    [[ $tx == yes && $rx == yes && $raw == yes ]] || ptp_die "$iface lacks required hardware timestamp capabilities" || return
    [[ $phc =~ ^/dev/ptp[0-9]+$ ]] || ptp_die "$iface has no interface-mapped PHC" || return
    [[ -n $phc_sysfs && $phc_sysfs != none ]] || ptp_die "$iface PHC has no sysfs mapping" || return
    if [[ $require_link == yes && $link != 1 ]]; then ptp_die "$iface has no carrier; connect the intended PTP cable and retry" || return; fi
}

ptp_distribution_name() {
    local line value
    if [[ -r /etc/os-release ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            [[ $line == PRETTY_NAME=* ]] || continue
            value=${line#PRETTY_NAME=}
            value=${value#\"}; value=${value%\"}
            printf '%s\n' "$value"
            return
        done < /etc/os-release
    fi
    echo unknown
}

ptp_server_model() {
    local vendor=unknown model=unknown
    [[ -r $PTP_SYS_ROOT/class/dmi/id/sys_vendor ]] && vendor="$(< "$PTP_SYS_ROOT/class/dmi/id/sys_vendor")"
    [[ -r $PTP_SYS_ROOT/class/dmi/id/product_name ]] && model="$(< "$PTP_SYS_ROOT/class/dmi/id/product_name")"
    printf '%s %s\n' "$vendor" "$model"
}

ptp_linuxptp_version() {
    local output
    output="$(ptp4l -v 2>&1 || true)"
    awk 'NF {print; exit}' <<<"$output"
}

ptp_write_inventory() {
    local target=${1:-$PTP_STATE_DIR/server_inventory.txt} temporary record
    local iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason
    mkdir -p "$(dirname "$target")" || return
    temporary="$target.tmp.$$"
    {
        echo "server_ptp live hardware inventory"
        echo "Generated: $(date --iso-8601=seconds)"
        echo "Documentation only: setup always repeats live discovery."
        echo
        echo "System"
        printf '%-24s %s\n' "Kernel:" "$(uname -a 2>/dev/null || echo unknown)"
        printf '%-24s %s\n' "Distribution:" "$(ptp_distribution_name)"
        printf '%-24s %s\n' "Server model:" "$(ptp_server_model)"
        printf '%-24s %s\n' "linuxptp:" "$(ptp_linuxptp_version)"
        echo
        echo "Intel I350/X710 ports (${#PTP_CANDIDATES[@]})"
        if [[ ${#PTP_CANDIDATES[@]} -eq 0 ]]; then
            echo "No supported Intel ports detected."
        fi
        for record in "${PTP_CANDIDATES[@]}"; do
            IFS=$'\t' read -r iface family pci model driver firmware link mac phc phc_sysfs tx rx raw valid reason <<<"$record"
            echo
            printf '%-24s %s\n' "Interface:" "$iface"
            printf '%-24s %s\n' "NIC family:" "$family"
            printf '%-24s %s\n' "PCI address:" "$pci"
            printf '%-24s %s\n' "Model:" "$model"
            printf '%-24s %s\n' "Driver:" "$driver"
            printf '%-24s %s\n' "Firmware:" "$firmware"
            printf '%-24s %s\n' "MAC:" "$mac"
            printf '%-24s %s\n' "Link:" "$([[ $link == 1 ]] && echo UP || echo DOWN)"
            printf '%-24s %s\n' "Hardware TX timestamp:" "${tx^^}"
            printf '%-24s %s\n' "Hardware RX timestamp:" "${rx^^}"
            printf '%-24s %s\n' "Hardware raw clock:" "${raw^^}"
            printf '%-24s %s\n' "PHC:" "$phc"
            printf '%-24s %s\n' "PHC sysfs mapping:" "$phc_sysfs"
            printf '%-24s %s\n' "PHC shared:" "$(ptp_candidate_phc_sharing "$record")"
            printf '%-24s %s (%s)\n' "Hardware-valid:" "${valid^^}" "$reason"
        done
        echo
        echo "Clock services and PTP processes"
        ptp_clock_service_report
    } > "$temporary" || { rm -f "$temporary"; return 1; }
    chmod 0644 "$temporary"
    mv -f "$temporary" "$target"
}
