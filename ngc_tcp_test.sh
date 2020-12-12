#!/bin/bash
# NGC Certification TCP test v2.0.5
# Owner: amira@nvidia.com
#

set -x
if [[ -z $4 ]]; then
	echo "usage: $0 <client ip> <client ib device> <server ip> <server ib device>"
	exit 1
fi

CLIENT_IP=$1
CLIENT_DEVICE=$2
SERVER_IP=$3
SERVER_DEVICE=$4
LOG_CLIENT=ngc_tcp_client_${CLIENT_IP}.log
LOG_SERVER=ngc_tcp_server_${SERVER_IP}.log

ssh ${CLIENT_IP} pkill iperf3
ssh ${SERVER_IP} pkill iperf3

CLIENT_NUMA_NODE=`ssh ${CLIENT_IP} cat /sys/class/infiniband/${CLIENT_DEVICE}/device/numa_node`
SERVER_NUMA_NODE=`ssh ${SERVER_IP} cat /sys/class/infiniband/${SERVER_DEVICE}/device/numa_node`

PROC=8
THREADS=2
TIME=60
TCP_PORT_ID=`echo $CLIENT_DEVICE | cut -d "_" -f 2`
TCP_PORT_ADDITION=`echo $TCP_PORT_ID*100 | bc -l `
BASE_TCP_PORT=$((5200+$TCP_PORT_ADDITION))
NUMACTL_HW='numactl --hardware | grep -v node'


CLIENT_HW_NUMA_LINE_FULL=`ssh ${CLIENT_IP} $NUMACTL_HW | grep " $CLIENT_NUMA_NODE:" `
CLIENT_LOGICAL_NUMA_PER_SOCKET=`echo $CLIENT_HW_NUMA_LINE_FULL | tr ' ' '\n' | grep -v ":" | egrep '10|11' | wc -l`
if [[ $CLIENT_LOGICAL_NUMA_PER_SOCKET -eq 0 ]]; then echo "Error - 0 detected" ; exit 1 ; fi 
if [[ $CLIENT_HW_NUMA_LINE_FULL == *11* ]]; then
	CLIENT_FIRST_SIBLING_NUMA=`python -c "import sys ; print(sys.argv.index('11')-2)" $CLIENT_HW_NUMA_LINE_FULL`
else
	CLIENT_FIRST_SIBLING_NUMA=$CLIENT_NUMA_NODE
fi
CLIENT_BASE_NUMA=`echo $(($CLIENT_FIRST_SIBLING_NUMA<$CLIENT_NUMA_NODE ? $CLIENT_FIRST_SIBLING_NUMA : $CLIENT_NUMA_NODE))`


SERVER_HW_NUMA_LINE_FULL=`ssh ${SERVER_IP} $NUMACTL_HW | grep " $SERVER_NUMA_NODE:" `
SERVER_LOGICAL_NUMA_PER_SOCKET=`echo $SERVER_HW_NUMA_LINE_FULL | tr ' ' '\n' | grep -v ":" | egrep '10|11' | wc -l`
if [[ $SERVER_LOGICAL_NUMA_PER_SOCKET -eq 0 ]]; then echo "Error - 0 detected" ; exit 1 ; fi 
if [[ $SERVER_HW_NUMA_LINE_FULL == *11* ]]; then
	SERVER_FIRST_SIBLING_NUMA=`python -c "import sys ; print(sys.argv.index('11')-2)" $SERVER_HW_NUMA_LINE_FULL`
else
	SERVER_FIRST_SIBLING_NUMA=$SERVER_NUMA_NODE
fi
SERVER_BASE_NUMA=`echo $(($SERVER_FIRST_SIBLING_NUMA<$SERVER_NUMA_NODE ? $SERVER_FIRST_SIBLING_NUMA : $SERVER_NUMA_NODE))`

for N in `seq ${CLIENT_BASE_NUMA} $((CLIENT_BASE_NUMA+CLIENT_LOGICAL_NUMA_PER_SOCKET-1))` ; do CLIENT_CPULIST=$CLIENT_CPULIST,`ssh $CLIENT_IP cat /sys/devices/system/node/node$N/cpulist` ; done
for N in `seq ${SERVER_BASE_NUMA} $((SERVER_BASE_NUMA+SERVER_LOGICAL_NUMA_PER_SOCKET-1))` ; do SERVER_CPULIST=$SERVER_CPULIST,`ssh $SERVER_IP cat /sys/devices/system/node/node$N/cpulist` ; done
 
CLIENT_CPULIST=`if [[ $CLIENT_CPULIST == ,* ]]; then echo ${CLIENT_CPULIST:1} ; fi`
SERVER_CPULIST=`if [[ $SERVER_CPULIST == ,* ]]; then echo ${SERVER_CPULIST:1} ; fi`


ssh ${CLIENT_IP} systemctl stop irqbalance
ssh ${SERVER_IP} systemctl stop irqbalance

#TODO:
#ssh ${CLIENT_IP} for f in /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/queues/rx-*/rps_flow_cnt ; do echo 2048 > $f ;done
#ssh ${SERVER_IP} for f in /sys/class/infiniband/${SERVER_DEVICE}/device/net/*/queues/rx-*/rps_flow_cnt ; do echo 2048 > $f ;done


LINK_TYPE=`ssh ${CLIENT_IP} cat /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/type`
if [ $LINK_TYPE -eq 1 ]; then
	MTU=9000
elif [ $LINK_TYPE -eq 32 ]; then
	MTU=4092
fi

ssh ${CLIENT_IP} "echo $MTU > /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/mtu"
sleep 2
ssh ${SERVER_IP} "echo $MTU > /sys/class/infiniband/${SERVER_DEVICE}/device/net/*/mtu"
sleep 2

ssh ${CLIENT_IP} set_irq_affinity_cpulist.sh $CLIENT_CPULIST $CLIENT_DEVICE 
ssh ${SERVER_IP} set_irq_affinity_cpulist.sh $SERVER_CPULIST $SERVER_DEVICE 

echo -- starting iperf with $PROC processes $THREADS threads --

        for P in `seq 0 $((PROC-1))`
        do ( sleep 0.1 ; ssh ${SERVER_IP} numactl --cpunodebind=$(((SERVER_NUMA_NODE+P)%$SERVER_LOGICAL_NUMA_PER_SOCKET+$SERVER_BASE_NUMA)) iperf3 -s -p $((BASE_TCP_PORT+P)) --one-off & )
		done | tee $LOG_SERVER &
	
	sleep 5 
       
	for P in `seq 0 $((PROC-1))`
        do ( sleep 0.1 ; ssh ${CLIENT_IP} numactl --cpunodebind=$(((CLIENT_NUMA_NODE+P)%$CLIENT_LOGICAL_NUMA_PER_SOCKET+$CLIENT_BASE_NUMA)) iperf3 -c ${SERVER_IP}  -P ${THREADS}  -t ${TIME} -p $((BASE_TCP_PORT+P)) -J & )
        done | tee $LOG_CLIENT &
        wait

        IPERF_TPUT=`cat $LOG_CLIENT | grep sum_sent -A7 | grep bits_per_second | tr "," " " | awk '{ SUM+=$NF } END { print SUM } '`
	BITS=`printf '%.0f' $IPERF_TPUT`
        echo "Throughput is: `bc -l <<< "scale=2; $BITS/1000000000"` Gb/s"

set +x