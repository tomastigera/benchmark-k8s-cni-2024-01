#!/bin/bash

apt update
apt install -y wireguard

swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

cd $HOME

# Install blackswifthosting/statexec
wget https://github.com/blackswifthosting/statexec/releases/download/0.8.0/statexec-linux-amd64
chmod +x statexec-linux-amd64
mv statexec-linux-amd64 /usr/local/bin/statexec

# Install nuttcp
wget https://nuttcp.net/nuttcp/nuttcp-8.1.4/bin/nuttcp-8.1.4.x86_64
chmod +x nuttcp-8.1.4.x86_64
mv nuttcp-8.1.4.x86_64 /usr/local/bin/nuttcp
cd

# Install iperf3
wget https://github.com/InfraBuilder/iperf-bin/releases/download/iperf3-v3.16/iperf3-3.16-linux-amd64
chmod +x iperf3-3.16-linux-amd64
mv iperf3-3.16-linux-amd64 /usr/local/bin/iperf3

if [ "$USE_VLAN" = "y" ]; then
	modprobe 8021q
	echo "8021q" >> /etc/modules
	ip link add link bond0 name bond0.1001 type vlan id 7
	octet=${HOSTNAME: -1}
	ip addr add 192.168.2.${octet}/24 dev bond0.1001
	ip link set dev bond0.1001 up
	ip -d link show bond0.1001
fi
