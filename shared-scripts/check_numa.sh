#!/bin/bash

bash_encode () {
  esc=${1@Q}
  echo "${esc:2:-1}"
}

echo "Ensuring that the Redis server is on the same NUMA node as the network interface..." 
echo "SERVER_SOCKET: $SERVER_SOCKET" 

if [[ $SERVER_IP == "localhost" ]] || [[ $SERVER_IP == "127.0.0.1" ]] ; then
	echo "Using localhost for network. This is not typically recommended, since we cannot pin IRQs and may lead to performance differences. Even if using a single node, it is preferable to use a physical interface." 
else
	path="/sys/class/net/${IRQ_INTERFACE}/device/numa_node"
	if ! $SSH_COMMAND test -e $path; then
		echo "Unable to discover the numa node for the IRQ interface." 
	else
		IRQ_NUMA_NODE=$($SSH_COMMAND cat $path 2>&1) 
		#bash_encode $IRQ_NUMA_NODE
		#IRQ_NUMA_NODE=`echo $IRQ_NUMA_NODE | tr -d '\r'`
		IRQ_NUMA_NODE=`echo $IRQ_NUMA_NODE | tr -d '[:space:]'`
		#bash_encode $IRQ_NUMA_NODE
		echo "IRQ_NUMA_NODE: $IRQ_NUMA_NODE"
		echo "IRQ Pinning: $SET_IRQ" 

		if [[ $IRQ_NUMA_NODE != $SERVER_SOCKET ]] ; then
			echo "WARNING: The Redis server is running on a different numa node than the network interface." 
			echo "WARNING: The Redis server is running on a different numa node than the network interface." >> ${RESULTS_PATH}/WARNING.txt
		else
			echo "The Redis server is running on the same numa node as the network interface." 
		fi
	fi

fi


