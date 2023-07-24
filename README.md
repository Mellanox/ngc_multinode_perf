# Performance Tests for Multinode NGC.Ready Certification

## Prerequisites:

* Passwordless root access to the participating nodes
* numactl
* iperf3 version >= 3.5
* sysstat

## RDMA test

Will automatically detect device local NUMA node and run write/read/send
bidirectional tests. Pass criterion is 90% of the port link speed.

### Usage:

```
./ngc_rdma_test.sh <client hostname/ip> <client ib device> \
    <server hostname/ip> <server ib device>
```

## TCP test

Will automatically detect device local NUMA node, disabled IRQ balancer,
increase MTU to max and run `iperf3` on the closest NUMA nodes. Report
aggregated throughput is in Gb/s.

### Usage:

```
./ngc_tcp_test.sh <client hostname/ip> <client ib device> <server hostname/ip> \
    <server ib device> <duplex (options: HALF (default), FULL)> \
    <change_mtu (options: CHANGE (default), DONT_CHANGE)>
```

## IPsec full offload test

* Relevant for BlueField-2 DPUs.
* This test supports single port only.

Will configure IPsec full offload on both client and server BlueField-2, and then run TCP test.

### Usage:

```
./ngc_ipsec_full_offload_tcp_test.sh <client hostname/ip> <client ib device> \
    <server hostname/ip> <server ib device> <client bluefield hostname/ip> \
    <server bluefield hostname/ip> [optional: mtu size]
```

## IPsec crypto offload test

* Relevant for connectX-6 DX only.

Will configure IPsec crypto offload on both client and server, run TCP test,
and remove IPsec configuration.

### Usage:

```
./ngc_ipsec_crypto_offload_tcp_test.sh <client hostname/ip> <client ib device> \
    <server hostname/ip> <server ib device> <number of tunnels>
```

* The number of tunnels should not exceed the number of IPs configured on the NICs.
