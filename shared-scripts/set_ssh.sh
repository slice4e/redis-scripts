#!/bin/bash

SSH_CONNECTED=false
SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${SERVER_IP}"

echo "Logging in as \"${LOGIN_ID}\" to $SERVER_IP"
$SSH_COMMAND 'exit'

if [ "$?" -ne 0 ] ; then
        SSH_CONNECTED=false

        read -p "Couldn't connect to server. Do you want to create an ssh-key for the paswordless login? [Y]: " GenerateKey
        GenerateKey=${GenerateKey:-Y}

        case $GenerateKey in
            y|Y)
                echo "Genarating the key..."
                ssh-keygen -t rsa -b 4096 -f ${SSH_KEY_PATH}/${SSH_KEY_NAME} -N "" -q -C ${LOGIN_ID}@${SERVER_IP}
                echo "Copying key to the server..."
                ssh-copy-id -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}

                echo "Logging in as \"${LOGIN_ID}\" to $SERVER_IP"
                $SSH_COMMAND 'exit'
                if [ "$?" -ne 0 ] ; then
                    SSH_CONNECTED=false
                else
                    SSH_CONNECTED=true
                fi
            ;;
            *)
                echo "Quiting..."
                exit 1
            ;;
        esac
else
        SSH_CONNECTED=true
fi

if [ "$SSH_CONNECTED" != "true" ]; then
    echo "Couldn't connect to server, please verify whether server is up or your ssh passwordless login to \"${SERVER_IP}\" is setup properly."
    exit 1
fi

echo "SSH Connection is Successfull!"


