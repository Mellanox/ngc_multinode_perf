#!/bin/bash

set -eE

default_qps=4
max_qps=64
bw_ms_list=("65536")
lat_ms_list=("2")

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
        --all_connection_types)
            ALL_CONN_TYPES=true
            shift
            ;;
        --qp=*)
            QPS="${1#*=}"
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
	--qp=<num of QPs>: Use the sepecified QPs' number (default: ${default_qps}, max: ${max_qps})
	--all_connection_types: check all the supported connection types for each test, or:
	--conn=<list of connection types>: Use this flag to provide a comma-separated list of connection types without spaces.
	--tests=<list of ib perftests>: Use this flag to provide a comma-separated list of ib perftests to run.
	--bw_message-size-list=<list of message sizes>: Use this flag to provide a comma separated message size list to run bw tests (default: 65536)
	--lat_message-size-list=<list of message sizes>: Use this flag to provide a comma separated message size list to run latency tests (default: 2)

Please note that when running 2 devices on each side we expect dual-port performance.

Example:(Run on 2 ports)
$0 client mlx5_0,mlx5_1 server mlx5_3,mlx5_4
Example:(Pick 3 connection types, single port)
$0 client mlx5_0 server mlx5_3 --conn=UC,UD,DC

EOF
}

CLIENT_TRUSTED="${1}"
CLIENT_DEVICES=(${2//,/ })
SERVER_TRUSTED="${3}"
SERVER_DEVICES=(${4//,/ })
NUM_CONNECTIONS=${#CLIENT_DEVICES[@]}
(( 1 <= NUM_CONNECTIONS )) && (( NUM_CONNECTIONS <= 2 )) ||
    fatal "Number of connections ${NUM_CONNECTIONS} is too high."
(( default_qps /= NUM_CONNECTIONS )) ||
    fatal "You need more QPs for the specified number of connections"
[ -n "${QPS}" ] || QPS="${default_qps}"
(( QPS <= max_qps )) || fatal "Max allowed QPs are ${max_qps}."
#Defaults are not using cuda, set params as empty string
server_cuda=""
client_cuda=""
server_cuda2=""
client_cuda2=""

if (( $# != 4  ))
then
    show_help
    exit 1
fi

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


run_perftest(){
    local -a conn_type_cmd extra_server_args extra_client_args
    local bg_pid bg2_pid
    local message_size="$1"

    case "${TEST}" in
        *_lat)
            extra_server_args=("--output=latency")
            bw_test=false
            ;;
        *_bw)
            extra_client_args=("--report_gbit" "-b" "-q" "${QPS}")
            extra_server_args=(${extra_client_args[@]} "--output=bandwidth")
            bw_test=true
            ;;
        *)
            fatal "${TEST} - test not supported."
            ;;
    esac
    [ "${CONN_TYPE}" = "default" ] || conn_type_cmd=( "-c" "${CONN_TYPE}" )
    PASS=true
    ssh "${SERVER_TRUSTED}" "sudo taskset -c ${SERVER_CORE} ${TEST} -d ${SERVER_DEVICES[0]} -D 30 -s ${message_size} -F ${conn_type_cmd[*]} ${extra_server_args[*]} ${server_cuda}" >> /dev/null &

    #open server on port 2 if exists
    if (( NUM_CONNECTIONS == 2 )); then
        ssh "${SERVER_TRUSTED}" "sudo taskset -c ${SERVER2_CORE} ${TEST} -d ${SERVER_DEVICES[1]} -D 30 -s ${message_size} -F ${conn_type_cmd[*]} ${extra_server_args[*]} -p 10001 ${server_cuda2}" >> /dev/null &
    fi

    #make sure server sides is open.
    sleep 2

    #Run client
    ssh "${CLIENT_TRUSTED}" "sudo taskset -c ${CLIENT_CORE} ${TEST} -d ${CLIENT_DEVICES[0]} -D 30 ${SERVER_TRUSTED} -s ${message_size} -F ${conn_type_cmd[*]} ${extra_client_args[*]} ${client_cuda} --out_json --out_json_file=/tmp/perftest_${CLIENT_DEVICES[0]}.json" & bg_pid=$!
    #if this is doul-port open another server.
    if (( NUM_CONNECTIONS == 2 )); then
        ssh "${CLIENT_TRUSTED}" "sudo taskset -c ${CLIENT2_CORE} ${TEST} -d ${CLIENT_DEVICES[1]} -D 30 ${SERVER_TRUSTED} -s ${message_size} -F ${conn_type_cmd[*]} ${extra_client_args[*]} -p 10001 ${client_cuda2} --out_json --out_json_file=/tmp/perftest_${CLIENT_DEVICES[1]}.json" & bg2_pid=$!
        wait "${bg2_pid}"
        if [ "${bw_test}" = "true" ]
        then
            BW2=$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/BW_average/{print \$2}' /tmp/perftest_${CLIENT_DEVICES[1]}.json | cut -d. -f1 | xargs")
            #Make sure that there is a valid BW
            check_if_number "$BW2" || PASS=false
            log "Device ${CLIENT_DEVICES[1]} reached ${BW2} Gb/s (max possible: $((port_rate2 * 2)) Gb/s)"
            if [[ $BW2 -lt ${BW_PASS_RATE2} ]]
            then
                log "Device ${CLIENT_DEVICES[1]} didn't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
                PASS=false
            fi
        fi
        ssh "${CLIENT_TRUSTED}" "sudo rm -f /tmp/perftest_${CLIENT_DEVICES[1]}.json"
    fi

    wait "${bg_pid}"
    if [ "${bw_test}" = "true" ]
    then
        BW=$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/BW_average/{print \$2}' /tmp/perftest_${CLIENT_DEVICES[0]}.json | cut -d. -f1 | xargs")
        #Make sure that there is a valid BW
        check_if_number "$BW" || PASS=false
        log "Device ${CLIENT_DEVICES[0]} reached ${BW} Gb/s (max possible: $((port_rate * 2)) Gb/s)"
        if [[ $BW -lt ${BW_PASS_RATE} ]]
        then
            log "Device ${CLIENT_DEVICES[0]} didn't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
            PASS=false
        fi
    fi
    ssh "${CLIENT_TRUSTED}" "sudo rm -f /tmp/perftest_${CLIENT_DEVICES[0]}.json"
}

#---------------------Cores Selection--------------------
# get device local numa node
if SERVER_NUMA_NODE=$(ssh "${SERVER_TRUSTED}" "cat /sys/class/infiniband/${SERVER_DEVICES[0]}/device/numa_node 2>/dev/null")
then
    if [[ $SERVER_NUMA_NODE == "-1" ]]; then
        SERVER_NUMA_NODE="0"
    fi
else
    SERVER_NUMA_NODE="0"
fi

if CLIENT_NUMA_NODE=$(ssh "${CLIENT_TRUSTED}" "cat /sys/class/infiniband/${CLIENT_DEVICES[0]}/device/numa_node 2>/dev/null")
then
    if [[ $CLIENT_NUMA_NODE == "-1" ]]; then
        CLIENT_NUMA_NODE="0"
    fi
else
    CLIENT_NUMA_NODE="0"
fi

#get list of cores on relevent NUMA.
read -ra SERVER_CORES_ARR <<< $(ssh "${SERVER_TRUSTED}" numactl -H | grep -i "node ${SERVER_NUMA_NODE} cpus" | awk '{print substr($0,14)}')
read -ra CLIENT_CORES_ARR <<< $(ssh "${CLIENT_TRUSTED}" numactl -H | grep -i "node ${CLIENT_NUMA_NODE} cpus" | awk '{print substr($0,14)}')


#Avoid using core 0
SERVER_CORES_START_INDEX=0
(( ${SERVER_CORES_ARR[SERVER_CORES_START_INDEX]} != 0 )) || SERVER_CORES_START_INDEX=1
CLIENT_CORES_START_INDEX=0
(( ${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX]} != 0 )) || CLIENT_CORES_START_INDEX=1

# Flag to indecate that there is not enough cores, if running on same setup that has 2 devices on same numa node.
NOT_ENOUGH_CORES=1
# If 2 NICs on the same setup and same NUMA then adjust client core to same core list and prevent using same core.
if [ "${CLIENT_TRUSTED}" = "${SERVER_TRUSTED}" ] && [ "${SERVER_NUMA_NODE}" = "${CLIENT_NUMA_NODE}" ]; then
    CLIENT_CORES_START_INDEX=$((SERVER_CORES_START_INDEX + NUM_CONNECTIONS))

    if (( ${#SERVER_CORES_ARR[@]} < 5 )); then
        log "Warning: there are not enough CPUs on NUMA to run isolated processes, this may impact performance."
        NOT_ENOUGH_CORES=0
    fi
fi

SERVER_CORE=${SERVER_CORES_ARR[SERVER_CORES_START_INDEX]}
CLIENT_CORE=${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX]}
if [ $RUN_WITH_CUDA ]
then
    CUDA_INDEX=$(get_cudas_per_rdma_device "${SERVER_TRUSTED}" "${SERVER_DEVICES[0]}" | cut -d , -f 1)
    server_cuda="--use_cuda=${CUDA_INDEX}"
    CUDA_INDEX=$(get_cudas_per_rdma_device "${CLIENT_TRUSTED}" "${CLIENT_DEVICES[0]}" | cut -d , -f 1)
    client_cuda="--use_cuda=${CUDA_INDEX}"
fi


#if there is a second device , set cores for it. IMPORTANT:in case 2 devices on same numa and on same setup,
#and numa is 0, then we assume there is at least 5 cores(0,1,2,3,4) on this numa to work with.
if (( NUM_CONNECTIONS == 2 )); then
    if (( NOT_ENOUGH_CORES == 0 )); then
        SERVER2_CORE=${SERVER_CORES_ARR[SERVER_CORES_START_INDEX]}
        CLIENT2_CORE=${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX]}
    else
        SERVER2_CORE=${SERVER_CORES_ARR[SERVER_CORES_START_INDEX+1]}
        CLIENT2_CORE=${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX+1]}
    fi
    if [ $RUN_WITH_CUDA ]
    then
        CUDA_INDEX=$(get_cudas_per_rdma_device "${SERVER_TRUSTED}" "${SERVER_DEVICES[0]}" | cut -d , -f 1)
        server_cuda2="--use_cuda=${CUDA_INDEX}"
        CUDA_INDEX=$(get_cudas_per_rdma_device "${CLIENT_TRUSTED}" "${CLIENT_DEVICES[0]}" | cut -d , -f 1)
        client_cuda2="--use_cuda=${CUDA_INDEX}"
    fi
fi

#---------------------Expected speed--------------------
# Set pass rate to 90% of the bidirectional link speed
port_rate=$(get_port_rate "${CLIENT_TRUSTED}" "${CLIENT_DEVICES[0]}")
BW_PASS_RATE="$(awk "BEGIN {printf \"%.0f\n\", 2*0.9*${port_rate}}")"

if (( NUM_CONNECTIONS == 2 )); then
    port_rate2=$(get_port_rate "${CLIENT_TRUSTED}" "${CLIENT_DEVICES[1]}")
    BW_PASS_RATE2="$(awk "BEGIN {printf \"%.0f\n\", 2*0.9*${port_rate2}}")"
fi


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
    for CONN_TYPE in "${connection_types[@]}"
    do
        if [[ "${TEST}" == *_lat* ]]; then
            ms_list=("${lat_ms_list[@]}")
        else
            ms_list=("${bw_ms_list[@]}")
        fi
        for message_size in "${ms_list[@]}"
        do
            run_perftest "$message_size"
            if [ "${bw_test}" = "true" ]
            then
                [ "${CONN_TYPE}" = "default" ] &&
                    logstring[1]="-" || logstring[1]="(connection type: ${CONN_TYPE})"
                [ "${PASS}" = true ] && logstring[2]="Passed" || logstring[2]="Failed"
                log "${logstring[*]}"
            fi
        done
    done
done
