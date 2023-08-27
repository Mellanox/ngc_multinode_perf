#!/bin/bash
# NGC Certification IPsec crypto offload test v0.1
# Owner: dorko@nvidia.com

if (( $# != 5 )); then
    echo "usage: $0 <client trusted ip> <client ib device> <server trusted ip> <server ib device> <number of tunnels>"
    exit 1
fi

CLIENT_TRUSTED=$1
CLIENT_DEVICE=$2
SERVER_TRUSTED=$3
SERVER_DEVICE=$4
NUM_OF_TUNNELS=$5
scriptdir="$(dirname "$0")"

source "${scriptdir}/ipsec_configuration.sh"
source "${scriptdir}/common.sh"

prep_for_tune_and_iperf_test



remove_ipsec_rules "${CLIENT_TRUSTED}"
remove_ipsec_rules "${SERVER_TRUSTED}"

in_key=0x093bfee2212802d626716815f862da31bcc7d9c44cfe3ab8049e7604b2feb1254869d25b
out_key=0x492e8ffe718a95a00c1893ea61afc64997f4732848ccfe6ea07db483175cb18de9ae411a

NUM_IPS=${#SERVER_IP[@]}
declare -a new_client_IP
declare -a new_server_IP
for (( i=0; i<NUM_OF_TUNNELS; i++ ))
do
    REQID_C=0x28f3954$(printf "%x" "${i}")
    REQID_S=0x622a73b$(printf "%x" "${i}")

    set_ipsec_rules "${CLIENT_TRUSTED}" "${CLIENT_NETDEV}" \
        "${CLIENT_IP[$(( i % NUM_IPS ))]}" "${SERVER_IP[$(( i % NUM_IPS ))]}" \
        "${in_key}" "${out_key}" "${REQID_S}" "${REQID_C}" offload
    set_ipsec_rules "${SERVER_TRUSTED}" "${SERVER_NETDEV}" \
        "${SERVER_IP[$(( i % NUM_IPS ))]}" "${CLIENT_IP[$(( i % NUM_IPS ))]}" \
        "${out_key}" "${in_key}" "${REQID_C}" "${REQID_S}" offload
    new_client_IP+=( "${CLIENT_IP[$(( i % NUM_IPS ))]}" )
    new_server_IP+=( "${SERVER_IP[$(( i % NUM_IPS ))]}" )
done
CLIENT_IP=(${new_client_IP[@]})
SERVER_IP=(${new_server_IP[@]})

ssh "${CLIENT_TRUSTED}" ip link set dev "${CLIENT_NETDEV}" up
ssh "${SERVER_TRUSTED}" ip link set dev "${SERVER_NETDEV}" up

#set_IRQ_affinity

set -x
run_iperf3
set +x

remove_ipsec_rules "${CLIENT_TRUSTED}"
remove_ipsec_rules "${SERVER_TRUSTED}"
