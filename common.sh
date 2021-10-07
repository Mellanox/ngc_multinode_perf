#!/bin/bash
# NGC Certification common functions v0.1
# Owner: dorko@nvidia.com
#


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
TIME=120
TCP_PORT_ID=`echo $CLIENT_DEVICE | cut -d "_" -f 2`
TCP_PORT_ADDITION=`echo $TCP_PORT_ID*100 | bc -l `
BASE_TCP_PORT=$(($RANDOM+5200+$TCP_PORT_ADDITION))
NUMACTL_HW='numactl --hardware | grep -v node'

# Get Client NUMA topology
CLIENT_HW_NUMA_LINE_FULL=`ssh ${CLIENT_TRUSTED} $NUMACTL_HW | grep " $CLIENT_NUMA_NODE:" `
CLIENT_LOGICAL_NUMA_PER_SOCKET=`echo $CLIENT_HW_NUMA_LINE_FULL | tr ' ' '\n' | grep -v ":" | egrep '10|11|12' | wc -l`
if [[ $CLIENT_LOGICAL_NUMA_PER_SOCKET -eq 0 ]]; then echo "Error - 0 detected" ; exit 1 ; fi
N=-1 ; for I in $CLIENT_HW_NUMA_LINE_FULL ; do if [[ $I == 11 || $I == 12 || $I == 10 ]]; then CLIENT_FIRST_SIBLING_NUMA=$N; break; else N=$((N+1)) ; fi ;  done
CLIENT_BASE_NUMA=`echo $(($CLIENT_FIRST_SIBLING_NUMA<$CLIENT_NUMA_NODE ? $CLIENT_FIRST_SIBLING_NUMA : $CLIENT_NUMA_NODE))`

# Get Server NUMA topology
SERVER_HW_NUMA_LINE_FULL=`ssh ${SERVER_TRUSTED} $NUMACTL_HW | grep " $SERVER_NUMA_NODE:" `
SERVER_LOGICAL_NUMA_PER_SOCKET=`echo $SERVER_HW_NUMA_LINE_FULL | tr ' ' '\n' | grep -v ":" | egrep '10|11|12' | wc -l`
if [[ $SERVER_LOGICAL_NUMA_PER_SOCKET -eq 0 ]]; then echo "Error - 0 detected" ; exit 1 ; fi
N=-1 ; for I in $SERVER_HW_NUMA_LINE_FULL ; do if [[ $I == 11 || $I == 12 || $I == 10 ]]; then SERVER_FIRST_SIBLING_NUMA=$N; break; else N=$((N+1)) ; fi ;  done
SERVER_BASE_NUMA=`echo $(($SERVER_FIRST_SIBLING_NUMA<$SERVER_NUMA_NODE ? $SERVER_FIRST_SIBLING_NUMA : $SERVER_NUMA_NODE))`
}

function run_iperf3 {

PROC=`printf "%s\n" $CLIENT_AFFINITY_IRQ_COUNT $SERVER_AFFINITY_IRQ_COUNT $MAX_PROC | sort -h | head -n1`
#check amount of IPs for interface asked, and run iperf3 mutli proccess each on another ip.
IP_AMOUNT=$(printf "%s\n" ${#SERVER_IP[@]} ${#CLIENT_IP[@]} | sort -h | head -n1)

echo -- starting iperf with $PROC processes $THREADS threads --

    for P in `seq 0 $((PROC-1))`
		do ( sleep 0.1 
			ssh ${SERVER_TRUSTED} numactl --cpunodebind=$(((SERVER_NUMA_NODE+P)%$SERVER_LOGICAL_NUMA_PER_SOCKET+$SERVER_BASE_NUMA)) numactl --physcpubind=+$((P/SERVER_LOGICAL_NUMA_PER_SOCKET)) iperf3 -s -p $((BASE_TCP_PORT+P)) --one-off & 
			if [[ $DUPLEX == "FULL" ]]; then
				ssh ${CLIENT_TRUSTED} numactl --cpunodebind=$(((CLIENT_NUMA_NODE+P)%$CLIENT_LOGICAL_NUMA_PER_SOCKET+$CLIENT_BASE_NUMA)) numactl --physcpubind=+$((P/CLIENT_LOGICAL_NUMA_PER_SOCKET)) iperf3 -s -p $((BASE_TCP_PORT+P)) --one-off & 
			fi
			)
		done | tee $LOG_SERVER &

	check_connection
    
	for P in `seq 0 $((PROC-1))`
        do ( sleep 0.1
			 ssh ${CLIENT_TRUSTED} numactl --cpunodebind=$(((CLIENT_NUMA_NODE+P)%$CLIENT_LOGICAL_NUMA_PER_SOCKET+$CLIENT_BASE_NUMA)) numactl --physcpubind=+$((P/CLIENT_LOGICAL_NUMA_PER_SOCKET)) iperf3 -c ${SERVER_IP[$((${P}%${IP_AMOUNT}))]}  -P ${THREADS}  -t ${TIME} -p $((BASE_TCP_PORT+P)) -J & 
			 if [[ $DUPLEX == "FULL" ]]; then
				sleep 0.1
				ssh ${SERVER_TRUSTED} numactl --cpunodebind=$(((SERVER_NUMA_NODE+P)%$SERVER_LOGICAL_NUMA_PER_SOCKET+$SERVER_BASE_NUMA)) numactl --physcpubind=+$((P/SERVER_LOGICAL_NUMA_PER_SOCKET)) iperf3 -c ${CLIENT_IP[$((${P}%${IP_AMOUNT}))]} -P ${THREADS}  -t ${TIME} -p $((BASE_TCP_PORT+P)) -J & 
			 fi
			)
        done | tee $LOG_CLIENT &
        wait

        IPERF_TPUT=`cat $LOG_CLIENT | grep sum_sent -A7 | grep bits_per_second | tr "," " " | awk '{ SUM+=$NF } END { print SUM } '`
	BITS=`printf '%.0f' $IPERF_TPUT`
        echo "Throughput is: `bc -l <<< "scale=2; $BITS/1000000000"` Gb/s"
}