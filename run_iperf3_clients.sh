#!/bin/bash

RESULT_FILE=/tmp/ngc_run_result.log
PROC=$1
NUMA_NODE=$2
LOGICAL_NUMA_PER_SOCKET=$3
BASE_NUMA=$4
IP=$5
BASE_TCP_PORT=$6
THREADS=$7
TIME=$8

for P in `seq 0 $((PROC-1))`
    do ( sleep 0.1
        numactl --cpunodebind=$(((NUMA_NODE+P)%$LOGICAL_NUMA_PER_SOCKET+$BASE_NUMA)) numactl --physcpubind=+$((P/LOGICAL_NUMA_PER_SOCKET)) iperf3 -Z -N -i 60 -c ${IP}  -P ${THREADS}  -t ${TIME} -p $((BASE_TCP_PORT+P)) -J &
            )
    done | tee $RESULT_FILE
