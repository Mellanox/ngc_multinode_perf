#!/bin/bash
# NGC Certification common functions v0.1
# Owner: dorko@nvidia.com
#

scriptdir="$(dirname "$0")"

function check_connection {
	ssh $CLIENT_TRUSTED ping $SERVER_IP -c 5
	if [ $? -ne 0 ]; then
		echo "No ping from client to server, test aborted"
		exit 1
	fi
}

function change_mtu {
	if [ $LINK_TYPE -eq 1 ]; then
		MTU=9000
	elif [ $LINK_TYPE -eq 32 ]; then
		MTU=4092
	fi
	ssh ${CLIENT_TRUSTED} "echo $MTU > /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/mtu"
	ssh ${SERVER_TRUSTED} "echo $MTU > /sys/class/infiniband/${SERVER_DEVICE}/device/net/*/mtu"
	CURR_MTU=`ssh ${CLIENT_TRUSTED} "cat /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/mtu"	`
	if [ $CURR_MTU != $MTU ]; then
		echo 'Warning, MTU was not configured correctly on Client'
	fi
	CURR_MTU=`ssh ${SERVER_TRUSTED} "cat /sys/class/infiniband/${SERVER_DEVICE}/device/net/*/mtu"	`
	if [ $CURR_MTU != $MTU ]; then
		echo 'Warning, MTU was not configured correctly on Server'
	fi
}

function run_iperf2 {
	ssh ${SERVER_TRUSTED} pkill iperf
	ssh ${SERVER_TRUSTED} iperf -s &
	sleep 5
	ssh ${CLIENT_TRUSTED} iperf -c $SERVER_IP -P $MAX_PROC -t 30
	ssh ${SERVER_TRUSTED} pkill iperf
}

function get_average {
	count=0;
	total=0;

	for i in $@
	do
			total=$(echo $total+$i | bc )
			((count++))
	done
	echo "scale=2; $total / $count" | bc
}

function get_min_index {
	DISTANCES=($@)
	MIN_IDX=0
	MIN_VAL=$1
	for i in `seq 0 $((${#DISTANCES[@]}-1))`; do
		if (( ${DISTANCES[$i]} < $MIN_VAL )); then
			MIN_IDX=$i
			MIN_VAL=${DISTANCES[$i]}
		fi
	done
	echo $MIN_IDX
}

function get_closest_n_nodes {
	N=$1
	END_SIDE=$2
	DISTANCES=(${@:3})
	MINS=()
	FLAG_MIN_IS_FIRST=0
	NODES_NUM=`ssh ${END_SIDE} ls /sys/devices/system/node/ | egrep 'node[0-9]' | wc -l`
	NODES_SEQ=(`seq 0 $((NODES_NUM-1))`)
	for i in `seq 0 $((N-1))`; do
		MIN_IDX=`get_min_index ${DISTANCES[@]}`
		TMP_MIN_IDX=MIN_IDX
		if (( $FLAG_MIN_IS_FIRST == 1 )); then 
			MIN_IDX=$((MIN_IDX+1))
		fi 
		if (( $TMP_MIN_IDX == 0 )); then 
			FLAG_MIN_IS_FIRST=1
		else 
			FLAG_MIN_IS_FIRST=0
		fi
		MINS=(${MINS[@]} ${NODES_SEQ[$MIN_IDX]})
		#echo "NODES_SEQ ${NODES_SEQ[@]}, NODES_NUM $NODES_NUM --- $MIN_IDX ==="
		unset DISTANCES[$MIN_IDX]
		unset NODES_SEQ[$MIN_IDX]
		DISTANCES=(${DISTANCES[@]})
		NODES_SEQ=(${NODES_SEQ[@]})
	done
	echo ${MINS[@]}
}

function prep_for_tune_and_iperf_test {

	ssh ${CLIENT_TRUSTED} pkill iperf3
	ssh ${SERVER_TRUSTED} pkill iperf3

	CLIENT_NUMA_NODE=`ssh ${CLIENT_TRUSTED} cat /sys/class/infiniband/${CLIENT_DEVICE}/device/numa_node`
	if [[ $CLIENT_NUMA_NODE == "-1" ]]; then
		CLIENT_NUMA_NODE="0"
	fi
	SERVER_NUMA_NODE=`ssh ${SERVER_TRUSTED} cat /sys/class/infiniband/${SERVER_DEVICE}/device/numa_node`
	if [[ $SERVER_NUMA_NODE == "-1" ]]; then
		SERVER_NUMA_NODE="0"
	fi

	CLIENT_NETDEV=`ssh ${CLIENT_TRUSTED} ls /sys/class/infiniband/${CLIENT_DEVICE}/device/net `
	SERVER_NETDEV=`ssh ${SERVER_TRUSTED} ls /sys/class/infiniband/${SERVER_DEVICE}/device/net`

	SERVER_IP=($(ssh $SERVER_TRUSTED "ip a sh $SERVER_NETDEV | grep -ioP  \"(?<=inet )\d+\.\d+\.\d+\.\d+\""))
	CLIENT_IP=($(ssh $CLIENT_TRUSTED "ip a sh $CLIENT_NETDEV | grep -ioP  \"(?<=inet )\d+\.\d+\.\d+\.\d+\""))

	if [ -z "$SERVER_IP" ]; then
		echo "Can't find server IP, did you set IPv4 address in server ?"
		exit 1
	fi
	if [ -z "$CLIENT_IP" ]; then
		echo "Can't find server IP, did you set IPv4 address in client ?"
		exit 1
	fi

	ssh ${CLIENT_TRUSTED} iperf3 -v
	ssh ${SERVER_TRUSTED} iperf3 -v
	ssh ${CLIENT_TRUSTED} cat /proc/cmdline
	ssh ${SERVER_TRUSTED} cat /proc/cmdline
	ssh ${CLIENT_TRUSTED} iperf -v
	ssh ${SERVER_TRUSTED} iperf -v

	MAX_PROC=16
	THREADS=1
	TIME=60
	TCP_PORT_ID=`echo $CLIENT_DEVICE | cut -d "_" -f 2`
	TCP_PORT_ADDITION=`echo $TCP_PORT_ID*100 | bc -l `
	BASE_TCP_PORT=$((5200+$TCP_PORT_ADDITION))
	NUMACTL_HW='numactl --hardware | grep -v node'
	NUM_SOCKETS_CMD='lscpu | grep Socket | cut -d":" -f2'
	NUM_NUMAS_CMD='lscpu | grep "NUMA node(s)" | cut -d":" -f2'

	# Get Client NUMA topology
	CLIENT_NUMA_DISTS=(`ssh ${CLIENT_TRUSTED} cat /sys/devices/system/node/node$CLIENT_NUMA_NODE/distance`)
	CLIENT_NUM_SOCKETS=`ssh ${CLIENT_TRUSTED} $NUM_SOCKETS_CMD`
	CLIENT_NUM_NUMAS=`ssh ${CLIENT_TRUSTED} $NUM_NUMAS_CMD`
	CLIENT_LOGICAL_NUMA_PER_SOCKET=$((CLIENT_NUM_NUMAS / CLIENT_NUM_SOCKETS))
	CLIENT_CLOSEST_NUMAS=(`get_closest_n_nodes $CLIENT_LOGICAL_NUMA_PER_SOCKET ${CLIENT_TRUSTED} ${CLIENT_NUMA_DISTS[@]}`)
	MIN_IDX=`get_min_index ${CLIENT_CLOSEST_NUMAS[@]}`
	CLIENT_BASE_NUMA=${CLIENT_CLOSEST_NUMAS[$MIN_IDX]}

	echo "CLIENT_CLOSEST_NUMAS ${CLIENT_CLOSEST_NUMAS[@]} CLIENT_BASE_NUMA $CLIENT_BASE_NUMA CLIENT_NUMA_DISTS ${CLIENT_NUMA_DISTS[@]} CLIENT_NUMA_NODE $CLIENT_NUMA_NODE"
	
	# Get Server NUMA topology
	SERVER_NUMA_DISTS=(`ssh ${SERVER_TRUSTED} cat /sys/devices/system/node/node$SERVER_NUMA_NODE/distance`)
	SERVER_NUM_SOCKETS=`ssh ${SERVER_TRUSTED} $NUM_SOCKETS_CMD`
	SERVER_NUM_NUMAS=`ssh ${SERVER_TRUSTED} $NUM_NUMAS_CMD`
	SERVER_LOGICAL_NUMA_PER_SOCKET=$((SERVER_NUM_NUMAS / SERVER_NUM_SOCKETS))
	SERVER_CLOSEST_NUMAS=(`get_closest_n_nodes $SERVER_LOGICAL_NUMA_PER_SOCKET ${SERVER_TRUSTED} ${SERVER_NUMA_DISTS[@]}`)
	MIN_IDX=`get_min_index ${SERVER_CLOSEST_NUMAS[@]}`
	SERVER_BASE_NUMA=${SERVER_CLOSEST_NUMAS[$MIN_IDX]}

	echo "SERVER_CLOSEST_NUMAS ${SERVER_CLOSEST_NUMAS[@]} SERVER_BASE_NUMA $SERVER_BASE_NUMA SERVER_NUMA_DISTS ${SERVER_NUMA_DISTS[@]} CLIENT_NUMA_NODE $SERVER_NUMA_NODE"
}
function clean_measurement_files {
	ssh ${CLIENT_TRUSTED} "find /tmp/ -name ngc\*.txt\* | xargs -I {} rm -f {}"
	ssh ${SERVER_TRUSTED} "find /tmp/ -name ngc\*.txt\* | xargs -I {} rm -f {}"
	find /tmp/ -name ngc\*.txt\* | xargs -I {} rm -f {}
}

function run_iperf3 {
	clean_measurement_files

	PROC=`printf "%s\n" $CLIENT_AFFINITY_IRQ_COUNT $SERVER_AFFINITY_IRQ_COUNT $MAX_PROC | sort -h | head -n1`
	#check amount of IPs for interface asked, and run iperf3 mutli proccess each on another ip.
	IP_AMOUNT=$(printf "%s\n" ${#SERVER_IP[@]} ${#CLIENT_IP[@]} | sort -h | head -n1)

	echo -- starting iperf with $PROC processes $THREADS threads --

	CLIENT_ACTIVE_CORES_LIST=()
	SERVER_ACTIVE_CORES_LIST=()
	for P in `seq 0 $((PROC-1))`
	do 
		index=$((P%CLIENT_LOGICAL_NUMA_PER_SOCKET*CLIENT_PHYSICAL_CORE_COUNT+P/CLIENT_LOGICAL_NUMA_PER_SOCKET))
		CLIENT_ACTIVE_CORES_LIST=(${CLIENT_ACTIVE_CORES_LIST[@]} ${CLIENT_PHYSICAL_CORES[$index]})
		index=$((P%SERVER_LOGICAL_NUMA_PER_SOCKET*SERVER_PHYSICAL_CORE_COUNT+P/SERVER_LOGICAL_NUMA_PER_SOCKET))
		SERVER_ACTIVE_CORES_LIST=(${SERVER_ACTIVE_CORES_LIST[@]} ${SERVER_PHYSICAL_CORES[$index]})
		
	done
	CLIENT_ACTIVE_CORES_LIST=(${CLIENT_ACTIVE_CORES_LIST[@]})
	SERVER_ACTIVE_CORES_LIST=(${SERVER_ACTIVE_CORES_LIST[@]})

	readarray -t sorted < <(for a in "${CLIENT_ACTIVE_CORES_LIST[@]}"; do echo "$a"; done | sort -n)
	CLIENT_ACTIVE_CORES_LIST=$(printf ",%s" "${sorted[@]}")
	CLIENT_ACTIVE_CORES_LIST=${CLIENT_ACTIVE_CORES_LIST:1}
	sorted=()
	readarray -t sorted < <(for a in "${SERVER_ACTIVE_CORES_LIST[@]}"; do echo "$a"; done | sort -n)
	SERVER_ACTIVE_CORES_LIST=$(printf ",%s" "${sorted[@]}")
	SERVER_ACTIVE_CORES_LIST=${SERVER_ACTIVE_CORES_LIST:1}

	scp ${scriptdir}/run_iperf3_* ${SERVER_TRUSTED}:/tmp/
	scp ${scriptdir}/run_iperf3_* ${CLIENT_TRUSTED}:/tmp/
	
	ssh ${SERVER_TRUSTED} "/tmp/run_iperf3_servers.sh $PROC $SERVER_ACTIVE_CORES_LIST $BASE_TCP_PORT $TIME &" &
	if [[ $DUPLEX == "FULL" ]]; then
		sleep 0.1
		ssh ${CLIENT_TRUSTED} "/tmp/run_iperf3_servers.sh $PROC $CLIENT_ACTIVE_CORES_LIST $((BASE_TCP_PORT*2)) $TIME &" &
	fi

	check_connection
	
	ssh ${CLIENT_TRUSTED} "/tmp/run_iperf3_clients.sh $RESULT_FILE $PROC $CLIENT_ACTIVE_CORES_LIST ${SERVER_IP[$((${P}%${IP_AMOUNT}))]} $BASE_TCP_PORT $THREADS $TIME &" &
	if [[ $DUPLEX == "FULL" ]]; then
		sleep 0.1
		ssh ${SERVER_TRUSTED} "/tmp/run_iperf3_clients.sh $RESULT_FILE $PROC $SERVER_ACTIVE_CORES_LIST ${CLIENT_IP[$((${P}%${IP_AMOUNT}))]} $((BASE_TCP_PORT*2)) $THREADS $TIME &" &
	fi
	# ssh ${SERVER_TRUSTED} "bash -s" -- < ${scriptdir}/run_iperf3_servers.sh $PROC $SERVER_NUMA_NODE $SERVER_LOGICAL_NUMA_PER_SOCKET $SERVER_BASE_NUMA $BASE_TCP_PORT &
	# if [[ $DUPLEX == "FULL" ]]; then
	# 	sleep 0.1
	# 	ssh ${CLIENT_TRUSTED} "bash -s" -- < ${scriptdir}/run_iperf3_servers.sh $PROC $CLIENT_NUMA_NODE $CLIENT_LOGICAL_NUMA_PER_SOCKET $CLIENT_BASE_NUMA $((BASE_TCP_PORT*2)) &
	# fi

	# check_connection
	
	# ssh ${CLIENT_TRUSTED} "bash -s" -- < ${scriptdir}/run_iperf3_clients.sh $RESULT_FILE $PROC $CLIENT_NUMA_NODE $CLIENT_LOGICAL_NUMA_PER_SOCKET $CLIENT_BASE_NUMA ${SERVER_IP[$((${P}%${IP_AMOUNT}))]} $BASE_TCP_PORT $THREADS $TIME &
	# if [[ $DUPLEX == "FULL" ]]; then
	# 	sleep 0.1
	# 	ssh ${SERVER_TRUSTED} "bash -s" -- < ${scriptdir}/run_iperf3_clients.sh $RESULT_FILE $PROC $SERVER_NUMA_NODE $SERVER_LOGICAL_NUMA_PER_SOCKET $SERVER_BASE_NUMA ${CLIENT_IP[$((${P}%${IP_AMOUNT}))]} $((BASE_TCP_PORT*2)) $THREADS $TIME &
	# fi
	
	DURATION=$( expr $TIME - 3 )
	ssh ${CLIENT_TRUSTED} "sar -u -P $CLIENT_ACTIVE_CORES_LIST,all $DURATION 1 | grep \"Average\" | head -n $( expr $PROC + 2 ) > $CLIENT_CORE_USAGES_FILE$$" & 
	ssh ${SERVER_TRUSTED} "sar -u -P $SERVER_ACTIVE_CORES_LIST,all $DURATION 1 | grep \"Average\" | head -n $( expr $PROC + 2 ) > $SERVER_CORE_USAGES_FILE$$" &
	
	wait
	ssh ${CLIENT_TRUSTED} "cat $RESULT_FILE* > $CLIENT_RESULT_RUN"
	if ! [ -f $CLIENT_RESULT_RUN ]; then 
		scp ${CLIENT_TRUSTED}:$CLIENT_RESULT_RUN $CLIENT_RESULT_RUN
	fi
	IPERF_TPUT_CLIENT=`cat $CLIENT_RESULT_RUN | grep sum_sent -A7 | grep bits_per_second | tr "," " " | awk '{ SUM+=$NF } END { print SUM } '`
	BITS_CLIENT=`printf '%.0f' $IPERF_TPUT_CLIENT`

	if [[ $DUPLEX == "FULL" ]]; then
		ssh ${SERVER_TRUSTED} "cat $RESULT_FILE* > $SERVER_RESULT_RUN"
		if ! [ -f $SERVER_RESULT_RUN ]; then 
			scp ${SERVER_TRUSTED}:$SERVER_RESULT_RUN $SERVER_RESULT_RUN
			IPERF_TPUT_SERVER=`cat $SERVER_RESULT_RUN | grep sum_sent -A7 | grep bits_per_second | tr "," " " | awk '{ SUM+=$NF } END { print SUM } '`
			BITS_SERVER=`printf '%.0f' $IPERF_TPUT_SERVER`
		fi
	fi

	CLIENT_THROUGHPUT=`bc -l <<< "scale=2; $BITS_CLIENT/1000000000"`
	if [[ $DUPLEX == "FULL" ]]; then
		SERVER_THROUGHPUT=`bc -l <<< "scale=2; $BITS_SERVER/1000000000"`
		tmp_sum="$CLIENT_THROUGHPUT $SERVER_THROUGHPUT"
		THROUGHPUT=`bc <<< "${tmp_sum// /+}"`
	else
		THROUGHPUT=$CLIENT_THROUGHPUT
	fi
	
	echo "Throughput is: $THROUGHPUT Gb/s" | tee -a  $RESULT_SUMMARY
	echo "${CLIENT_TRUSTED} Active cores: $CLIENT_ACTIVE_CORES_LIST" | tee -a  $RESULT_SUMMARY
	echo "Active core usages on ${CLIENT_TRUSTED}" | tee -a  $RESULT_SUMMARY
	ssh ${CLIENT_TRUSTED} "cat $CLIENT_CORE_USAGES_FILE$$" | sed 's/|/ /' | awk '{print $2 "\t" $5}'
	USAGES=(`ssh ${CLIENT_TRUSTED} "cat $CLIENT_CORE_USAGES_FILE$$" | tail -n +2 | sed 's/|/ /' | awk '{print $5}'`)
	TOTAL_ACTIVE_AVERAGE=`get_average ${USAGES[@]}`
	paste <(echo "Overall Active: $TOTAL_ACTIVE_AVERAGE") <(echo "Overall All cores: ") <(ssh ${CLIENT_TRUSTED} "cat $CLIENT_CORE_USAGES_FILE$$" | grep all | sed 's/|/ /' | awk '{print $5}') | tee -a  $RESULT_SUMMARY

	echo "${SERVER_TRUSTED} Active cores: $SERVER_ACTIVE_CORES_LIST" | tee -a  $RESULT_SUMMARY
	echo "Active core usages on ${SERVER_TRUSTED}" | tee -a  $RESULT_SUMMARY
	ssh ${SERVER_TRUSTED} "cat $SERVER_CORE_USAGES_FILE$$" | sed 's/|/ /' | awk '{print $2 "\t" $5}'
	USAGES=(`ssh ${SERVER_TRUSTED} "cat $SERVER_CORE_USAGES_FILE$$" | tail -n +2 | sed 's/|/ /' | awk '{print $5}'`)
	TOTAL_ACTIVE_AVERAGE=`get_average ${USAGES[@]}`
	paste <(echo "Overall Active: $TOTAL_ACTIVE_AVERAGE") <(echo "Overall All cores: ") <(ssh ${SERVER_TRUSTED} "cat $SERVER_CORE_USAGES_FILE$$" | grep all | sed 's/|/ /' | awk '{print $5}') | tee -a  $RESULT_SUMMARY

	ssh ${SERVER_TRUSTED} "rm -f /tmp/run_iperf3*"
	ssh ${CLIENT_TRUSTED} "rm -f /tmp/run_iperf3*"
	clean_measurement_files
}
