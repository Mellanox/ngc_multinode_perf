#!/bin/bash

scriptdir="$(dirname "$0")"
source "${scriptdir}/common.sh"

show_help()
{
    cat <<EOF >&2
Run RDMA test

Passwordless root access to the participating nodes
installed : numctl,perftest
Syntax: $0 <client hostname> <client ib device1>[,client ib device2]  <server hostname> <server ib device1>[,server ib device2] [use_cuda]
Options:
	use_cuda : add this flag to run perftest benchamrks on GPUs 
Please note that when running 2 devices on each side we expect it to be doul-port
Example:(Run on 2 ports)
$0 client mlx5_0,mlx5_1 server mlx5_3,mlx5_4

EOF
}

CLIENT_IP="${1}"
CLIENT_DEVICES=(${2//,/ })
SERVER_IP="${3}"
SERVER_DEVICES=(${4//,/ })
NUM_CONNECTIONS=${#CLIENT_DEVICES[@]}
#Defaults are not using cuda, set params as empty string
server_cuda=""
client_cuda=""
server_cuda2=""
client_cuda2=""

if (( $# < 4  )) || (( $# > 5 ))
then
    show_help
    exit 1
fi
#Check if need to run on GPU
if (( $# == 5 )) 
then
    if [ "${5}" = "use_cuda" ]
    then 
        RUN_WITH_CUDA=0
    else
	show_help
        exit 1
    fi
fi

check_if_number(){
	NUM=$1
	re='^[0-9]+$'
	if ! [[ $NUM =~ $re ]] ; then
	    PASS=1
	fi
}
run_perftest(){
    local -a ms_size_time
    local bg_pid bg2_pid
    local REPORT_ON_SIZE="8388608"
    PKT_SIZE=${1}
    ms_size_time=("-s" "${PKT_SIZE}" "-D" "10")
    PASS=0
    ssh "${SERVER_IP}" numactl -C "${SERVER_CORE}" "${TEST}" -d "${SERVER_DEVICES[0]}" --report_gbit "${ms_size_time[*]}" -b -F  -q4 --output=bandwidth "${server_cuda}" &

    #open server on port 2 if exists
    if (( NUM_CONNECTIONS == 2 )); then
        ssh "${SERVER_IP}" numactl -C "${SERVER2_CORE}" "${TEST}" -d "${SERVER_DEVICES[1]}" --report_gbit "${ms_size_time[*]}" -b -F  -q4 -p 10001 --output=bandwidth "${server_cuda2}" &
    fi

    #make sure server sides is open.
    sleep 2
    
    #Run client
    ssh "${CLIENT_IP}" "numactl -C ${CLIENT_CORE} ${TEST} -d ${CLIENT_DEVICES[0]} --report_gbit ${ms_size_time[*]} -b ${SERVER_IP} -F  -q4 ${client_cuda} --out_json --out_json_file=/tmp/perftest_${CLIENT_DEVICES[0]}.json" & bg_pid=$!
    #if this is doul-port open another server.
    if (( NUM_CONNECTIONS == 2 )); then
        ssh "${CLIENT_IP}" "numactl -C ${CLIENT2_CORE} ${TEST} -d ${CLIENT_DEVICES[1]} --report_gbit ${ms_size_time[*]} -b ${SERVER_IP} -F -q4 -p 10001 ${client_cuda2} --out_json --out_json_file=/tmp/perftest_${CLIENT_DEVICES[1]}.json" & bg2_pid=$!
        wait "${bg2_pid}"
	BW2=$(ssh "${CLIENT_IP}" "cat /tmp/perftest_${CLIENT_DEVICES[1]}.json | grep 'BW_average:' | awk -F: '{print \$2}' | awk -F, '{print \$1}' | cut -d. -f1| xargs")
	#Make sure that there is a valid BW
	check_if_number "$BW2"
        if [[ $BW2 -lt ${BW_PASS_RATE2} ]] && [[ $PKT_SIZE -eq $REPORT_ON_SIZE ]]
        then
            log "Device ${CLIENT_DEVICES[1]} did't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
            PASS=1
        fi
        ssh "${CLIENT_IP}" "rm -f /tmp/perftest_${CLIENT_DEVICES[1]}.json"
    fi

    wait "${bg_pid}"
    BW=$(ssh "${CLIENT_IP}" "cat /tmp/perftest_${CLIENT_DEVICES[0]}.json | grep 'BW_average:' | awk -F: '{print \$2}' | awk -F, '{print \$1}' | cut -d. -f1 | xargs")
    #Make sure that there is a valid BW
    check_if_number "$BW"
    if [[ $BW -lt ${BW_PASS_RATE} ]] && [[ $PKT_SIZE -eq $REPORT_ON_SIZE ]]
    then
        log "Device ${CLIENT_DEVICES[0]} did't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
        PASS=1
    fi
    ssh "${CLIENT_IP}" "rm -f /tmp/perftest_${CLIENT_DEVICES[0]}.json"
}

#---------------------Cores Selection--------------------
# get device local numa node
if SERVER_NUMA_NODE=$(ssh "${SERVER_IP}" "cat /sys/class/infiniband/${SERVER_DEVICES[0]}/device/numa_node 2>/dev/null")
then
    if [[ $SERVER_NUMA_NODE == "-1" ]]; then
        SERVER_NUMA_NODE="0"
    fi
else
    SERVER_NUMA_NODE="0"
fi

if CLIENT_NUMA_NODE=$(ssh "${CLIENT_IP}" "cat /sys/class/infiniband/${CLIENT_DEVICES[0]}/device/numa_node 2>/dev/null")
then
    if [[ $CLIENT_NUMA_NODE == "-1" ]]; then
        CLIENT_NUMA_NODE="0"
    fi
else
    CLIENT_NUMA_NODE="0"
fi

#get list of cores on relevent NUMA.
read -ra SERVER_CORES_ARR <<< $(ssh "${SERVER_IP}" numactl -H | grep -i "node ${SERVER_NUMA_NODE} cpus" | awk '{print substr($0,14)}')
read -ra CLIENT_CORES_ARR <<< $(ssh "${CLIENT_IP}" numactl -H | grep -i "node ${CLIENT_NUMA_NODE} cpus" | awk '{print substr($0,14)}')


#Avoid using core 0
SERVER_CORES_START_INDEX=0
(( ${SERVER_CORES_ARR[SERVER_CORES_START_INDEX]} != 0 )) || SERVER_CORES_START_INDEX=1
CLIENT_CORES_START_INDEX=0
(( ${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX]} != 0 )) || CLIENT_CORES_START_INDEX=1

# Flag to indecate that there is not enough cores, if running on same setup that has 2 devices on same numa node.
NOT_ENOUGH_CORES=1
# If 2 NICs on the same setup and same NUMA then adjust client core to same core list and prevent using same core.
if [ "${CLIENT_IP}" = "${SERVER_IP}" ] && [ "${SERVER_NUMA_NODE}" = "${CLIENT_NUMA_NODE}" ]; then
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
    CUDA_INDEX=$(get_cudas_per_rdma_device "${SERVER_IP}" "${SERVER_DEVICES[0]}" | cut -d , -f 1)
    server_cuda="--use_cuda=${CUDA_INDEX}"
    CUDA_INDEX=$(get_cudas_per_rdma_device "${CLIENT_IP}" "${CLIENT_DEVICES[0]}" | cut -d , -f 1)
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
        CUDA_INDEX=$(get_cudas_per_rdma_device "${SERVER_IP}" "${SERVER_DEVICES[0]}" | cut -d , -f 1)
        server_cuda2="--use_cuda=${CUDA_INDEX}"
        CUDA_INDEX=$(get_cudas_per_rdma_device "${CLIENT_IP}" "${CLIENT_DEVICES[0]}" | cut -d , -f 1)
        client_cuda2="--use_cuda=${CUDA_INDEX}"
    fi 
fi

#---------------------Expected speed--------------------
# Set pass rate to 90% of the bidirectional link speed
port_rate=$(get_port_rate "${CLIENT_IP}" "${CLIENT_DEVICES[0]}")
BW_PASS_RATE="$(awk "BEGIN {printf \"%.0f\n\", 2*0.9*${port_rate}}")"

if (( NUM_CONNECTIONS == 2 )); then
    port_rate2=$(get_port_rate "${CLIENT_IP}" "${CLIENT_DEVICES[1]}")
    BW_PASS_RATE2="$(awk "BEGIN {printf \"%.0f\n\", 2*0.9*${port_rate2}}")"
fi

#---------------------Run Benchmark--------------------
for TEST in ib_write_bw ib_read_bw ib_send_bw ; do
    #Loop over size 2k up to 8M
    for n in {1..23}
    do
        run_perftest $((2**n))
    done

    if (( PASS == 0 )); then
        log "NGC ${TEST} Passed"
    else
        log "NGC ${TEST} Failed"
    fi
done
