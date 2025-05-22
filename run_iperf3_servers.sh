#!/bin/bash

PROC=$1
NUMA_NODE=$2
LOGICAL_NUMA_PER_SOCKET=$3
BASE_NUMA=$4
BASE_TCP_PORT=$5
BIND_IP="${6}"



for P in $(seq 0 $((PROC-1)))
    do ( sleep 0.1
         numactl --cpunodebind=$(((NUMA_NODE+P)%LOGICAL_NUMA_PER_SOCKET+BASE_NUMA)) \
             numactl --physcpubind=+$((P/LOGICAL_NUMA_PER_SOCKET)) \
             iperf3 -s -B "${BIND_IP}" -p $((BASE_TCP_PORT+P)) --one-off &
        )
    done
