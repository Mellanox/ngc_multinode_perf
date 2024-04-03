#!/bin/bash
# Owner: rzilberzwaig@nvidia.com

set -eE

LOCAL_BF=$1 # DPU IP / name
device1=$2 # p0 / p1
REMOTE_BF=$3 # DPU IP / name
device2=$4 # p0 / p1


scriptdir="$(dirname "$0")"
source "${scriptdir}/common.sh"

update_mlnx_bf_conf() {
    local client="$1"  # Accept the client variable as an argument
    local mlnx_conf="/etc/mellanox/mlnx-bf.conf"
    local ipsec_setting="IPSEC_FULL_OFFLOAD=\"yes\""
    local current_setting=$(ssh "$client" "sudo grep -o 'IPSEC_FULL_OFFLOAD=\".*\"' \"$mlnx_conf\" | tail -n 1 | cut -d '\"' -f 2")


    if [ -z "$current_setting" ]; then
        echo "$ipsec_setting" >> "$mlnx_conf"
        echo "Added $ipsec_setting to $mlnx_conf"
        ssh "$client" "sudo systemctl stop mlx-regex; /etc/init.d/openibd restart; systemctl restart mlx-regex"
    elif [ "$current_setting" = "no" ]; then
        ssh "$client" "sudo sed -i 's/IPSEC_FULL_OFFLOAD=\"no\"/IPSEC_FULL_OFFLOAD=\"yes\"/' \"$mlnx_conf\""
        echo "Changed IPSEC_FULL_OFFLOAD setting to 'yes' in $mlnx_conf on $client"
        ssh "$client" "sudo systemctl stop mlx-regex; /etc/init.d/openibd restart; systemctl restart mlx-regex"
    else
        echo "IPSEC_FULL_OFFLOAD is already set to 'yes' in $mlnx_conf on $client"
    fi
}

update_mlnx_bf_conf_revert() {
    local client="$1"  # Accept the client variable as an argument
    local mlnx_conf="/etc/mellanox/mlnx-bf.conf"
    local ipsec_setting="IPSEC_FULL_OFFLOAD=\"no\""
    local current_setting=$(ssh "$client" "sudo grep -o 'IPSEC_FULL_OFFLOAD=\".*\"' \"$mlnx_conf\" | tail -n 1 | cut -d '\"' -f 2")

    if [ -z "$current_setting" ]; then
        echo "$ipsec_setting" >> "$mlnx_conf"
        echo "Added $ipsec_setting to $mlnx_conf"
        ssh "$client" "sudo systemctl stop mlx-regex; /etc/init.d/openibd restart; systemctl restart mlx-regex"
    elif [ "$current_setting" = "yes" ]; then
        ssh "$client" "sudo sed -i 's/IPSEC_FULL_OFFLOAD=\"yes\"/IPSEC_FULL_OFFLOAD=\"no\"/' \"$mlnx_conf\""
        echo "Changed IPSEC_FULL_OFFLOAD setting to 'no' in $mlnx_conf on $client"
        ssh "$client" "sudo systemctl stop mlx-regex; /etc/init.d/openibd restart; systemctl restart mlx-regex"
    else
        echo "IPSEC_FULL_OFFLOAD is already set to 'no' in $mlnx_conf on $client"
    fi
}

 
ip_last_octet=0
generate_next_ip() {
  ((ip_last_octet < 255 )) && ((ip_last_octet+=1)) || echo "Last octet exceeds 255"
  local_IP="192.169.${ip_last_octet}.1"
  #((ip_last_octet < 255 )) && ((ip_last_octet+=1)) || echo "Last octet exceeds 255"
  remote_IP="192.169.${ip_last_octet}.2"

}

generete_key() {
    local key
    key="0x$(tr -cd '0-9a-f' < /dev/urandom | head -c72)"
    echo $key
}

generete_req() {
    local key
    key="0x$(tr -cd '0-9a-f' < /dev/urandom | head -c8)"
    echo $key
}

set_ipsec_rules() {
    local client=$1 # DPU IP / name
    local device=$2 # p0 / p1
    local local_IP=$3 # of p0 / p1
    local remote_IP=$4 # of p0 / p1
    local in_key=$5
    local out_key=$6
    local in_reqid=$7
    local out_reqid=$8
    local offload_type=$9

    ssh "${client}" "sudo ovs-appctl exit --cleanup"
    ssh "${client}" "sudo /opt/mellanox/iproute2/sbin/ip xfrm state add src ${local_IP}/24 dst ${remote_IP}/24 proto esp spi ${out_reqid} reqid ${out_reqid} mode transport aead 'rfc4106(gcm(aes))' ${out_key} 128 ${offload_type} dev ${device} dir out sel src ${local_IP}/24 dst ${remote_IP}/24"
    ssh "${client}" "sudo /opt/mellanox/iproute2/sbin/ip xfrm state add src ${remote_IP}/24 dst ${local_IP}/24 proto esp spi ${in_reqid} reqid ${in_reqid} mode transport aead 'rfc4106(gcm(aes))' ${in_key} 128 ${offload_type} dev ${device} dir in sel src ${remote_IP}/24 dst ${local_IP}/24"
    ssh "${client}" "sudo /opt/mellanox/iproute2/sbin/ip xfrm policy add src ${local_IP}/24 dst ${remote_IP}/24 ${offload_type} dev ${device} dir out tmpl src ${local_IP}/24 dst ${remote_IP}/24 proto esp reqid ${out_reqid} mode transport"
    ssh "${client}" "sudo /opt/mellanox/iproute2/sbin/ip xfrm policy add src ${remote_IP}/24 dst ${local_IP}/24 ${offload_type} dev ${device} dir in tmpl src ${remote_IP}/24 dst ${local_IP}/24 proto esp reqid ${in_reqid} mode transport"
}

remove_ipsec_rules() {
    local client=$1
    ssh "${client}" "sudo ip xfrm state flush"
    ssh "${client}" "sudo ip xfrm policy flush"
}

set_ip() {
    local server=$1 # DPU IP / name
    local device1=$2 # p0 / p1
    local local_IP=$3 # of p0 / p1
    local client=$4 # DPU IP / name
    local device2=$5 # p0 / p1
    local remote_IP=$6 # of p0 / p1

    ssh "${server}" "sudo ifconfig ${device1} ${local_IP} up"
    ssh "${client}" "sudo ifconfig ${device2} ${remote_IP} up"
}

flush_ip() {
    local server=$1 # DPU IP / name
    local device1=$2 # p0 / p1
    local client=$3 # DPU IP / name
    local device2=$4 # p0 / p1

    ssh "${server}" "sudo ip addr flush dev ${device1}"
    ssh "${client}" "sudo ip addr flush dev ${device2}"
}

ovs_configure() {
    local client=$1 # DPU IP / name
    local device=$2 # p0 / p1
    local representor=$3
    local local_IP=$4 # of p0 / p1
    local remote_IP=$5 # of p0 / p1
    local i=$(( $6 + 1 ))

    ssh "${client}" "sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=true"
    ssh "${client}" "sudo systemctl restart openvswitch-switch.service"
    ssh "${client}" "sudo ovs-vsctl add-br br-int_${i}"
    ssh "${client}" "sudo ovs-vsctl del-port ${device}"
    ssh "${client}" "sudo ovs-vsctl del-port ${representor}"
    ssh "${client}" "sudo ovs-vsctl add-port br-int_${i} ${representor}"
    ssh "${client}" "sudo ovs-vsctl add-port br-int_${i} vxlan${i} -- set interface vxlan${i} type=vxlan options:key=${i}00 options:local_ip=${local_IP} options:remote_ip=${remote_IP} options:dst_port=4789"
}

ovs_configure_revert() {
    local client=$1 # DPU IP / name
    local device=$2 # p0 / p1
    local representor=$3
    local i=$(( $4 + 1 ))

    if [ "$device" = "p0" ]; then
        orig_bridge="ovsbr1"
    else
        orig_bridge="ovsbr2"
    fi

    ssh "${client}" "sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=true"
    ssh "${client}" "sudo systemctl restart openvswitch-switch.service"
    ssh "${client}" "sudo ovs-vsctl del-br br-int_${i}"
    ssh "${client}" "sudo ovs-vsctl add-port ${orig_bridge} ${representor}"
    ssh "${client}" "sudo ovs-vsctl add-port ${orig_bridge} ${device}"
}

set_mtu() {
    local server=$1 # DPU IP / name
    local device1=$2 # p0 / p1
    local client=$3 # DPU IP / name
    local device2=$4 # p0 / p1
    local mtu=$5
    ssh "${server}" "sudo ifconfig ${device1} mtu ${mtu}"
    ssh "${client}" "sudo ifconfig ${device2} mtu ${mtu}"
}

set_representor() {
    device1="$1"
    device2="$2"
    if [ "$device1" = "p0" ]; then
        representor1="pf0hpf"
    elif [ "$device1" = "p1" ]; then
        representor1="pf1hpf"
    else
        echo "Invalid device specified"
        return 1
    fi
    if [ "$device2" = "p0" ]; then
        representor2="pf0hpf"
    elif [ "$device2" = "p1" ]; then
        representor2="pf1hpf"
    else
        echo "Invalid device specified"
        return 1
    fi
}

restart_mlx5_ib_driver() {
    local server=$1 # DPU IP / name
    local client=$2 # DPU IP / name
    ssh "${server}" "modprobe -rv mlx5_ib ; modprobe -v mlx5_ib"
    ssh "${client}" "modprobe -rv mlx5_ib ; modprobe -v mlx5_ib"
}

<<EOF
# IPsec full-offload configuration flow:
update_mlnx_bf_conf ${LOCAL_BF}
update_mlnx_bf_conf ${REMOTE_BF}
generate_next_ip # Generate local_IP & remote_IP
set_mtu ${LOCAL_BF} ${device1} ${REMOTE_BF} ${device2} 2000
set_ip ${LOCAL_BF} ${device1} "${local_IP}" ${REMOTE_BF} ${device2} "${remote_IP}"
in_key=$(generete_key)
out_key=$(generete_key)
in_reqid=$(generete_req)
out_reqid=$(generete_req)
set_representor ${device1} ${device2}
set_ipsec_rules ${LOCAL_BF} ${device1} "${local_IP}" "${remote_IP}" ${in_key} ${out_key} ${in_reqid} ${out_reqid} "offload packet"
set_ipsec_rules ${REMOTE_BF} ${device2} "${remote_IP}" "${local_IP}" ${out_key} ${in_key} ${out_reqid} ${in_reqid} "offload packet"
ovs_configure ${LOCAL_BF} ${device1} ${representor1} "${local_IP}" "${remote_IP}" 1
ovs_configure ${REMOTE_BF} ${device2} ${representor2} "${remote_IP}" "${local_IP}" 1


# IPsec full-offload configuration *flush* flow:
set_representor ${device1} ${device2}
ovs_configure_revert ${LOCAL_BF} ${device1} ${representor1} 0
ovs_configure_revert ${REMOTE_BF} ${device2} ${representor2} 0
remove_ipsec_rules ${LOCAL_BF}
remove_ipsec_rules ${REMOTE_BF}
flush_ip ${LOCAL_BF} ${device1} ${REMOTE_BF} ${device2}
set_mtu ${LOCAL_BF} ${device1} ${REMOTE_BF} ${device2} 1500
update_mlnx_bf_conf_revert ${LOCAL_BF}
update_mlnx_bf_conf_revert ${REMOTE_BF}

EOF
