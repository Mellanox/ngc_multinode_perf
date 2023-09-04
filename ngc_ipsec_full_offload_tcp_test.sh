#!/bin/bash
# NGC Certification IPsec full offload (unaware) test v0.1
# Owner: dorko@nvidia.com
#

scriptdir="$(dirname "$0")"
source "${scriptdir}/ipsec_configuration.sh"
source "${scriptdir}/common.sh"

POSITIONAL_ARGS=()
while [ $# -gt 0 ]
do
    case "${1}" in
        --mtu=*)
            MTU_SIZE="${1#*=}"
            shift
            ;;
        --duration=*)
            # Exporting to be re-used in ngc_tcp_test.sh
            export TEST_DURATION="${1#*=}"
            shift
            ;;
        --*)
            fatal "Unknown option ${1}"
            ;;
        *)
            POSITIONAL_ARGS+=("${1}")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

CLIENT_TRUSTED=$1
CLIENT_DEVICE=$2
SERVER_TRUSTED=$3
SERVER_DEVICE=$4
LOCAL_BF=$5
REMOTE_BF=$6

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
    "${SERVER_TRUSTED}" "${SERVER_DEVICE}" --duplex="HALF" \
    --change_mtu="DONT_CHANGE"

remove_ipsec_rules "${LOCAL_BF}"
remove_ipsec_rules "${REMOTE_BF}"
