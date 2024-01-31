#!/bin/bash
cd /tmp
tar vxf /tmp/re.tar
echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
sudo mv /etc/resolv.conf /etc/resolv.conf.orig
sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo service systemd-resolved restart
/tmp/install.sh -y