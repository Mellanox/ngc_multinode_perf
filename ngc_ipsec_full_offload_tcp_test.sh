#!/bin/bash
# NGC Certification IPsec full offload (unaware) test v0.1
# Owner: dorko@nvidia.com
#

CLIENT_TRUSTED=$1
CLIENT_DEVICE=$2
SERVER_TRUSTED=$3
SERVER_DEVICE=$4
LOCAL_BF=$5
REMOTE_BF=$6
MTU_SIZE=$7

# Configure IPsec unaware mode
if [ -z "${MTU_SIZE}" ]; then
    net_name="$(ssh "${CLIENT_TRUSTED}" "ls -l /sys/class/infiniband/${CLIENT_DEVICE}/device/net/ | tail -1 | cut -d' ' -f9")"
    MTU_SIZE="$(ssh "${CLIENT_TRUSTED}" "ip addr | grep mtu | grep ${net_name} | cut -d' ' -f5")"
fi

scriptdir="$(dirname "$0")"
source "${scriptdir}/ipsec_configuration.sh"

bash "${scriptdir}/ipsec_full_offload_setup.sh" "${CLIENT_TRUSTED}" \
    "${CLIENT_DEVICE}" "${SERVER_TRUSTED}" "${SERVER_DEVICE}" "${LOCAL_BF}" \
    "${REMOTE_BF}" "$(( MTU_SIZE + 500 ))"

# Run tcp test
bash "${scriptdir}/ngc_tcp_test.sh" "${CLIENT_TRUSTED}" "${CLIENT_DEVICE}" \
    "${SERVER_TRUSTED}" "${SERVER_DEVICE}" "HALF" "DONT_CHANGE"

remove_ipsec_rules "${LOCAL_BF}"
remove_ipsec_rules "${REMOTE_BF}"
