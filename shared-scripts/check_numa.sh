#!/bin/bash

echo "Ensuring that the Redis server is on the same NUMA node as the network interface..." 
echo "Redis server is running on socket: $SERVER_SOCKET." 

if [[ $SERVER_IP == "localhost" ]] || [[ $SERVER_IP == "127.0.0.1" ]] ; then
	echo "Using localhost for network. This is not typically recommended, since we cannot pin IRQs and may lead to performance differences. Even if using a single node, it is preferable to use a physical interface." 
else
	IRQ_NUMA_NODE=`cat /sys/class/net/${IRQ_INTERFACE}/device/numa_node`
	if [[ $? == "0" ]] ; then 
		echo "The IRQ interface $IRQ_INTERFACE is on numa node: $IRQ_NUMA_NODE. IRQ pinning is $SET_IRQ" 

		if [[ $IRQ_NUMA_NODE != $SERVER_SOCKET ]] ; then
			echo "WARNING: The Redis server is running on a different numa node than the network interface." 
		else
			echo "The Redis server is running on the same numa node as the network interface." 
		fi

	else
		echo "Unable to discover the numa node for the IRQ interface." 
	fi
fi


