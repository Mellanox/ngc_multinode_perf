# ngc_multinode_perf
Performance tests for multinode NGC.Ready certification

RDMA test:
* Will automatically detect device local NUMA node and run write/read/send bidirectional tests
* Pass creteria is 90% of port link speed

usage: ./ngc_rdma_test.sh [client hostname] [client ib device] [server hostname] [server ib device]
  
TCP test:
* Will automatically detect device local NUMA node, disabled IRQ balancer, increase MTU to max (if not specifically requested) and run iperf3 on the closest NUMA nodes 
* Report aggregated throughput in Gb/s

usage: ./ngc_tcp_test.sh [client ip] [client ib device] [server ip] [server ib device] [MTU size]
  
IPsec full offload tests:
* Will setup IPsec full offload on BF2 hosts
* Run RDMA and TCP test according to input (rdma/tcp/both, on TCP test will set MTU to 1500 instead of maximum.

usage: ./ngc_ipsec_test.sh [[client BF] [server BF] [tests to run] [client ip] [client ib device] [server ip] [server ib device]
Prerequisites:
* numactl
* bc
* iperf3 version >= 3.5



  
  
