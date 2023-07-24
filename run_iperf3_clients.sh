#!/bin/bash

RESULT_FILE=$1
PROC=$2
NUMA_NODE=$3
LOGICAL_NUMA_PER_SOCKET=$4
BASE_NUMA=$5
IP=$6
BASE_TCP_PORT=$7
THREADS=$8
TIME=$9

for P in $(seq 0 $((PROC-1)))
    do ( sleep 0.1
         numactl --cpunodebind=$(((NUMA_NODE+P)%LOGICAL_NUMA_PER_SOCKET+BASE_NUMA)) \
             numactl --physcpubind=+$((P/LOGICAL_NUMA_PER_SOCKET)) \
             iperf3 -Z -N -i 60 -c "${IP}"  -P "${THREADS}"  -t "${TIME}" \
             -p $((BASE_TCP_PORT+P)) -J &
        )
    done | tee "${RESULT_FILE}"
