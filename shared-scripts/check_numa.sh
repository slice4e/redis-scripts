#!/bin/bash

echo "Ensuring that the Redis server is on the same NUMA node as the network interface..." 
echo "Redis server NUMA nodes: $SERVER_NUMA_NODES" 

# The server's benchmark NIC is the interface that owns SERVER_IP (also used by set_irq.sh)
SERVER_IFACE=$(${SSH_COMMAND:-bash -c} "ip -o -4 addr show | awk '{split(\$4,a,\"/\"); if (a[1]==\"$SERVER_IP\") print \$2}'" | tr -d '\r')
echo "Server interface for $SERVER_IP: ${SERVER_IFACE:-not found}"

if [[ $SERVER_IP == "localhost" ]] || [[ $SERVER_IP == "127.0.0.1" ]] ; then
	echo "Using localhost for network. This is not typically recommended, since we cannot pin IRQs and may lead to performance differences. Even if using a single node, it is preferable to use a physical interface." 
else
	path="/sys/class/net/${SERVER_IFACE}/device/numa_node"
	if ! $SSH_COMMAND test -e $path; then
		echo "Unable to discover the numa node for the IRQ interface." 
	else
		IRQ_NUMA_NODE=$($SSH_COMMAND cat $path 2>&1 | tr -d '[:space:]')
		echo "IRQ_NUMA_NODE: $IRQ_NUMA_NODE"
		echo "IRQ Pinning: $SET_IRQ" 

		if [[ " $SERVER_NUMA_NODES " != *" $IRQ_NUMA_NODE "* ]] ; then
			echo "WARNING: The Redis server is running on a different numa node than the network interface." 
			echo "WARNING: The Redis server is running on a different numa node than the network interface." >> ${RESULTS_PATH}/WARNING.txt
		else
			echo "The Redis server is running on the same numa node as the network interface." 
		fi
	fi

fi


