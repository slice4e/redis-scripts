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

    echo "Setting all ${num_cpus} cores to ${freq} KHz using userspace governor..."
    for ((i=0; i<num_cpus; i++)); do
        echo "userspace" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor 2>/dev/null
        if [[ $? -ne 0 ]]; then
            # userspace governor not available, use performance + min/max pinning
            echo "performance" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor
            echo "$freq" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_min_freq
            echo "$freq" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq
        else
            echo "$freq" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_setspeed
        fi
    done

    echo "Done. Verifying cpu0: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) KHz"
}

restore_settings() {
    if [[ ! -f "$BACKUP_FILE" ]]; then
        echo "No backup file found at ${BACKUP_FILE}. Nothing to restore."
        exit 1
    fi

    echo "Restoring CPU frequency settings from ${BACKUP_FILE}..."
    while read -r cpu gov min max; do
        echo "$gov" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor
        echo "$min" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq
        echo "$max" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_max_freq
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
