Performance tests for multinode NGC.Ready certification

RDMA test:

Will automatically detect device local NUMA node and run write/read/send bidirectional tests
Pass creteria is 90% of port link speed

Usage: ./ngc_rdma_test.sh [client hostname] [client ib device] [server hostname] [server ib device]

TCP test:

Will automatically detect device local NUMA node, disabled IRQ balancer, increase MTU to max and run iperf3 on the closest NUMA nodes
Report aggregated throughput in Gb/s

Usage: ./ngc_tcp_test.sh [client trusted ip] [client ib device] [server trusted ip] [server ib device] [duplex, options: HALF,FULL, default: HALF] [change_mtu, options: CHANGE,DONT_CHANGE, default: CHANGE>]

IPsec full offload test:

Relevant for BlueField-2 DPUs
Test supports single port (port 0) only.
Will configure IPsec full offload on both client and server BlueField-2 and then run TCP test

Usage: ./ngc_ipsec_full_offload_tcp_test.sh [client ip] [client ib device] [server ip] [server ib device] [client bluefield hostname/ip] [server bluefield hostname/ip] [optional: mtu size]

Prerequisites:
* Passwordless root access to the participating nodes
* numactl
* bc
* iperf3 version >= 3.5
