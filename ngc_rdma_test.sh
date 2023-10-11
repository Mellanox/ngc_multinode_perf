#!/bin/bash

set -eE

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

show_help()
{
    cat <<EOF >&2
Run RDMA test

* Passwordless SSH access to the participating nodes is required.
* Passwordless sudo root access is required from the SSH'ing user.
* Dependencies which need to be installed: numctl, perftest.

Syntax: $0 <client hostname> <client ib device1>[,client ib device2] <server hostname> <server ib device1>[,server ib device2] [--use_cuda]

Options:
	--use_cuda : add this flag to run perftest benchamrks on GPUs

Please note that when running 2 devices on each side we expect dual-port performance.

Example:(Run on 2 ports)
$0 client mlx5_0,mlx5_1 server mlx5_3,mlx5_4

EOF
}

CLIENT_TRUSTED="${1}"
CLIENT_DEVICES=(${2//,/ })
SERVER_TRUSTED="${3}"
SERVER_DEVICES=(${4//,/ })
NUM_CONNECTIONS=${#CLIENT_DEVICES[@]}
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

run_perftest(){
    local -a ms_size_time
    local bg_pid bg2_pid
    #Run on all size, report pass/fail if 8M size reached line rate
    ms_size_time="-a"
    PASS=true
    ssh "${SERVER_TRUSTED}" "sudo taskset -c ${SERVER_CORE} ${TEST} -d ${SERVER_DEVICES[0]} --report_gbit ${ms_size_time} -b -F  -q4 --output=bandwidth ${server_cuda}" >> /dev/null &

    #open server on port 2 if exists
    if (( NUM_CONNECTIONS == 2 )); then
        ssh "${SERVER_TRUSTED}" "sudo taskset -c ${SERVER2_CORE} ${TEST} -d ${SERVER_DEVICES[1]} --report_gbit ${ms_size_time} -b -F  -q4 -p 10001 --output=bandwidth ${server_cuda2}" >> /dev/null &
    fi

    #make sure server sides is open.
    sleep 2

    #Run client
    ssh "${CLIENT_TRUSTED}" "sudo taskset -c ${CLIENT_CORE} ${TEST} -d ${CLIENT_DEVICES[0]} --report_gbit ${ms_size_time} -b ${SERVER_TRUSTED} -F  -q4 ${client_cuda} --out_json --out_json_file=/tmp/perftest_${CLIENT_DEVICES[0]}.json" & bg_pid=$!
    #if this is doul-port open another server.
    if (( NUM_CONNECTIONS == 2 )); then
        ssh "${CLIENT_TRUSTED}" "sudo taskset -c ${CLIENT2_CORE} ${TEST} -d ${CLIENT_DEVICES[1]} --report_gbit ${ms_size_time} -b ${SERVER_TRUSTED} -F -q4 -p 10001 ${client_cuda2} --out_json --out_json_file=/tmp/perftest_${CLIENT_DEVICES[1]}.json" & bg2_pid=$!
        wait "${bg2_pid}"
        BW2=$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/BW_average/{print \$2}' /tmp/perftest_${CLIENT_DEVICES[1]}.json | cut -d. -f1 | xargs")
        #Make sure that there is a valid BW
        check_if_number "$BW2" || PASS=false
        if [[ $BW2 -lt ${BW_PASS_RATE2} ]] && [[ $PKT_SIZE -eq $REPORT_ON_SIZE ]]
        then
            log "Device ${CLIENT_DEVICES[1]} didn't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
            PASS=false
        fi
        ssh "${CLIENT_TRUSTED}" "sudo rm -f /tmp/perftest_${CLIENT_DEVICES[1]}.json"
    fi

    wait "${bg_pid}"
    BW=$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/BW_average/{print \$2}' /tmp/perftest_${CLIENT_DEVICES[0]}.json | cut -d. -f1 | xargs")
    #Make sure that there is a valid BW
    check_if_number "$BW" || PASS=false
    if [[ $BW -lt ${BW_PASS_RATE} ]]
    then
        log "Device ${CLIENT_DEVICES[0]} didn't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
        PASS=false
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
for TEST in ib_write_bw ib_read_bw ib_send_bw ; do
    if [ $RUN_WITH_CUDA ] && [ "$TEST" = "ib_send_bw" ]
    then
        log "Skip ib_send_bw when running with CUDA"
        continue
    fi
    run_perftest

    if $PASS
    then
        log "NGC ${TEST} Passed for devices: ${SERVER_DEVICES[@]} <-> ${CLIENT_DEVICES[@]}"
    else
        log "NGC ${TEST} Failed for devices: ${SERVER_DEVICES[@]} <-> ${CLIENT_DEVICES[@]}"
    fi
done
