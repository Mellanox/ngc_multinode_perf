# Performance Tests for Multinode NGC.Ready Certification

## Prerequisites

* numactl
* jq
* iperf3 version >= 3.5
* sysstat
* perftest version >= 4.5-0.11 (if running RDMA tests)
* nvidia-utils (if running RDMA test with CUDA)
* mlnx-tools (or at least the `common_irq_affinity.sh` and `set_irq_affinity_cpulist.sh` scripts from it). This package is available [here](https://github.com/Mellanox/mlnx-tools), and is also installed as a part of OFED.

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
        %sudo ALL=(ALL) ALL, NOPASSWD: /usr/bin/bash,/usr/sbin/ip,/opt/mellanox/iproute2/sbin/ip,/usr/bin/mlxprivhost,/usr/bin/mst,/usr/bin/systemctl,/usr/sbin/ethtool,/usr/sbin/set_irq_affinity_cpulist.sh,/usr/bin/tee,/usr/bin/numactl,/usr/bin/awk,/usr/bin/taskset,/usr/bin/setpci,/usr/bin/rm -f /tmp/*
        ```

## RDMA test

Will automatically detect device local NUMA node and run write/read/send
bidirectional tests. Pass criterion is 90% of the port link speed.

### Usage:

```
./ngc_rdma_test.sh \
    [<client username>@]<client hostname/ip> <client ib device>[,<client ib device2>,...] \
    [<server username>@]<server hostname/ip> <server ib device>[,<server ib device2>,...] \
    [--use_cuda] \
    [--qp=<num of QPs, default: total 4>] \
    [--all_connection_types | --conn=<list of connection types>] \
    [--tests=<list of ib perftests>] \
    [--duration=<time in seconds, default: 30 per test>]\
    [--bw_message_size_list=<list of message sizes>] \
    [--lat_message_size_list=<list of message sizes>] \
    [--server_cuda=<cuda_device>] \
    [--client_cuda=<cuda_device>] \
    [--unidir] \
    [--sd] \
    [--ipsec <list of DPU clients> <list of PFs associated to list of DPU clients> \
    <list of DPU servers> <list of PFs associated to list of DPU servers>]
```

* If running with CUDA:
    * The nvidia-peermem driver should be loaded.
    * Perftest should be built with CUDA support.


## RDMA Wrapper

Automatically detect HCAs on the host(s) and run ngc_rdma_test.sh for
each device.

### Usage:

```
./ngc_rdma_wrapper.sh [<client username>@]<client hostname/ip> [<server username>@]<server hostname/ip> \
    [--with_cuda, default: without cuda] \
    [--cuda_only] \
    [--write] \
    [--read] \
    [--vm] \
    [--aff <file>] \
    [--pairs <file>]

./ngc_internal_lb_rdma_wrapper.sh <hostname/ip> \
    [--with_cuda, default: without cuda] \
    [--cuda_only] \
    [--write] \ 
    [--read] \
    [--vm] \
    [--aff <file>]
```


## TCP test

Will automatically detect device local NUMA node, disable IRQ balancer,
increase MTU to max and run `iperf3` on the closest NUMA nodes. Report
aggregated throughput is in Gb/s.

### Usage:

```
./ngc_tcp_test.sh \
    [<client username>@]<client hostname/ip> <client ib device1>[,<client ib device2>,...] \
    [<server username>@]<server hostname/ip> <server ib device1>[,<server ib device2>,...] \
    [--duplex=<"HALF" (default) or "FULL">] \
    [--change_mtu=<"CHANGE" (default) or "DONT_CHANGE">] \
    [--duration=<in seconds, default: 120>]
    [--ipsec <list of DPU clients> <list of PFs associated to list of DPU clients> \
    <list of DPU servers> <list of PFs associated to list of DPU servers>]
```

## IPsec full offload test

* This test currently supports single port only.

Will configure IPsec full offload on both client and server DPU, and then run a TCP test.

### Usage:

```
./ngc_ipsec_full_offload_tcp_test.sh [<client username>@]<client hostname/ip> <client ib device> \
    [<server username>@]<server hostname/ip> <server ib device> <client bluefield hostname/ip> \
    <server bluefield hostname/ip> [--mtu=<mtu size>] \
    [--duration=<in seconds, default: 120>]
```

## IPsec crypto offload test

* Relevant for new HCAs (ConnectX-6 DX and above).

Will configure IPsec crypto offload on both client and server, run TCP test,
and remove IPsec configuration.

### Usage:

```
./ngc_ipsec_crypto_offload_tcp_test.sh [<client username>@]<client hostname/ip> <client ib device> \
    [<server username>@]<server hostname/ip> <server ib device> <number of tunnels>
```

* The number of tunnels should not exceed the number of IPs configured on the NICs.

## Download the latest stable version

Besides cloning and checking out to the latest stable release, you can also use
the following helper script:

```bash
curl -Lfs https://raw.githubusercontent.com/Mellanox/ngc_multinode_perf/main/helpers/dl_nmp.sh | bash
```

And to download the latest 'experimental' (rc) version:

```bash
curl -Lfs https://raw.githubusercontent.com/Mellanox/ngc_multinode_perf/main/helpers/dl_nmp.sh | bash -s -- rc
```

## Tuning instructions and HW/FW requirements

| Item                                    | Description                    |
|-----------------------------------------|--------------------------------|
| HCA Firmware version                    | Latest_GA                      |
| MLNX_OFED Version                       | Latest_GA                      |
| Eth Switch ports                        | Set MTU to 9216<br>Enable PFC and ECN using the single "Do ROCE" command |
| IB Switch OpenSM                        | Change IPoIB MTU to 4K:<br>[standalone: master] → en<br>[standalone: master] # conf t<br>[standalone: master] (config) # ib partition Default mtu 4K force |
| **AMD CPUs: EPYC 7002 and 7003 series** |                                |
| BIOS Settings                           | CPU Power Management → Maximum Performance<br>Memory Frequency → Maximum Performance<br>Alg. Performance Boost Disable (ApbDis) → Enabled<br>ApbDis Fixed Socket P-State → P0<br>NUMA Nodes Per Socket → 2<br>L3 cache as NUMA Domain → Enabled<br>x2APIC Mode → Enabled<br>PCIe ACS → Disabled<br>Preferred IO → Disabled<br>Enhanced Preferred IO → Enabled |
| Boot grub settings                      | `iommu=pt numa_balancing=disable processor.max_cstate=0` |
| **Intel CPUs: Xeon Gold and Platinum**  |                                |
| BIOS Settings                           | Out of the box                 |
| Boot grub settings                      | `intel_idle.max_cstate=0 processor.max_cstate=0 intel_pstate=disable` |
| NIC PCIe settings                       | For each NIC PCIe function:<br>Change PCI MaxReadReq to 4096B<br>Run `setpci -s $PCI_FUNCTION 68.w`, it will return 4 digits ABCD<br>→ Run `setpci -s $PCI_FUNCTION 68.w=5BCD` |
