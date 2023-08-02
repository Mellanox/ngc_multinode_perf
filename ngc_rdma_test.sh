#!/bin/bash
set +x 

Help()
{
#Show  Help
	echo "Run RDMA test"
	echo 
	echo "Passwordless root access to the participating nodes" 
	echo "installed : numctl,perftest"
	echo "Syntax: $0 <client hostname> <client ib device1>[,client ib device2] [cuda_index,..] <server hostname> <server ib device1>[,server ib device2] [cuda_index,..]"
	echo "Example:(Run on 2 ports with cuda devices)"
	echo "$0 client mlx5_0,mlx5_1 0,1 server mlx5_3,mlx5_4 4,5"
	echo
}

CLIENT_IP=$1
CLIENT_DEVICES=($(echo "$2" | tr "," "\n"))

if [[ "$#" -eq 4 ]]; then
        SERVER_IP=$3
        SERVER_DEVICES=($(echo "$4" | tr "," "\n"))
        NUM_CONNECTIONS=${#CLIENT_DEVICES[@]}
elif [[ "$#" -eq 6 ]]; then
        #Run with CUDA
        CLIENT_CUDA_DEVICES=($(echo "$3" | tr "," "\n"))
        SERVER_IP=$4
        SERVER_DEVICES=($(echo "$5" | tr "," "\n"))
        SERVER_CUDA_DEVICES=($(echo "$6" | tr "," "\n"))
        NUM_CONNECTIONS=${#CLIENT_DEVICES[@]}
	RUN_WITH_CUDA=0
else
        Help
        exit 0
fi

run_perftest(){
	MS_SIZE_TIME="-s $1 -D 10"
	PASS=0
	SERVER_CUDA=""
        if [ $RUN_WITH_CUDA ]
        then
                SERVER_CUDA="--use_cuda=${SERVER_CUDA_DEVICES[0]}"
        fi
        ssh "${SERVER_IP}" -l root numactl -C ${SERVER_CORE} $TEST -d ${SERVER_DEVICES[0]} --report_gbit $MS_SIZE_TIME -b -F --limit_bw=${BW_PASS_RATE} -q4 --output=bandwidth $SERVER_CUDA &

        #open server on port 2 if exists
        if [ ${NUM_CONNECTIONS} -eq 2 ]; then
                SERVER_CUDA=""
                if [ $RUN_WITH_CUDA ]
                then
                        SERVER_CUDA="--use_cuda=${SERVER_CUDA_DEVICES[1]}"
                fi
                ssh "${SERVER_IP}" -l root numactl -C ${SERVER2_CORE} $TEST -d ${SERVER_DEVICES[1]} --report_gbit $MS_SIZE_TIME -b -F --limit_bw=${BW_PASS_RATE2} -q4 -p 10001 --output=bandwidth $SERVER_CUDA &
        fi

        #make sure server sides is open.
        sleep 2

        CLIENT_CUDA=""
        if [ "$RUN_WITH_CUDA" ]
        then
                CLIENT_CUDA="--use_cuda=${CLIENT_CUDA_DEVICES[0]}"
        fi
        #Run client
        ssh "${CLIENT_IP}" -l root " numactl -C ${CLIENT_CORE} $TEST -d ${CLIENT_DEVICES[0]} --report_gbit $MS_SIZE_TIME -b ${SERVER_IP} -F --limit_bw=${BW_PASS_RATE} -q4 $CLIENT_CUDA ; echo \$? > /tmp/bandwidth_${CLIENT_DEVICES[0]} " & BG_PID=$!
        #if this is doul-port open another server.
        if [ "${NUM_CONNECTIONS}" -eq 2 ]; then
                CLIENT_CUDA=""
                if [ $RUN_WITH_CUDA ]
                then
                        CLIENT_CUDA="--use_cuda=${CLIENT_CUDA_DEVICES[1]}"
                fi
                ssh "${CLIENT_IP}" -l root "numactl -C ${CLIENT2_CORE} $TEST -d ${CLIENT_DEVICES[1]} --report_gbit $MS_SIZE_TIME  -b ${SERVER_IP} -F --limit_bw=${BW_PASS_RATE2} -q4 -p 10001 $CLIENT_CUDA ; echo \$? >/tmp/bandwidth_${CLIENT_DEVICES[1]} " & BG2_PID=$!
                wait $BG2_PID
                if (( $(ssh "${CLIENT_IP}" -l root "cat /tmp/bandwidth_${CLIENT_DEVICES[1]}") != 0 ))
                then
                        echo "Device ${CLIENT_DEVICES[1]} did't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
                        PASS=1
                fi
                ssh "${CLIENT_IP}" -l root "rm -f /tmp/bandwidth_${CLIENT_DEVICES[1]}"
        fi

	wait $BG_PID
        if (( $(ssh "${CLIENT_IP}" -l root "cat /tmp/bandwidth_${CLIENT_DEVICES[0]}") != 0 ))
        then
                echo "Device ${CLIENT_DEVICES[0]} did't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
                PASS=1
        fi
        ssh "${CLIENT_IP}" -l root "rm -f /tmp/bandwidth_${CLIENT_DEVICES[0]} "


}

#---------------------Cores Selection--------------------
# get device local numa node
if ssh  "${SERVER_IP}" -l root "test -e /sys/class/infiniband/${SERVER_DEVICES[0]}/device/numa_node"; then
	SERVER_NUMA_NODE=$(ssh "${SERVER_IP}" -l root cat /sys/class/infiniband/"${SERVER_DEVICES[0]}"/device/numa_node)
	if [[ $SERVER_NUMA_NODE == "-1" ]]; then
		SERVER_NUMA_NODE="0"
	fi
else
	SERVER_NUMA_NODE="0"
fi

if ssh  "${CLIENT_IP}" -l root "test -e /sys/class/infiniband/${CLIENT_DEVICES[0]}/device/numa_node" ; then
	CLIENT_NUMA_NODE=$(ssh "${CLIENT_IP}" -l root cat /sys/class/infiniband/"${CLIENT_DEVICES[0]}"/device/numa_node)
	if [[ $CLIENT_NUMA_NODE == "-1" ]]; then
		CLIENT_NUMA_NODE="0"
	fi
else
        CLIENT_NUMA_NODE="0"
fi

#get list of cores on relevent NUMA.
SERVER_CORES_ARR=($(ssh "${SERVER_IP}" -l root numactl -H | grep -i "node $SERVER_NUMA_NODE cpus" | awk '{print substr($0,14)}'))
CLIENT_CORES_ARR=($(ssh "${CLIENT_IP}" -l root numactl -H | grep -i "node $CLIENT_NUMA_NODE cpus" | awk '{print substr($0,14)}'))


#Avoid using core 0
SERVER_CORES_START_INDEX=0
if [[ ${SERVER_CORES_ARR[SERVER_CORES_START_INDEX]} == "0" ]]; then
	SERVER_CORES_START_INDEX=1
fi
#Avoid using core 0
CLIENT_CORES_START_INDEX=0
if [[ ${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX]} == "0" ]]; then
	CLIENT_CORES_START_INDEX=1
fi

#Flag to indecats that there is no enough cores,if running on same setup that has 2 devices on same numa node.
NO_ENOUGH_CORES=1
#If 2 NICs on same setup and same NUMA then adjust client core to same core list and prevent using same core.
if [[ ${CLIENT_IP} = "${SERVER_IP}" ]] && [[ ${SERVER_NUMA_NODE} = "${CLIENT_NUMA_NODE}" ]]; then
	CLIENT_CORES_START_INDEX=$((SERVER_CORES_START_INDEX+NUM_CONNECTIONS))
	
	if [ "${#SERVER_CORES_ARR[@]}" -lt "5" ]  ; then
		echo "Warning : there is no enough CPUs on NUMA to run isolated processes,this may impact performance"
		NO_ENOUGH_CORES=0	
	fi
fi

SERVER_CORE=${SERVER_CORES_ARR[SERVER_CORES_START_INDEX]}
CLIENT_CORE=${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX]}

#if there is a second device , set cores for it. IMPORTANT:in case 2 devices on same numa and on same setup,
#and numa is 0, then we assume there is at least 5 cores(0,1,2,3,4) on this numa to work with.
if [ "${NUM_CONNECTIONS}" -eq 2  ]; then
	if [ $NO_ENOUGH_CORES -eq 0 ]; then
		SERVER2_CORE=${SERVER_CORES_ARR[SERVER_CORES_START_INDEX]}
		CLIENT2_CORE=${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX]}
	else
		SERVER2_CORE=${SERVER_CORES_ARR[SERVER_CORES_START_INDEX+1]}
                CLIENT2_CORE=${CLIENT_CORES_ARR[CLIENT_CORES_START_INDEX+1]}
	fi
fi


#---------------------Expected speed--------------------
# Set pass rate to 90% of the bidirectional link speed
BW_PASS_RATE=$(echo 2*0.9*"$(ssh "${CLIENT_IP}" -l root cat /sys/class/infiniband/"${CLIENT_DEVICES[0]}"/ports/1/rate)" | awk '{ print $1}' | bc -l )

if [ "${NUM_CONNECTIONS}" -eq 2 ]; then
	BW_PASS_RATE2=$(echo 2*0.9*"$(ssh "${CLIENT_IP}" -l root cat /sys/class/infiniband/"${CLIENT_DEVICES[1]}"/ports/1/rate)" | awk '{ print $1}' | bc -l )
fi


#---------------------Run Benchmark--------------------
for TEST in ib_write_bw ib_read_bw ib_send_bw ; do 
	
	for ms_size in  65536 1048576 8388608 
	do 
		run_perftest $ms_size
	done 
	
	if [ $PASS -eq 0 ] ; then
      		echo "NGC $TEST Passed"
        else
                echo "NGC $TEST Failed"
        fi

done

