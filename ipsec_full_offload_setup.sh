#!/bin/bash
# NGC Certification IPsec full offload setup v0.4
# Owner: dorko@nvidia.com
#

# host ip should be already configured
CLIENT_TRUSTED=$1
CLIENT_DEVICE=$2
SERVER_TRUSTED=$3
SERVER_DEVICE=$4
LOCAL_BF=$5
REMOTE_BF=$6
MTU_SIZE=$7

PF0=p0
VF0_REP='pf0hpf'
KEY1=0x6b58214a0ded001ed0fec88131addb4eba92301e8afa50287dd75e4ed89d7521070831e4
KEY2=0xe7276f90cbbdfc8ca1d86fdb22f99c69da3c524f28ef4fddbcc0606f202d47828b7ddfa6
REQID1=0x0d2425dd
REQID2=0xb17c0ba5

setup_bf(){
	local_IP=$1
	remote_IP=$2
	in_key=$3
	out_key=$4
	in_reqid=$5
	out_reqid=$6
	bf_name=$7
	mtu=$8

	# Restricting host and setting interfaces
	# To revert privilges (host restriction) use the following command:
	# mlxprivhost -d /dev/mst/${pciconf} p
	ssh ${bf_name} sudo -i /bin/bash mst start
	pciconf=$(ssh ${bf_name} sudo -i find /dev/mst/ | grep -G  "pciconf0$")
	ssh ${bf_name} sudo -i /bin/bash mlxprivhost -d ${pciconf} r --disable_port_owner
	ssh ${bf_name} sudo -i ifconfig ${PF0} mtu ${MTU_SIZE}

	# Enable IPsec full offload
	ssh ${bf_name} sudo -i /bin/bash << 'EOF'
ip xfrm state flush
ip xfrm policy flush
ovs-appctl exit --cleanup
/sbin/mlnx-sf -a show | grep -q 'UUID:' && \
{
echo "Remove Pre-set Subfunctions (by UUID)";
for sf_uuid in `/sbin/mlnx-sf -a show | grep 'UUID:' | awk '{print $2}' 2>/dev/null`
do
/sbin/mlnx-sf -a remove --uuid $sf_uuid
done
}

/sbin/mlnx-sf -a show | grep -q 'SF Index:' && \
{
echo "Remove Pre-set Subfunctions (By Index)";
for sf_index in `/sbin/mlnx-sf -a show | grep 'SF Index:' | awk '{print $3}' 2>/dev/null`
do
/sbin/mlnx-sf -a delete --sfindex $sf_index
SF_REMOVED=1
done
}
devlink dev eswitch set pci/0000:03:00.0 mode legacy
echo full > /sys/class/net/p0/compat/devlink/ipsec_mode
echo dmfs > /sys/bus/pci/devices/0000\:03\:00.0/net/p0/compat/devlink/steering_mode
devlink dev eswitch set pci/0000:03:00.0 mode switchdev
systemctl restart openvswitch-switch.service
EOF

	echo setting IPsec rules
	# Add states and policies on ARM host for IPsec.
    ssh ${bf_name} sudo -i /bin/bash << EOF
/opt/mellanox/iproute2/sbin/ip xfrm state add src ${local_IP}/24 dst ${remote_IP}/24 proto esp spi ${out_reqid} reqid ${out_reqid} mode transport aead 'rfc4106(gcm(aes))' ${out_key} 128 full_offload dev p0 dir out sel src ${local_IP} dst ${remote_IP}
/opt/mellanox/iproute2/sbin/ip xfrm state add src ${remote_IP}/24 dst ${local_IP}/24 proto esp spi ${in_reqid} reqid ${in_reqid} mode transport aead 'rfc4106(gcm(aes))' ${in_key} 128 full_offload dev p0 dir in sel src ${remote_IP} dst ${local_IP}
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${local_IP} dst ${remote_IP} dir out tmpl src ${local_IP}/24 dst ${remote_IP}/24 proto esp reqid ${out_reqid} mode transport
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${remote_IP} dst ${local_IP} dir in tmpl src ${remote_IP}/24 dst ${local_IP}/24 proto esp reqid ${in_reqid} mode transport
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${remote_IP} dst ${local_IP} dir fwd tmpl src ${remote_IP}/24 dst ${local_IP}/24 proto esp reqid ${in_reqid} mode transport
EOF
}

CLIENT_NETDEV=`ssh ${CLIENT_TRUSTED} ls /sys/class/infiniband/${CLIENT_DEVICE}/device/net`
SERVER_NETDEV=`ssh ${SERVER_TRUSTED} ls /sys/class/infiniband/${SERVER_DEVICE}/device/net`

CLIENT_IP=$(ssh $CLIENT_TRUSTED "ip a sh $CLIENT_NETDEV | grep -m1 -ioP  \"(?<=inet )\d+\.\d+\.\d+\.\d+\"")
SERVER_IP=$(ssh $SERVER_TRUSTED "ip a sh $SERVER_NETDEV | grep -m1 -ioP  \"(?<=inet )\d+\.\d+\.\d+\.\d+\"")

if [ -z "$CLIENT_IP" ]; then
    echo "Can't find client IP, did you set IPv4 addresses?"
    exit 1
fi

if [ -z "$SERVER_IP" ]; then
    echo "Can't find server IP, did you set IPv4 addresses?"
    exit 1
fi

REMOTE_BF_IP=$SERVER_IP
LOCAL_BF_IP=$CLIENT_IP

echo configure ipsec
setup_bf ${LOCAL_BF_IP} ${REMOTE_BF_IP} ${KEY1} ${KEY2} ${REQID1} ${REQID2} ${LOCAL_BF} ${MTU_SIZE}
setup_bf ${REMOTE_BF_IP} ${LOCAL_BF_IP} ${KEY2} ${KEY1} ${REQID2} ${REQID1} ${REMOTE_BF} ${MTU_SIZE}

ssh ${CLIENT_TRUSTED} ifconfig ${CLIENT_NETDEV} ${CLIENT_IP}/24 mtu $(( ${MTU_SIZE} - 500 )) up
ssh ${SERVER_TRUSTED} ifconfig ${SERVER_NETDEV} ${SERVER_IP}/24 mtu $(( ${MTU_SIZE} - 500 )) up
