#!/bin/bash

if [[ -z $4 ]]; then
	echo "usage: $0 <client hostname> <client ib device> <server hostname> <server ib device>"
	exit 1
fi

CLIENT_IP=$1
CLIENT_DEVICE=$2
SERVER_IP=$3
SERVER_DEVICE=$4
LOCAL_BF=$5
REMOTE_BF=$6

# please 
CLIENT_NUMA_NODE=`ssh ${CLIENT_IP} cat /sys/class/infiniband/${CLIENT_DEVICE}/device/numa_node`
SERVER_NUMA_NODE=`ssh ${SERVER_IP} cat /sys/class/infiniband/${SERVER_DEVICE}/device/numa_node`

# Set pass rate to 90% of the bidirectional link speed
BW_PASS_RATE=$(echo 2*0.9*`ssh ${CLIENT_IP} cat /sys/class/infiniband/${CLIENT_DEVICE}/ports/1/rate` | awk '{ print $1}' | bc -l )

# Set IPsec offload on both BlueFields
if [[ ! -z "${LOCAL_BF}" ]] && [[ ! -z "${REMOTE_BF}" ]]; then
	net_name=`ssh ${CLIENT_IP} ls -l /sys/class/infiniband/${CLIENT_DEVICE}/device/net/ |tail -1 | cut -d" " -f9`
	MTU=`ssh ${CLIENT_IP} ip addr | grep mtu | grep ${net_name} | cut -d" " -f5`
	scriptdir="$(dirname "$0")"
	cd "$scriptdir"
	bash ./ipsec_full_offload_setup.sh ${LOCAL_BF} ${REMOTE_BF} $(( ${MTU} + 500 ))
fi

for TEST in ib_write_bw ib_read_bw ib_send_bw ; do 

ssh ${SERVER_IP} numactl --cpunodebind=${SERVER_NUMA_NODE} $TEST -d ${SERVER_DEVICE} --report_gbit -a -b --limit_bw=${BW_PASS_RATE} -q4 & 
sleep 2
ssh ${CLIENT_IP} numactl --cpunodebind=${CLIENT_NUMA_NODE} $TEST -d ${CLIENT_DEVICE} --report_gbit -a -b ${SERVER_IP} --limit_bw=${BW_PASS_RATE} -q4
RC=$?

if [[ $RC -eq 0 ]]; then
	echo "NGC $TEST Passed"
else
	echo "NGC $TEST Failed"
fi

done


