#!/bin/bash

#Expects one or more cpus to which to assign the IRQs

if [[ ${SERVER_REMOTE} == true ]] ; then
	if [ "$1" != "" ]; then

		echo "Assigning IRQ interruptions to CPUs $@ ...."
		interrupts=$($SSH_COMMAND "cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print \$1}'" | tr -d '\r')
		for i in $interrupts
		do
			cmd="echo $@ > /proc/irq/${i}/smp_affinity_list"
			$($SSH_COMMAND $cmd)
		done

		echo "Printing assigned cpu numbers for each interrupts..."
		interrupts=$($SSH_COMMAND "cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print \$1}'" | tr -d '\r' )
		for i in $interrupts
		do
			cmd="cat /proc/irq/${i}/smp_affinity_list"
			$($SSH_COMMAND $cmd)
		done

	else
		echo "Please pass at least one argument for CPU: set_irq.sh 0" 
	fi
else
	if [ "$1" != "" ]; then

		echo "Assigning IRQ interruptions to CPUs $@ ...."
		interrupts=$(cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print $1}')
		for i in $interrupts
		do
			echo $@ > /proc/irq/${i}/smp_affinity_list
		done

		echo "Printing assigned cpu numbers for each interrupts..."
		interrupts=$(cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print $1}')
		for i in $interrupts
		do
			cat /proc/irq/${i}/smp_affinity_list
		done

	else
		echo "Please pass at least one argument for CPU: set_irq.sh 0" 
	fi
fi
