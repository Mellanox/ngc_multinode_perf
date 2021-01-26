#!/bin/bash
# NGC Certification TCP test v2.1
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

CLIENT_NETDEV=`ssh ${CLIENT_IP} ls /sys/class/infiniband/${CLIENT_DEVICE}/device/net `
SERVER_NETDEV=`ssh ${SERVER_IP} ls /sys/class/infiniband/${SERVER_DEVICE}/device/net`

PROC=16
THREADS=1
TIME=120
TCP_PORT_ID=`echo $CLIENT_DEVICE | cut -d "_" -f 2`
TCP_PORT_ADDITION=`echo $TCP_PORT_ID*100 | bc -l `
BASE_TCP_PORT=$((5200+$TCP_PORT_ADDITION))
NUMACTL_HW='numactl --hardware | grep -v node'

# Get Client NUMA topology
CLIENT_HW_NUMA_LINE_FULL=`ssh ${CLIENT_IP} $NUMACTL_HW | grep " $CLIENT_NUMA_NODE:" `
CLIENT_LOGICAL_NUMA_PER_SOCKET=`echo $CLIENT_HW_NUMA_LINE_FULL | tr ' ' '\n' | grep -v ":" | egrep '10|11|12' | wc -l`
if [[ $CLIENT_LOGICAL_NUMA_PER_SOCKET -eq 0 ]]; then echo "Error - 0 detected" ; exit 1 ; fi
N=-1 ; for I in $CLIENT_HW_NUMA_LINE_FULL ; do if [[ $I == 11 || $I == 12 || $I == 10 ]]; then CLIENT_FIRST_SIBLING_NUMA=$N; break; else N=$((N+1)) ; fi ;  done
CLIENT_BASE_NUMA=`echo $(($CLIENT_FIRST_SIBLING_NUMA<$CLIENT_NUMA_NODE ? $CLIENT_FIRST_SIBLING_NUMA : $CLIENT_NUMA_NODE))`

# Get Server NUMA topology
SERVER_HW_NUMA_LINE_FULL=`ssh ${SERVER_IP} $NUMACTL_HW | grep " $SERVER_NUMA_NODE:" `
SERVER_LOGICAL_NUMA_PER_SOCKET=`echo $SERVER_HW_NUMA_LINE_FULL | tr ' ' '\n' | grep -v ":" | egrep '10|11|12' | wc -l`
if [[ $SERVER_LOGICAL_NUMA_PER_SOCKET -eq 0 ]]; then echo "Error - 0 detected" ; exit 1 ; fi
N=-1 ; for I in $SERVER_HW_NUMA_LINE_FULL ; do if [[ $I == 11 || $I == 12 || $I == 10 ]]; then SERVER_FIRST_SIBLING_NUMA=$N; break; else N=$((N+1)) ; fi ;  done
SERVER_BASE_NUMA=`echo $(($SERVER_FIRST_SIBLING_NUMA<$SERVER_NUMA_NODE ? $SERVER_FIRST_SIBLING_NUMA : $SERVER_NUMA_NODE))`

# Stop IRQ balancer service
ssh ${CLIENT_IP} systemctl stop irqbalance
ssh ${SERVER_IP} systemctl stop irqbalance

# Increase MTU to maximum per link type
LINK_TYPE=`ssh ${CLIENT_IP} cat /sys/class/infiniband/${CLIENT_DEVICE}/device/net/\*/type`
if [ $LINK_TYPE -eq 1 ]; then
	MTU=9000
elif [ $LINK_TYPE -eq 32 ]; then
	MTU=4092
fi

ssh ${CLIENT_IP} "echo $MTU > /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/mtu"
sleep 2
ssh ${SERVER_IP} "echo $MTU > /sys/class/infiniband/${SERVER_DEVICE}/device/net/*/mtu"
sleep 2

# Change number of channels to number of CPUs in the socket
CLIENT_PRESET_MAX=`ssh ${CLIENT_IP} ethtool -l $CLIENT_NETDEV | grep Combined | head -1 | awk '{ print $2}'`
SERVER_PRESET_MAX=`ssh ${SERVER_IP} ethtool -l $SERVER_NETDEV | grep Combined | head -1 | awk '{ print $2}'`
for N in `seq ${CLIENT_BASE_NUMA} $((CLIENT_BASE_NUMA+CLIENT_LOGICAL_NUMA_PER_SOCKET-1))` ; do CLIENT_CPUCOUNT=$((CLIENT_CPUCOUNT+`ssh $CLIENT_IP ls /sys/devices/system/node/node$N/ | egrep 'cpu[0-9]' | wc -l`)) ; done
for N in `seq ${SERVER_BASE_NUMA} $((SERVER_BASE_NUMA+SERVER_LOGICAL_NUMA_PER_SOCKET-1))` ; do SERVER_CPUCOUNT=$((SERVER_CPUCOUNT+`ssh $SERVER_IP ls /sys/devices/system/node/node$N/ | egrep 'cpu[0-9]' | wc -l`)) ; done
ssh $CLIENT_IP ethtool -L $CLIENT_NETDEV combined `echo $(($CLIENT_CPUCOUNT<$CLIENT_PRESET_MAX ? $CLIENT_CPUCOUNT : $CLIENT_PRESET_MAX))`
ssh $SERVER_IP ethtool -L $SERVER_NETDEV combined `echo $(($SERVER_CPUCOUNT<$SERVER_PRESET_MAX ? $SERVER_CPUCOUNT : $SERVER_PRESET_MAX))`

# Enable aRFS for ethernet links
if [ $LINK_TYPE -eq 1 ]; then
	ssh ${CLIENT_IP} "ethtool -K ${CLIENT_NETDEV} ntuple on"
	ssh ${CLIENT_IP} "echo 32768 > /proc/sys/net/core/rps_sock_flow_entries"
	ssh ${CLIENT_IP} 'for f in /sys/class/net/"'$CLIENT_NETDEV'"/queues/rx-*/rps_flow_cnt; do echo 32768 > $f; done'

	ssh ${SERVER_IP} "ethtool -K ${SERVER_NETDEV} ntuple on"
	ssh ${SERVER_IP} "echo 32768 > /proc/sys/net/core/rps_sock_flow_entries"
	ssh ${SERVER_IP} 'for f in /sys/class/net/"'$SERVER_NETDEV'"/queues/rx-*/rps_flow_cnt; do echo 32768 > $f; done'
fi

# Set IRQ affinity to local socket CPUs
NUMA_TOPO="numactl -H"
CLIENT_NUMA_TOPO=$(ssh $CLIENT_IP $NUMA_TOPO)
SERVER_NUMA_TOPO=$(ssh $SERVER_IP $NUMA_TOPO)
THREAD_PER_CORE="lscpu | grep Thread | grep -oP \"\d+\""
CLIENT_THREAD_PER_CORE=$(ssh $CLIENT_IP "$THREAD_PER_CORE")
SERVER_THREAD_PER_CORE=$(ssh $SERVER_IP "$THREAD_PER_CORE")
CLIENT_PHYSICAL_CORE_COUNT=$((CLIENT_CPUCOUNT/CLIENT_LOGICAL_NUMA_PER_SOCKET/CLIENT_THREAD_PER_CORE))
SERVER_PHYSICAL_CORE_COUNT=$((SERVER_CPUCOUNT/SERVER_LOGICAL_NUMA_PER_SOCKET/SERVER_THREAD_PER_CORE))
CLIENT_PHYSICAL_CORES=()
CLIENT_LOGICAL_CORES=()
SERVER_PHYSICAL_CORES=()
SERVER_LOGICAL_CORES=()
for node in $(seq $CLIENT_FIRST_SIBLING_NUMA $((CLIENT_FIRST_SIBLING_NUMA+CLIENT_LOGICAL_NUMA_PER_SOCKET-1))) ; do
    numa_cores=($(echo "$CLIENT_NUMA_TOPO" | grep "node $node cpus" | cut -d":" -f2))
    CLIENT_PHYSICAL_CORES=(${CLIENT_PHYSICAL_CORES[@]} ${numa_cores[@]:0:CLIENT_PHYSICAL_CORE_COUNT})
    CLIENT_LOGICAL_CORES=(${CLIENT_LOGICAL_CORES[@]} ${numa_cores[@]:CLIENT_PHYSICAL_CORE_COUNT})
done
for node in $(seq $SERVER_FIRST_SIBLING_NUMA $((SERVER_FIRST_SIBLING_NUMA+SERVER_LOGICAL_NUMA_PER_SOCKET-1))) ; do
    numa_cores=($(echo "$SERVER_NUMA_TOPO" | grep "node $node cpus" | cut -d":" -f2))
    SERVER_PHYSICAL_CORES=(${SERVER_PHYSICAL_CORES[@]} ${numa_cores[@]:0:SERVER_PHYSICAL_CORE_COUNT})
    SERVER_LOGICAL_CORES=(${SERVER_LOGICAL_CORES[@]} ${numa_cores[@]:SERVER_PHYSICAL_CORE_COUNT})
done
CLIENTS_AFFINITY_CORES=(${CLIENT_PHYSICAL_CORES[@]} ${CLIENT_LOGICAL_CORES[@]})
SERVER_AFFINITY_CORES=(${CLIENT_PHYSICAL_CORES[@]} ${SERVER_LOGICAL_CORES[@]})
CLIENT_AFFINITY_IRQ_COUNT=$((CLIENT_CPUCOUNT<CLIENT_PRESET_MAX ? CLIENT_CPUCOUNT : CLIENT_PRESET_MAX))
SERVER_AFFINITY_IRQ_COUNT=$((SERVER_CPUCOUNT<SERVER_PRESET_MAX ? SERVER_CPUCOUNT : SERVER_PRESET_MAX))

ssh ${CLIENT_IP} set_irq_affinity_cpulist.sh "$(tr " " "," <<< "${CLIENTS_AFFINITY_CORES[@]::CLIENT_AFFINITY_IRQ_COUNT}")" $CLIENT_NETDEV
ssh ${SERVER_IP} set_irq_affinity_cpulist.sh "$(tr " " "," <<< "${SERVER_AFFINITY_CORES[@]::SERVER_AFFINITY_IRQ_COUNT}") "$SERVER_NETDEV

# Toggle interfaces down/up so channels allocation will be according to actual IRQ affinity
ssh ${SERVER_IP} "ip l s down $SERVER_NETDEV ; ip l s up $SERVER_NETDEV"
sleep 1
ssh ${CLIENT_IP} "ip l s down $CLIENT_NETDEV ; ip l s up $CLIENT_NETDEV"
sleep 1

echo -- starting iperf with $PROC processes $THREADS threads --

        for P in `seq 0 $((PROC-1))`
        do ( sleep 0.1 ; ssh ${SERVER_IP} numactl --cpunodebind=$(((SERVER_NUMA_NODE+P)%$SERVER_LOGICAL_NUMA_PER_SOCKET+$SERVER_BASE_NUMA)) numactl --physcpubind=+$((P/SERVER_LOGICAL_NUMA_PER_SOCKET)) iperf3 -s -p $((BASE_TCP_PORT+P)) --one-off & )
		done | tee $LOG_SERVER &

	sleep 5

	for P in `seq 0 $((PROC-1))`
        do ( sleep 0.1 ; ssh ${CLIENT_IP} numactl --cpunodebind=$(((CLIENT_NUMA_NODE+P)%$CLIENT_LOGICAL_NUMA_PER_SOCKET+$CLIENT_BASE_NUMA)) numactl --physcpubind=+$((P/CLIENT_LOGICAL_NUMA_PER_SOCKET)) iperf3 -c ${SERVER_IP}  -P ${THREADS}  -t ${TIME} -p $((BASE_TCP_PORT+P)) -J & )
        done | tee $LOG_CLIENT &
        wait

        IPERF_TPUT=`cat $LOG_CLIENT | grep sum_sent -A7 | grep bits_per_second | tr "," " " | awk '{ SUM+=$NF } END { print SUM } '`
	BITS=`printf '%.0f' $IPERF_TPUT`
        echo "Throughput is: `bc -l <<< "scale=2; $BITS/1000000000"` Gb/s"

set +x
