#!/bin/bash
# NGC Certification TCP test v2.3
# Owner: amira@nvidia.com
#

if (($# < 4)); then
    echo "usage: $0 <client trusted ip> <client ib device> <server trusted ip> <server ib device> [duplex] [change_mtu]"
    echo "		   duplex - options: HALF,FULL, default: HALF"
    echo "		   change_mtu - options: CHANGE,DONT_CHANGE, default: CHANGE"
    exit 1
fi
scriptdir="$(dirname "$0")"
source "${scriptdir}/common.sh"

CLIENT_TRUSTED=$1
CLIENT_DEVICE=$2
SERVER_TRUSTED=$3
SERVER_DEVICE=$4
DUPLEX=$5
CHANGE_MTU=$6

prep_for_tune_and_iperf_test

#set -x

[ -n "${DUPLEX}" ]     || DUPLEX="HALF"
[ -n "${CHANGE_MTU}" ] || CHANGE_MTU="CHANGE"

LOG_CLIENT="ngc_tcp_client_${CLIENT_TRUSTED}.log"
LOG_SERVER="ngc_tcp_server_${SERVER_TRUSTED}.log"
CLIENT_CORE_USAGES_FILE="/tmp/ngc_client_core_usages.log"
SERVER_CORE_USAGES_FILE="/tmp/ngc_server_core_usages.log"
CLIENT_ALL_CORE_USAGES_FILE="/tmp/ngc_all_client_core_usages.log"
SERVER_ALL_CORE_USAGES_FILE="/tmp/ngc_all_server_core_usages.log"

# uncomment if needed: Run iperf2 for reference before any change
# run_iperf2

# Stop IRQ balancer service
ssh "${CLIENT_TRUSTED}" systemctl stop irqbalance
ssh "${SERVER_TRUSTED}" systemctl stop irqbalance

LINK_TYPE="$(ssh "${CLIENT_TRUSTED}" "cat /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/type")"
# Increase MTU to maximum per link type
[ "${CHANGE_MTU}" != "CHANGE" ] || change_mtu

# Change number of channels to number of CPUs in the socket
CLIENT_PRESET_MAX=$(ssh "${CLIENT_TRUSTED}" ethtool -l "${CLIENT_NETDEV}" | awk '/Combined/{print $2}' | head -1)
SERVER_PRESET_MAX=$(ssh "${SERVER_TRUSTED}" ethtool -l "${SERVER_NETDEV}" | awk '/Combined/{print $2}' | head -1)
for N in $(seq "${CLIENT_BASE_NUMA}" $((CLIENT_BASE_NUMA+CLIENT_LOGICAL_NUMA_PER_SOCKET-1)))
do
    CLIENT_CPUCOUNT=$((CLIENT_CPUCOUNT+$(ssh "${CLIENT_TRUSTED}" "ls -1 /sys/devices/system/node/node${N}/" | grep -c 'cpu[0-9]\+')))
done
for N in $(seq "${SERVER_BASE_NUMA}" $((SERVER_BASE_NUMA+SERVER_LOGICAL_NUMA_PER_SOCKET-1)))
do
    SERVER_CPUCOUNT=$((SERVER_CPUCOUNT+$(ssh "${SERVER_TRUSTED}" "ls -1 /sys/devices/system/node/node${N}/" | grep -c 'cpu[0-9]\+')))
done
ssh "${CLIENT_TRUSTED}" ethtool -L "${CLIENT_NETDEV}" combined "$((CLIENT_CPUCOUNT<CLIENT_PRESET_MAX ? CLIENT_CPUCOUNT : CLIENT_PRESET_MAX))"
ssh "${SERVER_TRUSTED}" ethtool -L "${SERVER_NETDEV}" combined "$((SERVER_CPUCOUNT<SERVER_PRESET_MAX ? SERVER_CPUCOUNT : SERVER_PRESET_MAX))"

# Enable aRFS for ethernet links
if [ ${LINK_TYPE} -eq 1 ]; then
    ssh "${CLIENT_TRUSTED}" "ethtool -K ${CLIENT_NETDEV} ntuple on"
    ssh "${CLIENT_TRUSTED}" "echo 32768 > /proc/sys/net/core/rps_sock_flow_entries"
    ssh "${CLIENT_TRUSTED}" "for f in /sys/class/net/${CLIENT_NETDEV}/queues/rx-*/rps_flow_cnt; do echo '32768' > \${f}; done"

    ssh "${SERVER_TRUSTED}" "ethtool -K ${SERVER_NETDEV} ntuple on"
    ssh "${SERVER_TRUSTED}" "echo 32768 > /proc/sys/net/core/rps_sock_flow_entries"
    ssh "${SERVER_TRUSTED}" "for f in /sys/class/net/${SERVER_NETDEV}/queues/rx-*/rps_flow_cnt; do echo '32768' > \${f}; done"
fi

# Set IRQ affinity to local socket CPUs
NUMA_TOPO=("numactl" "-H")
CLIENT_NUMA_TOPO=$(ssh "${CLIENT_TRUSTED}" "${NUMA_TOPO[*]}")
SERVER_NUMA_TOPO=$(ssh "${SERVER_TRUSTED}" "${NUMA_TOPO[*]}")
THREAD_PER_CORE=("lscpu" "|" "awk" "'/Thread/{print \$NF}'")
CLIENT_THREAD_PER_CORE=$(ssh "${CLIENT_TRUSTED}" "${THREAD_PER_CORE[*]}")
SERVER_THREAD_PER_CORE=$(ssh "${SERVER_TRUSTED}" "${THREAD_PER_CORE[*]}")
CLIENT_PHYSICAL_CORE_COUNT=$((CLIENT_CPUCOUNT/CLIENT_LOGICAL_NUMA_PER_SOCKET/CLIENT_THREAD_PER_CORE))
SERVER_PHYSICAL_CORE_COUNT=$((SERVER_CPUCOUNT/SERVER_LOGICAL_NUMA_PER_SOCKET/SERVER_THREAD_PER_CORE))
CLIENT_PHYSICAL_CORES=()
CLIENT_LOGICAL_CORES=()
SERVER_PHYSICAL_CORES=()
SERVER_LOGICAL_CORES=()
for node in $(seq "${CLIENT_FIRST_SIBLING_NUMA}" $((CLIENT_FIRST_SIBLING_NUMA+CLIENT_LOGICAL_NUMA_PER_SOCKET-1)))
do
    numa_cores=($(echo "${CLIENT_NUMA_TOPO}" | grep "node ${node} cpus" | cut -d":" -f2))
    CLIENT_PHYSICAL_CORES=(${CLIENT_PHYSICAL_CORES[@]} ${numa_cores[@]:0:CLIENT_PHYSICAL_CORE_COUNT})
    CLIENT_LOGICAL_CORES=(${CLIENT_LOGICAL_CORES[@]} ${numa_cores[@]:CLIENT_PHYSICAL_CORE_COUNT})
done
for node in $(seq "${SERVER_FIRST_SIBLING_NUMA}" $((SERVER_FIRST_SIBLING_NUMA+SERVER_LOGICAL_NUMA_PER_SOCKET-1)))
do
    numa_cores=($(echo "${SERVER_NUMA_TOPO}" | grep "node ${node} cpus" | cut -d":" -f2))
    SERVER_PHYSICAL_CORES=(${SERVER_PHYSICAL_CORES[@]} ${numa_cores[@]:0:SERVER_PHYSICAL_CORE_COUNT})
    SERVER_LOGICAL_CORES=(${SERVER_LOGICAL_CORES[@]} ${numa_cores[@]:SERVER_PHYSICAL_CORE_COUNT})
done
CLIENTS_AFFINITY_CORES=(${CLIENT_PHYSICAL_CORES[@]} ${CLIENT_LOGICAL_CORES[@]})
SERVER_AFFINITY_CORES=(${SERVER_PHYSICAL_CORES[@]} ${SERVER_LOGICAL_CORES[@]})
CLIENT_AFFINITY_IRQ_COUNT=$((CLIENT_CPUCOUNT<CLIENT_PRESET_MAX ? CLIENT_CPUCOUNT : CLIENT_PRESET_MAX))
SERVER_AFFINITY_IRQ_COUNT=$((SERVER_CPUCOUNT<SERVER_PRESET_MAX ? SERVER_CPUCOUNT : SERVER_PRESET_MAX))

ssh "${CLIENT_TRUSTED}" set_irq_affinity_cpulist.sh "$(tr " " "," <<< "${CLIENTS_AFFINITY_CORES[@]::CLIENT_AFFINITY_IRQ_COUNT}")" "${CLIENT_NETDEV}"
ssh "${SERVER_TRUSTED}" set_irq_affinity_cpulist.sh "$(tr " " "," <<< "${SERVER_AFFINITY_CORES[@]::SERVER_AFFINITY_IRQ_COUNT}")" "${SERVER_NETDEV}"

# Toggle interfaces down/up so channels allocation will be according to actual IRQ affinity
ssh "${SERVER_TRUSTED}" "ip l set ${SERVER_NETDEV} down; ip l set  ${SERVER_NETDEV} up"
sleep 2
ssh "${CLIENT_TRUSTED}" "ip l set ${CLIENT_NETDEV} down; ip l set  ${CLIENT_NETDEV} up"
sleep 2

run_iperf3

# uncomment if needed: Run iperf2 for reference after settings
# run_iperf2

#set +x
