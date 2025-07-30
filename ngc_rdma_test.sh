#!/bin/bash
# Owner: rzilberzwaig@nvidia.com

set -eE

NEIGHBOR_LEVELS=1 # Utilizing NIC's NUMA
default_qps=4
max_qps=64
bw_ms_list=("65536")
lat_ms_list=("2")
min_send_lat_ms=32
server_QPS=()
client_QPS=()
conn_type_cmd=()
mtu_sizes=()
#Defaults are not using cuda, set params as empty string
server_cuda=""
client_cuda=""
ALLOW_CORE_ZERO=false
ALLOW_GPU_NODE_RELATION=false

scriptdir="$(dirname "$0")"
source "${scriptdir}/common.sh"
source "${scriptdir}/ipsec_full_offload_setup.sh"

POSITIONAL_ARGS=()
while [ $# -gt 0 ]
do
    case "${1}" in
        --use_cuda)
            RUN_WITH_CUDA=true
            shift
            ;;
        --server_cuda=*)
            [ "${RUN_WITH_CUDA}" = true ] || fatal "--server_cuda can only be used with --use_cuda"
            IFS=, read -r -a server_cuda_idx <<<"${1#*=}"
            #server_cuda_idx=${1#*=}
            shift
            ;;
        --client_cuda=*)
            [ "${RUN_WITH_CUDA}" = true ] || fatal "--client_cuda can only be used with --use_cuda"
            IFS=, read -r -a client_cuda_idx <<<"${1#*=}"
            #client_cuda_idx=${1#*=}
            shift
            ;;
        --use_cuda_dmabuf)
            dmabuf="--use_cuda_dmabuf"
            shift
            ;;
        --use_data_direct)
            datadirect="--use_data_direct"
            shift
            ;;
        --use-null-mr)
            null_mr="--use-null-mr"
            shift
            ;;
        --post_list=*)
            post_list="--post_list=${1#*=}"
            shift
            ;;
        --all_connection_types)
            ALL_CONN_TYPES=true
            shift
            ;;
        --qp=*)
            user_qps="${1#*=}"
            shift
            ;;
        --conn=*)
            IFS=',' read -ra CONN_TYPES <<< "${1#*=}"
            shift
            ;;
        --tests=*)
            IFS=',' read -ra TESTS <<< "${1#*=}"
            shift
            ;;
        --bw_message_size_list=*)
            IFS=',' read -ra bw_ms_list <<< "${1#*=}"
            shift
            ;;
        --lat_message_size_list=*)
            IFS=',' read -ra lat_ms_list <<< "${1#*=}"
            shift
            ;;
        --unidir)
            RDMA_UNIDIR=true
            shift
            ;;
        --sd)
            SD=true
            shift
            ;;
        --duration=*)
            TEST_DURATION="${1#*=}"
            shift
            ;;
        --ipsec)
            IPSEC=true
            shift
            ;;
        --allow_gpu_node_relation)
            [ "${RUN_WITH_CUDA}" = true ] || fatal "--allow_gpu_node_relation can only be used with --use_cuda"
            ALLOW_GPU_NODE_RELATION=true
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

IMPLEMENTED_TESTS=("ib_write_bw" "ib_read_bw" "ib_send_bw" "ib_write_lat" "ib_read_lat" "ib_send_lat")
# loop over TESTS and fatal if there is a test that is not implemented
for test in "${TESTS[@]}"; do
    if [[ ! " ${IMPLEMENTED_TESTS[@]} " =~ " ${test} " ]]; then
        fatal "Test '${test}' is not implemented."
    fi
done

# If TESTS is empty, set it to IMPLEMENTED_TESTS
if [ ${#TESTS[@]} -eq 0 ]; then
    TESTS=("${IMPLEMENTED_TESTS[@]}")
fi

get_perftest_connect_options() {
    local test

    test="${1}"
    ssh "${SERVER_TRUSTED}" "${test} --help" | awk -F'[<>]' '/--connection=/{gsub(/\//," ");gsub(/SRD/,"");print $2}'
}

show_help()
{
    cat <<EOF >&2
Run RDMA test

* Passwordless SSH access to the participating nodes is required.
* Passwordless sudo root access is required from the SSH'ing user.
* Dependencies which need to be installed: numctl, perftest.

Syntax: $0 [<client username>@]<client hostname> <client ib device1>[,<client ib device2>,...] [<server username>@]<server hostname> <server ib device1>[,<server ib device2>,...] [--use_cuda] [--qp=<num of QPs>] [--all_connection_types | --conn=<list of connection types>] [--tests=<list of ib perftests>] [--duration=<time in seconds>] [--message-size-list=<list of message sizes>] [--ipsec] [--sd] [--allow_gpu_node_relation]

Options:
	--use_cuda: add this flag to run BW perftest benchamrks on GPUs
	--server_cuda=<cuda device index>: Use the specified cuda device
	--client_cuda=<cuda device index>: Use the specified cuda device
	--use_cuda_dmabuf: Use CUDA DMA-BUF for GPUDirect RDMA testing
	--use_data_direct: Use mlx5dv_reg_dmabuf_mr verb
	--use-null-mr: Allocate a null memory region for the client with ibv_alloc_null_mr
	--post_list=<list size>: Post list of receive WQEs of <list size> size (instead of single post)
	--qp=<num of QPs>: Use the sepecified QPs' number (default: 4 QPs per device, max: ${max_qps})
	--all_connection_types: check all the supported connection types for each test, or:
	--conn=<list of connection types>: Use this flag to provide a comma-separated list of connection types without spaces.
	--tests=<list of ib perftests>: Use this flag to provide a comma-separated list of ib perftests to run.
	--duration=<time in seconds>: Specify the duration for each test (default: 30 seconds)
	--bw_message_size_list=<list of message sizes>: Use this flag to provide a comma separated message size list to run bw tests (default: 65536)
	--lat_message_size_list=<list of message sizes>: Use this flag to provide a comma separated message size list to run latency tests (default: 2)
	--unidir: Run in unidir (default: bidir)
	--ipsec: Enable IPsec packet offload (full-offload) on the Arm cores.
	--sd: Enable Socket Direct support. The SD should be added after the device (see example below).
	--allow_gpu_node_relation: Allow 'node' relation between GPU and NIC (connection traversing PCIe as well as the interconnect between PCIe host bridges within a NUMA node). This may result in lower performance, so use only if necessary. Use 'nvidia-smi topo -mp' to see all the available relations on the system.

Please note that when running 2 devices on each side we expect dual-port performance.

Example:(Run on 2 ports)
$0 client mlx5_0,mlx5_1 server mlx5_3,mlx5_4
Example:(Pick 3 connection types, single port)
$0 client mlx5_0 server mlx5_3 --conn=UC,UD,DC
Example: (Run on 2 ports with Socket Direct)
$0 client mlx5_0,mlx5_1,mlx5_4,mlx5_5 server mlx5_0,mlx5_1,mlx5_4,mlx5_5 --sd

EOF
}

if (( $# < 4  ))
then
    show_help
    exit 1
fi

CLIENT_TRUSTED="${1}"
CLIENT_DEVICES=(${2//,/ })
SERVER_TRUSTED="${3}"
SERVER_DEVICES=(${4//,/ })

[ -n "${IPSEC}" ] || IPSEC=false
if [ "$IPSEC" = true ]
then
    LOCAL_BF=(${5//,/ })
    LOCAL_BF_device=(${6//,/ })
    REMOTE_BF=(${7//,/ })
    REMOTE_BF_device=(${8//,/ })
fi

[ -n "${TEST_DURATION}" ] || TEST_DURATION="30"

NUM_CONNECTIONS=${#CLIENT_DEVICES[@]}
if [ -n "${user_qps}" ]; then
    (( user_qps <= max_qps )) || fatal "Max allowed QPs are ${max_qps}."
    for ((i = 0; i < NUM_CONNECTIONS; i++)); do
        server_QPS+=("${user_qps}")
    done
    client_QPS=("${server_QPS[@]}")
else
    read -ra client_QPS <<< $(default_qps_optimization "$CLIENT_TRUSTED" "${CLIENT_DEVICES[@]}")
    read -ra server_QPS <<< $(default_qps_optimization "$SERVER_TRUSTED" "${SERVER_DEVICES[@]}")
fi

BASE_RDMA_PORT=10000

if [ "${#SERVER_DEVICES[@]}" -ne "${#CLIENT_DEVICES[@]}" ]
then
    fatal "The number of server and client devices must be equal."
fi
NUM_DEVS=${#SERVER_DEVICES[@]}
NUM_BF_DEVS=${#LOCAL_BF[@]}

#init the arrays SERVER_NETDEVS,CLIENT_NETDEVS
get_netdevs

MAX_PROC="32"
min_l=$(get_min_channels)
opt_proc=$((min_l<MAX_PROC ? min_l : MAX_PROC))

read -ra CORES_ARRAY <<< $(get_cores_for_devices $1 $2 $3 $4 $((opt_proc+2)))
NUM_CORES_PER_DEVICE=$(( ${#CORES_ARRAY[@]}/(${#CLIENT_DEVICES[@]}*2) ))
NUM_INST=${NUM_CORES_PER_DEVICE}

# validate CONN_TYPES input before start of run
for CONN_TYPE in "${CONN_TYPES[@]}"; do
    exists_for_at_least_one_test=false
    for TEST in "${TESTS[@]}"; do
        available_conn_types="$(get_perftest_connect_options "$TEST")"
        # Check if the current connection type exists for the current test
        if [[ "$available_conn_types" == *"$CONN_TYPE"* ]]; then
            exists_for_at_least_one_test=true
            break
        fi
    done
    if [ "${exists_for_at_least_one_test}" != "true" ]; then
        fatal "invalid connection type: ${CONN_TYPE}"
        exit 1
    fi
done

#---------------------Configure IPsec full offload--------------------
if [ "$IPSEC" = true ]
then

    if [ -z "${MTU_SIZE}" ]; then
        for dev in "${CLIENT_DEVICES[@]}"
        do
            echo "$dev"
            net_name="$(ssh "${CLIENT_TRUSTED}" "ls -1 /sys/class/infiniband/${dev}/device/net/ | head -1")"
            mtu_sizes+=("$(ssh "${CLIENT_TRUSTED}" "ip a show ${net_name} | awk '/mtu/{print \$5}'")")
            echo "$mtu_sizes"
        done
        MTU_SIZE="$(get_min_val ${mtu_sizes[@]})"
    fi

    index=0
    for ((; index<NUM_BF_DEVS; index++))
    do
        # IPsec full-offload configuration flow:
        get_ips_and_ifs # create SERVER_IPS, SERVER_IPS_MASK, CLIENT_IPS, CLIENT_IPS_MASK
        update_mlnx_bf_conf ${LOCAL_BF[index]}
        update_mlnx_bf_conf ${REMOTE_BF[index]}
        generate_next_ip # Generate local_IP & remote_IP
        set_mtu ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} $(( MTU_SIZE + 50 ))
        set_ip ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} "${local_IP}/24" ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} "${remote_IP}/24"
        in_key=$(generete_key)
        out_key=$(generete_key)
        in_reqid=$(generete_req)
        out_reqid=$(generete_req)
        set_representor ${LOCAL_BF_device[index]} ${REMOTE_BF_device[index]}
        set_ipsec_rules ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} "${local_IP}" "${remote_IP}" ${in_key} ${out_key} ${in_reqid} ${out_reqid} "offload packet"
        set_ipsec_rules ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} "${remote_IP}" "${local_IP}" ${out_key} ${in_key} ${out_reqid} ${in_reqid} "offload packet"
        ovs_configure ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${representor1} "${local_IP}" "${remote_IP}" "${index}"
        ovs_configure ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} ${representor2} "${remote_IP}" "${local_IP}" "${index}"
    done
    for ((index1=0; index1<NUM_DEVS; index1++))
    do
        set_ip ${CLIENT_TRUSTED} ${CLIENT_NETDEVS[index1]} "${CLIENT_IPS[index1]}/${CLIENT_IPS_MASK[index1]}" ${SERVER_TRUSTED} ${SERVER_NETDEVS[index1]} "${SERVER_IPS[index1]}/${SERVER_IPS_MASK[index1]}"
    done
fi

#---------------------Run Benchmark--------------------
logstring=( "" "" "" "for" "devices:" "${SERVER_DEVICES[*]}" "<->" "${CLIENT_DEVICES[*]}")
for TEST in "${TESTS[@]}"; do
    logstring[0]="${TEST}"
    if [ $RUN_WITH_CUDA ] && grep -q '^ib_write_lat$' <<<"${TEST}"
    then
        log "Skip ${TEST} when running with CUDA"
        continue
    fi
    if [ "${ALL_CONN_TYPES}" = true ]
    then
        read -ra connection_types <<<"$(get_perftest_connect_options "${TEST}")"
    else
        connection_types=("${CONN_TYPES[@]}")
        if [ "${#connection_types[@]}" -eq 0 ]; then
            connection_types=("default")
        else
            # Filter unrelevant connection types to the current test
            available_conn_types=($(get_perftest_connect_options "${TEST}"))
            connection_types=($(comm -12 <(printf '%s\n' "${available_conn_types[@]}" | LC_ALL=C sort) <(printf '%s\n' "${connection_types[@]}" | LC_ALL=C sort)))
            if [ "${#connection_types[@]}" -eq 0 ]; then
                continue
            fi
        fi
    fi
    case "${TEST}" in
        *_lat)
            extra_server_args=("--output=latency")
            extra_client_args=("")
            bw_test=false
            ;;
        *_bw)
            [ "${RDMA_UNIDIR}" = "true" ] && unset bidir || bidir="-b"
            extra_client_args=("--report_gbit" "${bidir}" "-q" "%%QPS%%")
            extra_server_args=("--report_gbit" "${bidir}" "-q" "%%QPS%%" "--output=bandwidth")
            bw_test=true
            ;;
        *)
            fatal "${TEST} - test not supported."
            ;;
    esac

    for CONN_TYPE in "${connection_types[@]}"
    do
        if [[ "${TEST}" == *_lat* ]]; then
            ms_list=("${lat_ms_list[@]}")
        else
            ms_list=("${bw_ms_list[@]}")
        fi
        [ "${CONN_TYPE}" = "default" ] || conn_type_cmd=( "-c" "${CONN_TYPE}" )
        PASS=true
        for message_size in "${ms_list[@]}"
        do
            if [ "${RUN_WITH_CUDA}" = true ] && ((message_size <= min_send_lat_ms)) && grep -q '^ib_send_lat$' <<<"${TEST}"
            then
                log "Skip ${TEST} when running with CUDA - message size is too small (${message_size}), consider using '--lat_message_size_list'"
                continue
            fi
            run_perftest_servers
            sleep 2
            run_perftest_clients
            [ "${CONN_TYPE}" = "default" ] &&
                logstring[1]="-" || logstring[1]="(connection type: ${CONN_TYPE})"
            if [ "${PASS}" = true ]
            then
                logstring[2]="Passed"
                log "${logstring[*]}" RESULT_PASS
            else
                logstring[2]="Failed"
                log "${logstring[*]}" RESULT_FAIL
            fi
        done
    done
done
if [ "$IPSEC" = true ]
then
    index=0
    for ((; index<NUM_BF_DEVS; index++))
    do

        # IPsec full-offload configuration *flush* flow:
        set_representor ${LOCAL_BF_device[index]} ${REMOTE_BF_device[index]}
        ovs_configure_revert ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${representor1} "${index}"
        ovs_configure_revert ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} ${representor2} "${index}"
        remove_ipsec_rules ${LOCAL_BF[index]}
        remove_ipsec_rules ${REMOTE_BF[index]}
        flush_ip ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${REMOTE_BF[index]} ${REMOTE_BF_device[index]}
        set_mtu ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} ${MTU_SIZE}
        update_mlnx_bf_conf_revert ${LOCAL_BF[index]}
        update_mlnx_bf_conf_revert ${REMOTE_BF[index]}
        for ((index1=0; index1<NUM_DEVS; index1++))
        do
            set_ip ${CLIENT_TRUSTED} ${CLIENT_NETDEVS[index1]} "${CLIENT_IPS[index1]}/${CLIENT_IPS_MASK[index1]}" ${SERVER_TRUSTED} ${SERVER_NETDEVS[index1]} "${SERVER_IPS[index1]}/${SERVER_IPS_MASK[index1]}"
        done
    done
fi
