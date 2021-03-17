# ngc_multinode_perf
Performance tests for multinode NGC.Ready certification

RDMA test:
* Will automatically detect device local NUMA node and run write/read/send bidirectional tests
* Pass creteria is 90% of port link speed
* Optional: setting IPsec full offload, needs to give client and server BlueField names/IP.
	note: if IPsec offload is needed, please do not set MTU size to within 500 of maximum MTU.

usage: ./ngc_rdma_test.sh [client hostname] [client ib device] [server hostname] [server ib device] [client BlueField] [server BlueField]
  
TCP test:
* Will automatically detect device local NUMA node, disabled IRQ balancer, increase MTU to max (if not specifically requested) and run iperf3 on the closest NUMA nodes 
* Report aggregated throughput in Gb/s
* Optional: setting IPsec full offload, needs to give client and server BlueField names/IP.

usage: ./ngc_tcp_test.sh [client ip] [client ib device] [server ip] [server ib device] [client BlueField] [server BlueField]
  
Prerequisites:
* numactl
* bc
* iperf3 version >= 3.5



  
  
