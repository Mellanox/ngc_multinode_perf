#!/bin/bash

# RESULT_FILE=/tmp/ngc_result_run.log
# PROC=$1
# NUMA_NODE=$2
# LOGICAL_NUMA_PER_SOCKET=$3
# BASE_NUMA=$4
# IP=$5
# BASE_TCP_PORT=$6
# THREADS=$7
# TIME=$8

RESULT_FILE=$1
PROC=$2
CORES="$3"
IP=$4
BASE_TCP_PORT=$5
THREADS=$6
TIME=$7

CORES_ARR=(${CORES//,/ })

for P in ${CORES_ARR[@]}
       do ( sleep 0.1
                taskset -c $P timeout $((TIME+5)) iperf3 -Z -N -i 60 -c ${IP}  -P ${THREADS}  -t ${TIME} -p $((BASE_TCP_PORT+P)) -J --logfile $RESULT_FILE$P & 
                       )
       done
