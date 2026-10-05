#!/bin/bash

# Drivers such as mlx5 name their IRQs by PCI address, not by interface, so prefer the device's MSI vector list
irq_list_cmd(){
	echo "ls /sys/class/net/$1/device/msi_irqs 2>/dev/null || grep $1 /proc/interrupts | awk -F ':' '{print \$1}'"
}

#Expects one or more cpus to which to assign the IRQs
set_irq(){
	if [ "$1" != "" ]; then
		echo "Stopping the OS IRQ balancer: "
		status=$(sudo systemctl --no-pager status irqbalance.service)
		echo "$status" >> ${RESULTS_PATH}/irq_status.txt
		status=$(sudo systemctl --no-pager stop irqbalance.service)
		status=$(sudo systemctl --no-pager status irqbalance.service)
		echo "$status" >> ${RESULTS_PATH}/irq_status.txt

		echo "Assigning IRQ interruptions to CPUs $@ ...."
		interrupts=$(bash -c "$(irq_list_cmd $IRQ_SET_INTERFACE)")
		echo "$IRQ_SET_INTERFACE: $(echo $interrupts | wc -w) IRQs" >> ${RESULTS_PATH}/irq_status.txt
		for i in $interrupts
		do
			echo $@ | sudo tee /proc/irq/${i}/smp_affinity_list > /dev/null
		done

		for i in $interrupts
		do
			cat /proc/irq/${i}/smp_affinity_list >> ${RESULTS_PATH}/irq_status.txt
		done

	else
		echo "Please pass at least one argument for CPU: set_irq.sh 0" 
	fi
}

#Expects one or more cpus to which to assign the IRQs
set_irq_remote(){
	if [ "$1" != "" ]; then

		echo "Stopping the OS IRQ balancer: "
		# SSH_COMMAND uses ssh -t, so without --no-pager systemctl opens less and waits forever
		status=$($SSH_COMMAND "sudo systemctl --no-pager status irqbalance.service")
		echo "$status" >> ${RESULTS_PATH}/irq_status.txt
		status=$($SSH_COMMAND "sudo systemctl --no-pager stop irqbalance.service")
		status=$($SSH_COMMAND "sudo systemctl --no-pager status irqbalance.service")
		echo "$status" >> ${RESULTS_PATH}/irq_status.txt

		echo "Assigning IRQ interruptions to CPUs $@ ...."
		interrupts=$($SSH_COMMAND "$(irq_list_cmd $IRQ_SET_INTERFACE)" | tr -d '\r')
		echo "$IRQ_SET_INTERFACE: $(echo $interrupts | wc -w) IRQs" >> ${RESULTS_PATH}/irq_status.txt
		for i in $interrupts
		do
			cmd="echo $@ | sudo tee /proc/irq/${i}/smp_affinity_list > /dev/null"
			$($SSH_COMMAND $cmd)
		done

		for i in $interrupts
		do
			cmd="cat /proc/irq/${i}/smp_affinity_list"
			status=$($SSH_COMMAND $cmd) 
			echo $status >> ${RESULTS_PATH}/irq_status.txt
		done

	else
		echo "Please pass at least one argument for CPU: set_irq.sh 0" 
	fi
}


if [[ ${SERVER_REMOTE} == true ]] ; then
	echo "Setting IRQs on the Redis server" | tee -a ${RESULTS_PATH}/irq_status.txt
	IRQ_SET_INTERFACE=$IRQ_INTERFACE
	set_irq_remote $CPUS
	echo "Setting IRQs on the memtier client" | tee -a ${RESULTS_PATH}/irq_status.txt
	IRQ_SET_INTERFACE=$IRQ_INTERFACE_MEMTIER
	set_irq $MEMTIER_CPUS
else
	echo "Setting IRQs on the Redis server" | tee -a ${RESULTS_PATH}/irq_status.txt
	IRQ_SET_INTERFACE=$IRQ_INTERFACE
	set_irq $CPUS
fi
