#!/bin/bash
# Pins the benchmark NIC's IRQs to the benchmark CPUs on the server and on every memtier client.
# irqbalance is stopped on those hosts and left stopped.

# Usage: pin_irqs "<command prefix that runs a shell command on the host>" <interface> <cpu>...
pin_irqs(){
	local run=$1 iface=$2
	shift 2
	# Drivers such as mlx5 name their IRQs by PCI address, not by interface, so use the device's MSI vector list
	local irqs=$($run "ls /sys/class/net/$iface/device/msi_irqs 2>/dev/null" | tr -d '\r')
	$run "sudo systemctl stop irqbalance.service; for i in $irqs; do echo $* | sudo tee /proc/irq/\$i/smp_affinity_list > /dev/null; done"
	local affinity=$($run "for i in $irqs; do cat /proc/irq/\$i/smp_affinity_list; done | sort -u" | tr -d '\r' | xargs)
	echo "$($run hostname | tr -d '\r') $iface: $(echo $irqs | wc -w) IRQs pinned to $affinity"
}

# A client's benchmark NIC is the interface it routes SERVER_IP through; SERVER_IFACE comes from check_numa.sh
CLIENT_IFACE_CMD="ip -o -4 route get $SERVER_IP | grep -o 'dev [^ ]*' | cut -d' ' -f2"

pin_irqs "${SSH_COMMAND:-bash -c}" "$SERVER_IFACE" $CPUS | tee -a ${RESULTS_PATH}/irq_status.txt
if [[ ${SERVER_REMOTE} == true ]]; then
	for run in "bash -c" "${CLIENT_SSH_CMDS[@]}"; do
		pin_irqs "$run" "$($run "$CLIENT_IFACE_CMD" | tr -d '\r')" $MEMTIER_CPUS | tee -a ${RESULTS_PATH}/irq_status.txt
	done
fi
