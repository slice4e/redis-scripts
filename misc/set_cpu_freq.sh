#!/bin/bash
#
# Set CPU frequency for all cores in the system.
# Usage:
#   ./set_cpu_freq.sh              # Show available frequencies and prompt
#   ./set_cpu_freq.sh <freq_khz>  # Set all cores to the given frequency (in KHz)
#   ./set_cpu_freq.sh restore      # Restore original governor and frequency settings
#

BACKUP_FILE="/tmp/cpu_freq_backup.conf"

get_num_cpus() {
    ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l
}

show_available() {
    echo "=== Current CPU frequency info ==="
    echo "Current governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    echo "Current frequency: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) KHz"
    echo ""

    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies ]]; then
        echo "Available frequencies (KHz):"
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
    elif [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq && -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
        local min=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq)
        local max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
        echo "Frequency range: ${min} - ${max} KHz"
    fi

    echo ""
    echo "Available governors:"
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
}

save_settings() {
    local num_cpus=$(get_num_cpus)
    > "$BACKUP_FILE"
    # Save intel_pstate status if applicable
    if [[ -f /sys/devices/system/cpu/intel_pstate/status ]]; then
        echo "intel_pstate $(cat /sys/devices/system/cpu/intel_pstate/status)" >> "$BACKUP_FILE"
    fi
    for ((i=0; i<num_cpus; i++)); do
        local gov=$(cat /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor)
        local min=$(cat /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_min_freq)
        local max=$(cat /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq)
        echo "${i} ${gov} ${min} ${max}" >> "$BACKUP_FILE"
    done
    echo "Settings saved to ${BACKUP_FILE}"
}

set_frequency() {
    local freq=$1
    local num_cpus=$(get_num_cpus)

    # Save current settings before changing
    if [[ ! -f "$BACKUP_FILE" ]]; then
        save_settings
    fi

    echo "Setting all ${num_cpus} cores to ${freq} KHz..."

    # If intel_pstate is active, switch to passive mode so governors work properly.
    # In active mode with HWP, the CPU ignores OS frequency requests.
    if [[ -f /sys/devices/system/cpu/intel_pstate/status ]]; then
        local pstate_status=$(cat /sys/devices/system/cpu/intel_pstate/status)
        if [[ "$pstate_status" != "passive" ]]; then
            echo "Switching intel_pstate from '${pstate_status}' to 'passive' mode..."
            echo "passive" > /sys/devices/system/cpu/intel_pstate/status
        fi
    fi

    for ((i=0; i<num_cpus; i++)); do
        echo "userspace" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "$freq" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_setspeed
        else
            # Pin min/max to the target frequency.
            # Order matters: widen the range first, then narrow it.
            local cur_max=$(cat /sys/devices/system/cpu/cpu${i}/cpufreq/cpuinfo_max_freq)
            echo "performance" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor
            echo "$cur_max" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq 2>/dev/null
            echo "$freq" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_min_freq
            echo "$freq" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq
        fi
    done

    # Brief settle time then verify
    sleep 0.5
    echo "Done. Verifying cpu0: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) KHz"
}

restore_settings() {
    if [[ ! -f "$BACKUP_FILE" ]]; then
        echo "No backup file found at ${BACKUP_FILE}. Nothing to restore."
        exit 1
    fi

    echo "Restoring CPU frequency settings from ${BACKUP_FILE}..."
    while read -r first rest; do
        if [[ "$first" == "intel_pstate" ]]; then
            echo "Restoring intel_pstate to '${rest}' mode..."
            echo "$rest" > /sys/devices/system/cpu/intel_pstate/status 2>/dev/null
            continue
        fi
        local cpu="$first"
        read -r gov min max <<< "$rest"
        # Widen range first to avoid "busy" errors from ordering conflicts
        local cur_max=$(cat /sys/devices/system/cpu/cpu${cpu}/cpufreq/cpuinfo_max_freq)
        echo "$cur_max" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_max_freq 2>/dev/null
        echo "$min" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq
        echo "$max" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_max_freq
        echo "$gov" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor
    done < "$BACKUP_FILE"

    rm -f "$BACKUP_FILE"
    echo "Restored. Current governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    echo "Current frequency: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) KHz"
}

# --- Main ---

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

if [[ "$1" == "restore" ]]; then
    restore_settings
    exit 0
fi

if [[ -n "$1" ]]; then
    set_frequency "$1"
    exit 0
fi

# Interactive mode
show_available
echo ""
echo "Usage:"
echo "  $0 <freq_in_khz>   Set all cores to specified frequency"
echo "  $0 restore          Restore original settings"
echo ""
read -p "Enter frequency (KHz) to set, or 'q' to quit: " choice
if [[ "$choice" == "q" || -z "$choice" ]]; then
    exit 0
fi
set_frequency "$choice"
