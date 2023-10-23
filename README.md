# Performance Tests for Multinode NGC.Ready Certification

## Prerequisites

* numactl
* jq
* iperf3 version >= 3.5
* sysstat
* nvidia-utils (if running RDMA test with CUDA)

## Access requirements

In order to run this, you will need passwordless root access to all the
involved servers and DPUs. This can be achieved in several ways:

Firstly, generate a passwordless SSH key (_e.g._ using `ssh-keygen`) and copy it to all the entities involved (_e.g._ using `ssh-copy-id`).

* If running as root: no further action is required.
* If running as a non-root user:
    * Make sure that your non-root user name is the same on the server, the client, and both the DPUs.
    * Make sure that your non-root user is able to use `sudo` (is in administrative group, such as `sudo` or `wheel`, or is mentioned directly in the sudoers file).
    * Make sure that your non-root user is able to use `sudo` either without a password at all (for example, this configuration in the sudoers file will do, assuming your user is a member of a group named `sudo`: `%sudo ALL=(ALL:ALL) NOPASSWD: ALL`) or, for a more granular approach, the following line can be used, allowing the non-root user to run only the needed binaries without a password:
        ```
        %sudo ALL=(ALL) ALL, NOPASSWD: /usr/bin/bash,/usr/sbin/ip,/opt/mellanox/iproute2/sbin/ip,/usr/bin/mlxprivhost,/usr/bin/mst,/usr/bin/systemctl,/usr/sbin/ethtool,/usr/sbin/set_irq_affinity_cpulist.sh,/usr/bin/tee,/usr/bin/awk,/usr/bin/taskset,/usr/bin/rm -f /tmp/*
        ```

## RDMA test

Will automatically detect device local NUMA node and run write/read/send
bidirectional tests. Pass criterion is 90% of the port link speed.

### Usage:

```
./ngc_rdma_test.sh <client hostname/ip> <client ib device>[,<client ib device2>] \
    <server hostname/ip> <server ib device>[,<server ib device2>] [--use_cuda] \
    [--qp=<num of QPs, default: 4>] [--all_connection_types]
```

## TCP test

Will automatically detect device local NUMA node, disabled IRQ balancer,
increase MTU to max and run `iperf3` on the closest NUMA nodes. Report
aggregated throughput is in Gb/s.

### Usage:

```
./ngc_tcp_test.sh <client hostname/ip> <client ib device> <server hostname/ip> \
    <server ib device> [--duplex=<"HALF" (default) or "FULL">] \
    [--change_mtu=<"CHANGE" (default) or "DONT_CHANGE">] \
    [--duration=<in seconds, default: 120>]
```

## IPsec full offload test

* This test currently supports single port only.

Will configure IPsec full offload on both client and server DPU, and then run a TCP test.

### Usage:

```
./ngc_ipsec_full_offload_tcp_test.sh <client hostname/ip> <client ib device> \
    <server hostname/ip> <server ib device> <client bluefield hostname/ip> \
    <server bluefield hostname/ip> [--mtu=<mtu size>] \
    [--duration=<in seconds, default: 120>]
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
