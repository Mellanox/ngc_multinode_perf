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
TEST_DURATION=$8

scriptdir="$(dirname "$0")"
source "${scriptdir}/ipsec_configuration.sh"
source "${scriptdir}/common.sh"

# Configure IPsec unaware mode
client_devices=(${CLIENT_DEVICE/,/ })
mtu_sizes=()
if [ -z "${MTU_SIZE}" ]; then
    for dev in "${client_devices[@]}"
    do
        net_name="$(ssh "${CLIENT_TRUSTED}" "ls -1 /sys/class/infiniband/${dev}/device/net/ | tail -1")"
        mtu_sizes+=("$(ssh "${CLIENT_TRUSTED}" "ip a show ${net_name} | awk '/mtu/{print \$5}'")")
    done
    MTU_SIZE="$(get_min_val ${mtu_sizes[@]})"
fi

bash "${scriptdir}/ipsec_full_offload_setup.sh" "${CLIENT_TRUSTED}" \
    "${CLIENT_DEVICE}" "${SERVER_TRUSTED}" "${SERVER_DEVICE}" "${LOCAL_BF}" \
    "${REMOTE_BF}" "$(( MTU_SIZE + 500 ))"

# Run tcp test
bash "${scriptdir}/ngc_tcp_test.sh" "${CLIENT_TRUSTED}" "${CLIENT_DEVICE}" \
    "${SERVER_TRUSTED}" "${SERVER_DEVICE}" "HALF" "DONT_CHANGE" \
    ${TEST_DURATION}

remove_ipsec_rules "${LOCAL_BF}"
remove_ipsec_rules "${REMOTE_BF}"
