# ngc_multinode_perf
Performance tests for multinode NGC.Ready certification

RDMA test:
* Will automatically detect device local NUMA node and run write/read/send bidirectional tests
* Pass creteria is 90% of port link speed

usage: ./ngc_rdma_test.sh [client hostname] [client ib device] [server hostname] [server ib device]
  
TCP test:
* Will automatically detect device local NUMA node, disabled IRQ balancer, increase MTU to max and run iperf3 on the closest NUMA nodes 
* Report aggregated throughput in Gb/s

usage: ./ngc_tcp_test.sh [client trusted ip] [client ib device] [server trusted ip] [server ib device] [duplex, options: HALF,FULL, default: HALF] [change_mtu, options: CHANGE,DONT_CHANGE, default: CHANGE>]  
Prerequisites:
* numactl
* bc
* iperf3 version >= 3.5



  
  
