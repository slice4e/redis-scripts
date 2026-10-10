#!/bin/bash

echo "Ensuring that the Redis server is on the same NUMA node as the network interface..." 
echo "Redis server NUMA nodes: $SERVER_NUMA_NODES" 

# Each server group's benchmark NIC is the interface that owns its IP (also used by set_irq.sh)
SERVER_IFACES=()
check_ips=("${SERVER_IPS[@]:-$SERVER_IP}")
for g in "${!check_ips[@]}"; do
	ip=${check_ips[$g]}
	nodes=${GROUP_NODES[$g]:-$SERVER_NUMA_NODES}
	iface=$(${SSH_COMMAND:-bash -c} "ip -o -4 addr show | awk '{split(\$4,a,\"/\"); if (a[1]==\"$ip\") print \$2}'" | tr -d '\r')
	SERVER_IFACES+=("$iface")
	echo "Server interface for $ip: ${iface:-not found}"

	if [[ $ip == "localhost" ]] || [[ $ip == "127.0.0.1" ]] ; then
		echo "Using localhost for network. This is not typically recommended, since we cannot pin IRQs and may lead to performance differences. Even if using a single node, it is preferable to use a physical interface." 
	else
		path="/sys/class/net/${iface}/device/numa_node"
		if ! $SSH_COMMAND test -e $path; then
			echo "Unable to discover the numa node for the IRQ interface." 
		else
			IRQ_NUMA_NODE=$($SSH_COMMAND cat $path 2>&1 | tr -d '[:space:]')
			echo "IRQ_NUMA_NODE: $IRQ_NUMA_NODE"
			echo "IRQ Pinning: $SET_IRQ" 

			if [[ " $nodes " != *" $IRQ_NUMA_NODE "* ]] ; then
				echo "WARNING: The Redis server is running on a different numa node than the network interface $iface." 
				echo "WARNING: The Redis server is running on a different numa node than the network interface $iface." >> ${RESULTS_PATH}/WARNING.txt
			else
				echo "The Redis server is running on the same numa node as the network interface $iface." 
			fi
		fi
	fi
done
SERVER_IFACE=${SERVER_IFACES[0]}



