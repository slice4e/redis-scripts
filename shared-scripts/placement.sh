#!/bin/bash
# Process placement shared by the harnesses. A role (Redis servers, memtier clients) is placed either on whole
# NUMA nodes (<ROLE>_NODES: each process bound to one node, round-robin over the list) or on vCPUs
# (<ROLE>_CORES: one process per listed vCPU, memory on that vCPU's node; "all" leaves the processes unpinned).
# Lists accept ranges, e.g. 0-31,64-95. Find the nodes and their vCPUs with: lscpu | grep NUMA

# "0-3,8" -> "0 1 2 3 8"
expand_list(){
	local part out=()
	for part in ${1//,/ }; do
		if [[ $part == *-* ]]; then out+=($(seq ${part%-*} ${part#*-})); else out+=($part); fi
	done
	echo "${out[@]}"
}

# Usage: placement <ROLE> "<command prefix that runs a shell command on the host>" "<nodes>" "<cores>"
# Sets SLOTS (launch prefix per process, used round-robin), SLOT_CPUS (vCPUs the processes can run on) and
# SLOT_NODES (the NUMA nodes of those vCPUs).
placement(){
	local role=$1 run=$2 nodes=$3 cores=$4 n c map
	SLOTS=(); SLOT_CPUS=""; SLOT_NODES=""
	if [[ -n $nodes && -n $cores ]] || [[ -z $nodes && -z $cores ]]; then
		echo "Error: set exactly one of ${role}_NODES and ${role}_CORES."
		exit 1
	fi
	# "<vCPU> <node>" for every vCPU of the host
	map=$($run 'for d in /sys/devices/system/cpu/cpu[0-9]*/node[0-9]*; do c=${d%/node*}; echo ${c##*cpu} ${d##*node}; done' | tr -d '\r')
	if [[ -n $nodes ]]; then
		for n in $(expand_list $nodes); do
			c=$(awk -v n=$n '$2==n{print $1}' <<< "$map" | sort -n | xargs)
			[[ -z $c ]] && { echo "Error: NUMA node $n in ${role}_NODES has no vCPUs."; exit 1; }
			SLOTS+=("numactl -N $n -m $n")
			SLOT_CPUS+=" $c"
		done
	elif [[ $cores == all ]]; then
		SLOTS=("")
		SLOT_CPUS=$(awk '{print $1}' <<< "$map" | sort -n | xargs)
	else
		for c in $(expand_list $cores); do
			n=$(awk -v c=$c '$1==c{print $2}' <<< "$map")
			[[ -z $n ]] && { echo "Error: vCPU $c in ${role}_CORES does not exist."; exit 1; }
			SLOTS+=("numactl -m $n taskset -c $c")
			SLOT_CPUS+=" $c"
		done
	fi
	SLOT_CPUS=$(echo $SLOT_CPUS)
	SLOT_NODES=$(awk -v cpus=" $SLOT_CPUS " 'index(cpus, " "$1" "){print $2}' <<< "$map" | sort -un | xargs)
}

# memtier harnesses: places the Redis servers (host reached via $1) and the memtier processes (this host; up to $2
# per client, and additional clients reuse it), and checks that they fit.
# With several server IPs (SERVER_IPS, from a '|'-separated SERVER_IP: one group per server NIC), SERVER_NODES|
# SERVER_CORES and MEMTIER_NODES|MEMTIER_CORES hold one '|'-separated entry per group, and the servers alternate
# between the groups, so every server is reached through the NIC local to it and every client drives all groups.
# Sets SERVER_SLOTS/MEMTIER_SLOTS (all groups, located by *_SLOT_START/*_SLOT_COUNT), per group GROUP_CPUS,
# GROUP_NODES and GROUP_MEMTIER_CPUS, over all groups CPUS, SERVER_NUMA_NODES and MEMTIER_CPUS, and MEMTIER_PROCS.
place_servers_and_memtier(){
	local run=$1 per_client=$2 c g var n mcores
	[[ ${#SERVER_IPS[@]} -eq 0 ]] && SERVER_IPS=("$SERVER_IP")
	NUM_GROUPS=${#SERVER_IPS[@]}
	for var in SERVER_NODES SERVER_CORES MEMTIER_NODES MEMTIER_CORES; do
		n=$(awk -F'|' '{print NF}' <<< "${!var}")
		if [[ -n ${!var} && $n -ne $NUM_GROUPS ]]; then
			echo "Error: $var has $n '|'-separated entries, but SERVER_IP has $NUM_GROUPS."
			exit 1
		fi
	done
	SERVER_SLOTS=(); SERVER_SLOT_START=(); SERVER_SLOT_COUNT=(); GROUP_CPUS=(); GROUP_NODES=(); CPUS=""
	MEMTIER_SLOTS=(); MEMTIER_SLOT_START=(); MEMTIER_SLOT_COUNT=(); GROUP_MEMTIER_CPUS=(); MEMTIER_CPUS=""
	for ((g = 0; g < NUM_GROUPS; g++)); do
		placement SERVER "$run" "$(group_field "$SERVER_NODES" $g)" "$(group_field "$SERVER_CORES" $g)"
		SERVER_SLOT_START+=(${#SERVER_SLOTS[@]}); SERVER_SLOT_COUNT+=(${#SLOTS[@]}); SERVER_SLOTS+=("${SLOTS[@]}")
		GROUP_CPUS+=("$SLOT_CPUS"); GROUP_NODES+=("$SLOT_NODES"); CPUS+=" $SLOT_CPUS"
		mcores=$(group_field "$MEMTIER_CORES" $g)
		placement MEMTIER "bash -c" "$(group_field "$MEMTIER_NODES" $g)" "$mcores"
		MEMTIER_SLOT_START+=(${#MEMTIER_SLOTS[@]}); MEMTIER_SLOT_COUNT+=(${#SLOTS[@]}); MEMTIER_SLOTS+=("${SLOTS[@]}")
		GROUP_MEMTIER_CPUS+=("$SLOT_CPUS"); MEMTIER_CPUS+=" $SLOT_CPUS"
		[[ $NUM_GROUPS -gt 1 ]] && echo "Group $g (${SERVER_IPS[$g]}): Redis server vCPUs: ${GROUP_CPUS[$g]}; memtier vCPUs: $SLOT_CPUS"
		# Servers alternate between the groups, so a group gets at most ceil(n / NUM_GROUPS) of any n servers
		n=$(( (NUM_SERVERS - g + NUM_GROUPS - 1) / NUM_GROUPS ))
		if [[ -n $SERVER_CORES && ${SERVER_SLOT_COUNT[$g]} -lt $n ]]; then
			echo "SERVER_CORES lists ${SERVER_SLOT_COUNT[$g]} vCPUs for group $g, fewer than its $n Redis servers."
			exit 1
		fi
		n=$(( (per_client + NUM_GROUPS - 1) / NUM_GROUPS ))
		if [[ -n $mcores && $mcores != all && ${MEMTIER_SLOT_COUNT[$g]} -lt $n ]]; then
			echo "Each client drives up to $n Redis servers of group $g, but MEMTIER_CORES lists only ${MEMTIER_SLOT_COUNT[$g]} vCPUs for it."
			exit 1
		fi
	done
	CPUS=$(echo $CPUS); MEMTIER_CPUS=$(echo $MEMTIER_CPUS)
	SERVER_NUMA_NODES=$(echo ${GROUP_NODES[@]} | tr ' ' '\n' | sort -un | xargs)
	echo "Redis server vCPUs: $CPUS"
	echo "Memtier vCPUs: $MEMTIER_CPUS"
	if [[ ${SERVER_REMOTE} != true && $MEMTIER_CORES != *all* ]]; then
		for c in $CPUS; do
			if [[ " $MEMTIER_CPUS " == *" $c "* ]]; then
				echo "Redis servers and memtier would share vCPU $c on this host; give them disjoint placements."
				exit 1
			fi
		done
	fi
	MEMTIER_PROCS=$(seq 0 $((NUM_SERVERS - 1)))
}

# Entry <g> (0-based) of a '|'-separated per-group setting
group_field(){ [[ -n $1 ]] && cut -d'|' -f$(($2 + 1)) <<< "$1"; }

# Group, launch prefix and IP of Redis server <i> (1-based)
server_group(){ echo $(( ($1 - 1) % NUM_GROUPS )); }
server_slot(){ local g=$(server_group $1); echo "${SERVER_SLOTS[$(( SERVER_SLOT_START[g] + ($1 - 1) / NUM_GROUPS % SERVER_SLOT_COUNT[g] ))]}"; }
server_ip(){ echo "${SERVER_IPS[$(server_group $1)]}"; }

# Launch prefix for the memtier process at position <n> of a client's servers, which drives Redis server <i>
memtier_slot(){ local g=$(server_group $2); echo "${MEMTIER_SLOTS[$(( MEMTIER_SLOT_START[g] + $1 / NUM_GROUPS % MEMTIER_SLOT_COUNT[g] ))]}"; }
