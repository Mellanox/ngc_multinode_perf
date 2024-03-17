#!/bin/bash
# Owner: rzilberzwaig@nvidia.com

set -eE

NEIGHBOR_LEVELS=1 # Utilizing NIC's NUMA
default_qps=4
max_qps=64
bw_ms_list=("65536")
lat_ms_list=("2")
server_QPS=()
client_QPS=()
conn_type_cmd=()
#Defaults are not using cuda, set params as empty string
server_cuda=""
client_cuda=""
ALLOW_CORE_ZERO=false

scriptdir="$(dirname "$0")"
source "${scriptdir}/common.sh"

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
            server_cuda_idx=${1#*=}
            shift
            ;;
        --client_cuda=*)
            [ "${RUN_WITH_CUDA}" = true ] || fatal "--client_cuda can only be used with --use_cuda"
            client_cuda_idx=${1#*=}
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
        --bw_message-size-list=*)
            IFS=',' read -ra bw_ms_list <<< "${1#*=}"
            shift
            ;;
        --lat_message-size-list=*)
            IFS=',' read -ra lat_ms_list <<< "${1#*=}"
            shift
            ;;
        --unidir)
            RDMA_UNIDIR=true
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

Syntax: $0 <client hostname> <client ib device1>[,client ib device2] <server hostname> <server ib device1>[,server ib device2] [--use_cuda] [--qp=<num of QPs>] [--all_connection_types | --conn=<list of connection types>] [ --tests=<list of ib perftests>] [--message-size-list=<list of message sizes>]

Options:
	--use_cuda : add this flag to run BW perftest benchamrks on GPUs
	--server_cuda=<cuda device index>: Use the specified cuda device
	--client_cuda=<cuda device index>: Use the specified cuda device
	--qp=<num of QPs>: Use the sepecified QPs' number (default: 4 QPs per device, max: ${max_qps})
	--all_connection_types: check all the supported connection types for each test, or:
	--conn=<list of connection types>: Use this flag to provide a comma-separated list of connection types without spaces.
	--tests=<list of ib perftests>: Use this flag to provide a comma-separated list of ib perftests to run.
	--bw_message-size-list=<list of message sizes>: Use this flag to provide a comma separated message size list to run bw tests (default: 65536)
	--lat_message-size-list=<list of message sizes>: Use this flag to provide a comma separated message size list to run latency tests (default: 2)
	--unidir: Run in unidir (default: bidir)

Please note that when running 2 devices on each side we expect dual-port performance.

Example:(Run on 2 ports)
$0 client mlx5_0,mlx5_1 server mlx5_3,mlx5_4
Example:(Pick 3 connection types, single port)
$0 client mlx5_0 server mlx5_3 --conn=UC,UD,DC

EOF
}

if (( $# != 4  ))
then
    show_help
    exit 1
fi

CLIENT_TRUSTED="${1}"
CLIENT_DEVICES=(${2//,/ })
SERVER_TRUSTED="${3}"
SERVER_DEVICES=(${4//,/ })
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

#---------------------Run Benchmark--------------------
logstring=( "" "" "" "for" "devices:" "${SERVER_DEVICES[*]}" "<->" "${CLIENT_DEVICES[*]}")
for TEST in "${TESTS[@]}"; do
    logstring[0]="${TEST}"
    if [ $RUN_WITH_CUDA ] && grep -q '^ib_send_bw\|ib_write_lat\|ib_send_lat$' <<<"${TEST}"
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
            run_perftest_servers
            sleep 2
            run_perftest_clients
            [ "${CONN_TYPE}" = "default" ] &&
                logstring[1]="-" || logstring[1]="(connection type: ${CONN_TYPE})"
            [ "${PASS}" = true ] && logstring[2]="Passed" || logstring[2]="Failed"
            log "${logstring[*]}"
        done
    done
done
