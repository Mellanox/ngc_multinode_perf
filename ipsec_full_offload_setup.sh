#!/bin/bash
# NGC Certification IPsec full offload setup v0.1
#Owner: dorko@nvidia.com
#

#host ip should be already configured
LOCAL_BF=$1
REMOTE_BF=$2
REMOTE_BF_IP=192.168.1.65
LOCAL_BF_IP=192.168.1.64
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
#source from: https://community.mellanox.com/s/article/ConnectX-6DX-Bluefield-2-IPsec-HW-Full-Offload-Configuration-Guide
    sshpass -p centos ssh -o StrictHostKeyChecking=no -l root ${bf_name} /bin/bash << EOF
#add states and policies on ARM host for IPsec.
/opt/mellanox/iproute2/sbin/ip xfrm state add src ${local_IP}/24 dst ${remote_IP}/24 proto esp spi ${out_reqid} reqid ${out_reqid} mode transport aead 'rfc4106(gcm(aes))' ${out_key} 128 full_offload dev p0 dir out sel src ${local_IP} dst ${remote_IP}
/opt/mellanox/iproute2/sbin/ip xfrm state add src ${remote_IP}/24 dst ${local_IP}/24 proto esp spi ${in_reqid} reqid ${in_reqid} mode transport aead 'rfc4106(gcm(aes))' ${in_key} 128 full_offload dev p0 dir in sel src ${remote_IP} dst ${local_IP}
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${local_IP} dst ${remote_IP} dir out tmpl src ${local_IP}/24 dst 192.168.1.65/24 proto esp reqid ${out_reqid} mode transport
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${remote_IP} dst ${local_IP} dir in tmpl src ${remote_IP}/24 dst ${local_IP}/24 proto esp reqid ${in_reqid} mode transport
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${remote_IP} dst ${local_IP} dir fwd tmpl src ${remote_IP}/24 dst ${local_IP}/24 proto esp reqid ${in_reqid} mode transport

#uping interfaces
ip a a ${local_IP}/24 brd + dev ${PF0}; ip l s dev ${PF0} up ; ifconfig ${PF0} mtu 2000
ifconfig ${VF0_REP} up
# adding hw-tc-offload on
ethtool -K ${VF0_REP} hw-tc-offload on
ethtool -K ${PF0} hw-tc-offload on

#ovs set up Vxlan
service openvswitch start
ovs-vsctl del-br ovs-br
ovs-vsctl add-br ovs-br
ovs-vsctl add-port ovs-br ${VF0_REP}
ovs-vsctl add-port ovs-br vxlan11 -- set interface vxlan11 type=vxlan options:local_ip=${local_IP} options:remote_ip=${remote_IP} options:key=100 options:dst_port=4789
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
service openvswitch restart
ifconfig ovs-br up

EOF
}

setup_bf ${LOCAL_BF_IP} ${REMOTE_BF_IP} ${KEY1} ${KEY2} ${REQID1} ${REQID2} ${LOCAL_BF}
setup_bf ${REMOTE_BF_IP} ${LOCAL_BF_IP} ${KEY2} ${KEY1} ${REQID2} ${REQID1} ${REMOTE_BF}

