#!/bin/bash

#Expects one or more cpus to which to assign the IRQs

if [ "$1" != "" ]; then

	echo "Assigning IRQ interruptions to CPUs $@ ...."
	interrupts=$($SSH_COMMAND "cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print \$1}'")
	for i in $interrupts
	do
		cmd="echo $@ > /proc/irq/${i:0:-1}/smp_affinity_list"
		$SSH_COMMAND $cmd
	done

	echo "Printing assigned cpu numbers for each interrupts..."
	interrupts=$($SSH_COMMAND "cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print \$1}'")
	for i in $interrupts
	do
		cmd="cat /proc/irq/${i:0:-1}/smp_affinity_list"
		$SSH_COMMAND $cmd
	done

else
	echo "Please pass at least one argument for CPU: set_irq.sh 0" 
fi


