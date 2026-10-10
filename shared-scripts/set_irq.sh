#!/bin/bash
# Pins the benchmark NIC's IRQs to the benchmark CPUs on the server and on every memtier client, with irqbalance
# stopped. The original affinities and irqbalance state are restored when run_all.sh exits, however it exits.

IRQ_RESTORE_RUNS=()
IRQ_RESTORE_CMDS=()

# Usage: pin_irqs "<command prefix that runs a shell command on the host>" <interface> <cpu>...
pin_irqs(){
	local run=$1 iface=$2
	shift 2
	# Drivers such as mlx5 name their IRQs by PCI address, not by interface, so use the device's MSI vector list
	local irqs=$($run "ls /sys/class/net/$iface/device/msi_irqs 2>/dev/null" | tr -d '\r' | xargs)
	# Ask the host for the commands that undo what we are about to change
	IRQ_RESTORE_RUNS+=("$run")
	IRQ_RESTORE_CMDS+=("$($run "for i in $irqs; do echo \"echo \$(cat /proc/irq/\$i/smp_affinity_list) | sudo tee /proc/irq/\$i/smp_affinity_list > /dev/null;\"; done; systemctl is-active -q irqbalance.service && echo 'sudo systemctl start irqbalance.service'" | tr -d '\r' | tr '\n' ' ')")
	$run "sudo systemctl stop irqbalance.service; for i in $irqs; do echo $* | sudo tee /proc/irq/\$i/smp_affinity_list > /dev/null; done"
	local affinity=$($run "for i in $irqs; do cat /proc/irq/\$i/smp_affinity_list; done | sort -u" | tr -d '\r' | xargs)
	echo "$($run hostname | tr -d '\r') $iface: $(echo $irqs | wc -w) IRQs pinned to $affinity" | tee -a ${RESULTS_PATH}/irq_status.txt
}

restore_irqs(){
	for k in "${!IRQ_RESTORE_CMDS[@]}"; do
		${IRQ_RESTORE_RUNS[$k]} "${IRQ_RESTORE_CMDS[$k]}"
	done
	echo "Restored the original IRQ affinities and irqbalance state on ${#IRQ_RESTORE_CMDS[@]} hosts" | tee -a ${RESULTS_PATH}/irq_status.txt
}
trap restore_irqs EXIT
trap 'exit 1' HUP INT TERM

# Per server group (one per server NIC): the server NIC (from check_numa.sh) goes to the group's server vCPUs, and
# the client NIC it is routed through goes to the group's memtier vCPUs on every client
irq_ips=("${SERVER_IPS[@]:-$SERVER_IP}")
for g in "${!irq_ips[@]}"; do
        pin_irqs "${SSH_COMMAND:-bash -c}" "${SERVER_IFACES[$g]:-$SERVER_IFACE}" ${GROUP_CPUS[$g]:-$CPUS}
        if [[ ${SERVER_REMOTE} == true ]]; then
                for run in "bash -c" "${CLIENT_SSH_CMDS[@]}"; do
                        iface=$($run "ip -o -4 route get ${irq_ips[$g]} | grep -o 'dev [^ ]*' | cut -d' ' -f2" | tr -d '\r')
                        pin_irqs "$run" "$iface" ${GROUP_MEMTIER_CPUS[$g]:-$MEMTIER_CPUS}
                done
        fi
done
