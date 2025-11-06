#!/bin/bash

# Reusable function to setup SSH connection to a remote host
# Usage: setup_ssh_to_host <ip_address> <login_id> <ssh_key_path> <ssh_key_name> <host_description>
# Returns: Sets up passwordless SSH and returns 0 on success, 1 on failure
setup_ssh_to_host() {
	local target_ip=$1
	local target_login=$2
	local target_key_path=$3
	local target_key_name=$4
	local host_desc=$5  # e.g., "server" or "client"
	
	local ssh_cmd="ssh -t -o PreferredAuthentications=publickey -i ${target_key_path}/${target_key_name} -q ${target_login}@${target_ip}"
	
	echo "Logging in as \"${target_login}\" to $host_desc $target_ip"
	$ssh_cmd 'exit'

	if [ "$?" -ne 0 ] ; then
		read -p "Couldn't connect to $host_desc. Do you want to create an ssh-key for passwordless login? [Y]: " GenerateKey
		GenerateKey=${GenerateKey:-Y}

		case $GenerateKey in
		    y|Y)
			echo "Generating the key..."
			if [ ! -f "${target_key_path}/${target_key_name}" ]; then
				ssh-keygen -t rsa -b 4096 -f ${target_key_path}/${target_key_name} -N "" -q -C ${target_login}@${target_ip}
			fi
			echo "Copying key to the $host_desc..."
			ssh-copy-id -i ${target_key_path}/${target_key_name} ${target_login}@${target_ip}

			echo "Logging in as \"${target_login}\" to $host_desc $target_ip"
			$ssh_cmd 'exit'
			if [ "$?" -ne 0 ] ; then
				echo "Is root SSH login disabled? We can enable by modifying: /etc/ssh/sshd_config on the $host_desc." 
				echo "Quiting..."
				return 1
			else
				echo "SSH connection to $host_desc $target_ip successful"
				return 0
			fi
		    ;;
		    *)
			echo "Quiting..."
			return 1
		    ;;
		esac
	else
		echo "SSH connection to $host_desc $target_ip verified"
		return 0
	fi
}

SSH_CONNECTED=false
SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${SERVER_IP}"

if [[ ${SERVER_REMOTE} == false ]] ; then
	SSH_COMMAND=""
	SSH_CONNECTED=true
fi

# Setup SSH to the Redis server
if [[ ${SERVER_REMOTE} == true ]] ; then
	if setup_ssh_to_host "${SERVER_IP}" "${LOGIN_ID}" "${SSH_KEY_PATH}" "${SSH_KEY_NAME}" "server"; then
		SSH_CONNECTED=true
	else
		SSH_CONNECTED=false
	fi
fi

# Setup SSH to additional memtier client machines (if configured)
# This is only executed when sourced from run_all.sh in multi-client mode
if [[ -n "${ADDITIONAL_CLIENT_IPS}" ]]; then
	echo ""
	echo "Setting up SSH to additional memtier client machines..."
	
	IFS=',' read -ra CLIENT_IPS_ARRAY <<< "$ADDITIONAL_CLIENT_IPS"
	
	for ip in "${CLIENT_IPS_ARRAY[@]}"; do
		if ! setup_ssh_to_host "${ip}" "${LOGIN_ID}" "${SSH_KEY_PATH}" "${SSH_KEY_NAME}" "client"; then
			echo "Failed to setup SSH to client $ip. Exiting..."
			exit 1
		fi
	done
	
	echo "SSH setup complete for all additional client machines"
fi
