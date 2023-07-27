#!/bin/bash
# NGC Certification IPsec configuration functions v0.1
# Owner: dorko@nvidia.com
#

set_ipsec_rules() {
    local client=$1
    local device=$2
    local local_IP=$3
    local remote_IP=$4
    local in_key=$5
    local out_key=$6
    local in_reqid=$7
    local out_reqid=$8
    local offload_type=$9

    ssh "${client}" sudo -i bash << EOF
/opt/mellanox/iproute2/sbin/ip xfrm state add src ${local_IP}/24 dst ${remote_IP}/24 proto esp spi ${out_reqid} reqid ${out_reqid} mode transport aead 'rfc4106(gcm(aes))' ${out_key} 128 ${offload_type} dev ${device} dir out sel src ${local_IP} dst ${remote_IP}
/opt/mellanox/iproute2/sbin/ip xfrm state add src ${remote_IP}/24 dst ${local_IP}/24 proto esp spi ${in_reqid} reqid ${in_reqid} mode transport aead 'rfc4106(gcm(aes))' ${in_key} 128 ${offload_type} dev ${device} dir in sel src ${remote_IP} dst ${local_IP}
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${local_IP} dst ${remote_IP} dir out tmpl src ${local_IP}/24 dst ${remote_IP}/24 proto esp reqid ${out_reqid} mode transport
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${remote_IP} dst ${local_IP} dir in tmpl src ${remote_IP}/24 dst ${local_IP}/24 proto esp reqid ${in_reqid} mode transport
/opt/mellanox/iproute2/sbin/ip xfrm policy add src ${remote_IP} dst ${local_IP} dir fwd tmpl src ${remote_IP}/24 dst ${local_IP}/24 proto esp reqid ${in_reqid} mode transport
EOF

}

remove_ipsec_rules() {
    local client=$1
    ssh "${client}" sudo ip xfrm state flush
    ssh "${client}" sudo ip xfrm policy flush
}

