#!/bin/bash

# PROC=$1
# NUMA_NODE=$2
# LOGICAL_NUMA_PER_SOCKET=$3
# BASE_NUMA=$4
# BASE_TCP_PORT=$5

PROC=$1
CORES="$2"
BASE_TCP_PORT=$3
TIME=$4


CORES_ARR=(${CORES//,/ })
 
for P in ${CORES_ARR[@]}
       do ( sleep 0.5 
            taskset -c $P timeout $((TIME+10)) iperf3 -s -p $((BASE_TCP_PORT+P)) --one-off & 
               )
       done
