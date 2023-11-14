#!/bin/bash

#Expects one or more cpus to which to assign the IRQs

if [[ ${SERVER_REMOTE} == true ]] ; then
	if [ "$1" != "" ]; then

		echo "Stopping the OS IRQ balancer: "
		status=$($SSH_COMMAND "systemctl status irqbalance.service")
		echo "$status" >> ${RESULTS_PATH}/irq_status.txt
		status=$($SSH_COMMAND "systemctl stop irqbalance.service")
		status=$($SSH_COMMAND "systemctl status irqbalance.service")
		echo "$status" >> ${RESULTS_PATH}/irq_status.txt

		echo "Assigning IRQ interruptions to CPUs $@ ...."
		interrupts=$($SSH_COMMAND "cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print \$1}' | tr -d '\r' | tr -d '\n' ")
		for i in $interrupts
		do
			cmd="echo $@ > /proc/irq/${i}/smp_affinity_list"
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
else
	if [ "$1" != "" ]; then
		echo "Stopping the OS IRQ balancer: "
		status=$(systemctl status irqbalance.service)
		echo "$status" >> ${RESULTS_PATH}/irq_status.txt
		status=$(systemctl stop irqbalance.service)
		status=$(systemctl status irqbalance.service)
		echo "$status" >> ${RESULTS_PATH}/irq_status.txt

		echo "Assigning IRQ interruptions to CPUs $@ ...."
		interrupts=$(cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print $1}')
		for i in $interrupts
		do
			echo $@ > /proc/irq/${i}/smp_affinity_list
		done

		for i in $interrupts
		do
			cat /proc/irq/${i}/smp_affinity_list >> ${RESULTS_PATH}/irq_status.txt
		done

	else
		echo "Please pass at least one argument for CPU: set_irq.sh 0" 
	fi
fi
