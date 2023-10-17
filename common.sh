#!/bin/bash
# NGC Certification common functions v0.1
# Owner: dorko@nvidia.com
#

scriptdir="$(dirname "$0")"

log() {
    >&2 printf "%s\n" "${*}"
}

fatal() {
    log "ERROR: ${*}"
    exit 1
}

check_connection() {
    ssh "${CLIENT_TRUSTED}" ping "${SERVER_IP}" -c 5 ||
        fatal "No ping from client to server, test aborted"
}

check_if_number(){
    local re num
    num=$1
    re='^[0-9]+$'
    [[ $num =~ $re ]] || return 1
}

change_mtu() {
    if [ "${LINK_TYPE}" -eq 1 ]; then
        MTU=9000
    elif [ "${LINK_TYPE}" -eq 32 ]; then
        MTU=4092
    fi
    # TODO: Support multiple client/server devices (when TCP test will support them)
    ssh "${CLIENT_TRUSTED}" "sudo bash -c 'echo ${MTU} > /sys/class/infiniband/${CLIENT_DEVICE}/device/net/${CLIENT_NETDEV}/mtu'"
    ssh "${SERVER_TRUSTED}" "sudo bash -c 'echo ${MTU} > /sys/class/infiniband/${SERVER_DEVICE}/device/net/${SERVER_NETDEV}/mtu'"
    CURR_MTU="$(ssh "${CLIENT_TRUSTED}" "cat /sys/class/infiniband/${CLIENT_DEVICE}/device/net/${CLIENT_NETDEV}/mtu")"
    ((CURR_MTU == MTU)) || log 'Warning, MTU was not configured correctly on Client'
    CURR_MTU="$(ssh "${SERVER_TRUSTED}" "cat /sys/class/infiniband/${SERVER_DEVICE}/device/net/${SERVER_NETDEV}/mtu")"
    ((CURR_MTU == MTU)) || log 'Warning, MTU was not configured correctly on Server'
}

run_iperf2() {
    ssh "${SERVER_TRUSTED}" pkill iperf
    ssh "${SERVER_TRUSTED}" iperf -s &
    sleep 5
    ssh "${CLIENT_TRUSTED}" iperf -c "${SERVER_IP}" -P "${MAX_PROC}" -t 30
    ssh "${SERVER_TRUSTED}" pkill iperf
}

get_average() {
    awk "BEGIN {printf \"%.2f\n\", ($(IFS=+; printf '%s' "${*}"))/$#}"
}

get_port_rate() {
    local host device
    host="${1}"
    device="${2}"

    ssh "${host}" "cat /sys/class/infiniband/${device}/ports/1/rate" | cut -d' ' -f1
}

get_min() {
    local distances min_idx min_val
    distances=($@)
    min_idx=0
    min_val=$1
    for i in "${!distances[@]}"; do
        if (( ${distances[$i]} < min_val )); then
            min_idx=$i
            min_val=${distances[$i]}
        fi
    done
    echo "${min_idx}"
}

get_min_val() {
    local distances
    distances=($@)
    echo "${distances[$(get_min ${distances[@]})]}"
}

get_n_min_distances() {
    local n distances mins flag_min_is_first
    n=$1
    distances=(${@:2})
    mins=()
    flag_min_is_first=0
    for i in $(seq 0 $((n-1))); do
        MIN_IDX=$(get_min ${distances[@]})
        TMP_MIN_IDX=MIN_IDX
        if (( flag_min_is_first == 1 )); then
            MIN_IDX=$((MIN_IDX+1))
        fi
        if (( TMP_MIN_IDX == 0 )); then
            flag_min_is_first=1
        else
            flag_min_is_first=0
        fi
        mins=(${mins[@]} ${MIN_IDX})
        unset distances[$MIN_IDX]
        distances=(${distances[@]})
    done
    echo "${mins[@]}"
}

get_server_client_ips_and_ifs() {
    local cdev sdev i

    (( $(awk -F',' '{print NF}' <<<"${CLIENT_DEVICE}") == $(awk -F',' '{print NF}' <<<"${SERVER_DEVICE}") )) ||
        fatal "The number of client and server devices must be equal."

    case "${CLIENT_DEVICE}" in
        *","*)
            client_devices=(${CLIENT_DEVICE//,/ })
            CLIENT_NETDEV=()
            CLIENT_IP=()
            for cdev in "${client_devices[@]}"
            do
                CLIENT_NETDEV+=("$(ssh "${CLIENT_TRUSTED}" "ls -1 /sys/class/infiniband/${cdev}/device/net | head -1")")
                [ -n "${CLIENT_NETDEV[${#CLIENT_NETDEV[@]}-1]}" ] ||
                    fatal "Can't find a client net device associated with the IB device '${cdev}'."
                CLIENT_IP+=("$(ssh "${CLIENT_TRUSTED}" "ip a sh ${CLIENT_NETDEV[${#CLIENT_NETDEV[@]}-1]}" | grep -ioP '(?<=inet )\d+\.\d+\.\d+\.\d+' | xargs | tr ' ' ',')")
                [ -z "${CLIENT_IP[${#CLIENT_IP[@]}-1]}" ] &&
                    fatal "Can't find a client IP associated with the net device '${CLIENT_NETDEV[${#CLIENT_NETDEV[@]}-1]}'." ||
                    log "INFO: Found $(awk -F',' '{print NF}' <<<"${CLIENT_IP[${#CLIENT_IP[@]}-1]}") IPs associated with the client net device '${CLIENT_NETDEV[${#CLIENT_NETDEV[@]}-1]}'."
            done
            ;;
        *)
            CLIENT_NETDEV="$(ssh "${CLIENT_TRUSTED}" "ls -1 /sys/class/infiniband/${CLIENT_DEVICE}/device/net | head -1")"
            [ -n "${CLIENT_NETDEV}" ] ||
                fatal "Can't find client net device. Did you mean to specify IB device as '${CLIENT_DEVICE}'?"

            readarray -t CLIENT_IP < <(ssh "${CLIENT_TRUSTED}" "ip a sh ${CLIENT_NETDEV}" | grep -ioP '(?<=inet )\d+\.\d+\.\d+\.\d+')
            ((${#CLIENT_IP[@]} != 0)) || fatal "Can't find client IP, did you set IPv4 address in client?"
            ;;
    esac

    case "${SERVER_DEVICE}" in
        *","*)
            server_devices=(${SERVER_DEVICE//,/ })
            SERVER_NETDEV=()
            SERVER_IP=()
            for sdev in "${server_devices[@]}"
            do
                SERVER_NETDEV+=("$(ssh "${SERVER_TRUSTED}" "ls -1 /sys/class/infiniband/${sdev}/device/net | head -1")")
                [ -n "${SERVER_NETDEV[${#SERVER_NETDEV[@]}-1]}" ] ||
                    fatal "Can't find a server net device associated with the IB device '${sdev}'."
                SERVER_IP+=("$(ssh "${SERVER_TRUSTED}" "ip a sh ${SERVER_NETDEV[${#SERVER_NETDEV[@]}-1]}" | grep -ioP '(?<=inet )\d+\.\d+\.\d+\.\d+' | xargs | tr ' ' ',')")
                [ -z "${SERVER_IP[${#SERVER_IP[@]}-1]}" ] &&
                    fatal "Can't find a server IP associated with the net device '${SERVER_NETDEV[${#SERVER_NETDEV[@]}-1]}'." ||
                    log "INFO: Found $(awk -F',' '{print NF}' <<<"${SERVER_IP[${#SERVER_IP[@]}-1]}") IPs associated with the server net device '${SERVER_NETDEV[${#SERVER_NETDEV[@]}-1]}'."
            done
            ;;
        *)
            SERVER_NETDEV="$(ssh "${SERVER_TRUSTED}" "ls -1 /sys/class/infiniband/${SERVER_DEVICE}/device/net | head -1")"
            [ -n "${SERVER_NETDEV}" ] ||
                fatal "Can't find server net device. Did you mean to specify IB device as '${SERVER_DEVICE}'?"

            readarray -t SERVER_IP < <(ssh "${SERVER_TRUSTED}" "ip a sh ${SERVER_NETDEV}" | grep -ioP '(?<=inet )\d+\.\d+\.\d+\.\d+')
            ((${#SERVER_IP[@]} != 0)) || fatal "Can't find server IP, did you set IPv4 address in server?"
            ;;
    esac

    for i in "${!CLIENT_NETDEV[@]}"
    do
        (( $(awk -F',' '{print NF}' <<<"${CLIENT_IP[$i]}") == $(awk -F',' '{print NF}' <<<"${SERVER_IP[$i]}") )) ||
            fatal "The number of IPs on client interface ${CLIENT_NETDEV[$i]} does not match this on server interface ${SERVER_NETDEV[$i]}."
    done
}

prep_for_tune_and_iperf_test() {

    ssh "${CLIENT_TRUSTED}" pkill iperf3
    ssh "${SERVER_TRUSTED}" pkill iperf3

    CLIENT_NUMA_NODE="$(ssh "${CLIENT_TRUSTED}" "cat /sys/class/infiniband/${CLIENT_DEVICE}/device/numa_node")"
    ((CLIENT_NUMA_NODE != -1)) || CLIENT_NUMA_NODE="0"
    SERVER_NUMA_NODE="$(ssh "${SERVER_TRUSTED}" "cat /sys/class/infiniband/${SERVER_DEVICE}/device/numa_node")"
    ((SERVER_NUMA_NODE != -1)) || SERVER_NUMA_NODE="0"

    get_server_client_ips_and_ifs

    ssh "${CLIENT_TRUSTED}" iperf3 -v
    ssh "${SERVER_TRUSTED}" iperf3 -v
    ssh "${CLIENT_TRUSTED}" cat /proc/cmdline
    ssh "${SERVER_TRUSTED}" cat /proc/cmdline
    #ssh "${CLIENT_TRUSTED}" iperf -v
    #ssh "${SERVER_TRUSTED}" iperf -v

    MAX_PROC=16
    THREADS=1
    TIME="${TEST_DURATION}"
    TCP_PORT_ID="$(echo "${CLIENT_DEVICE}" | cut -d '_' -f 2)"
    TCP_PORT_ADDITION=$((TCP_PORT_ID * 100))
    BASE_TCP_PORT=$((5200 + TCP_PORT_ADDITION))
    NUMACTL_HW=("numactl" "--hardware" "|" "grep" "-v" "node")
    NUM_SOCKETS_CMD=("lscpu" "|" "grep" "'Socket'" "|" "cut" "-d':'" "-f2")
    NUM_NUMAS_CMD=("lscpu" "|" "grep" "'NUMA node(s)'" "|" "cut" "-d':'" "-f2")

    # Get Client NUMA topology
    CLIENT_NUMA_DISTS=( $(ssh "${CLIENT_TRUSTED}" "${NUMACTL_HW[*]} | sed -n 's/${CLIENT_NUMA_NODE}://p'") )
    CLIENT_NUM_SOCKETS=$(ssh "${CLIENT_TRUSTED}" "${NUM_SOCKETS_CMD[*]}")
    CLIENT_NUM_NUMAS=$(ssh "${CLIENT_TRUSTED}" "${NUM_NUMAS_CMD[*]}")
    CLIENT_LOGICAL_NUMA_PER_SOCKET=$(( (CLIENT_NUM_NUMAS + CLIENT_NUM_SOCKETS - 1) / CLIENT_NUM_SOCKETS ))
    CLIENT_FIRST_SIBLING_NUMA=( $(get_n_min_distances "${CLIENT_LOGICAL_NUMA_PER_SOCKET}" ${CLIENT_NUMA_DISTS[@]}) )
    MIN_IDX=$(get_min ${CLIENT_FIRST_SIBLING_NUMA[@]})
    CLIENT_BASE_NUMA=${CLIENT_FIRST_SIBLING_NUMA[$MIN_IDX]}

    log "MIN_IDX $MIN_IDX, CLIENT_FIRST_SIBLING_NUMA ${CLIENT_FIRST_SIBLING_NUMA[*]} CLIENT_BASE_NUMA ${CLIENT_BASE_NUMA} CLIENT_NUMA_DISTS ${CLIENT_NUMA_DISTS[*]} CLIENT_NUMA_NODE ${CLIENT_NUMA_NODE}"

    # Get Server NUMA topology
    SERVER_NUMA_DISTS=( $(ssh "${SERVER_TRUSTED}" "${NUMACTL_HW[*]} | sed -n 's/${SERVER_NUMA_NODE}://p'") )
    SERVER_NUM_SOCKETS=$(ssh "${SERVER_TRUSTED}" "${NUM_SOCKETS_CMD[*]}")
    SERVER_NUM_NUMAS=$(ssh "${SERVER_TRUSTED}" "${NUM_NUMAS_CMD[*]}")
    SERVER_LOGICAL_NUMA_PER_SOCKET=$(( (SERVER_NUM_NUMAS + SERVER_NUM_SOCKETS - 1) / SERVER_NUM_SOCKETS ))
    SERVER_FIRST_SIBLING_NUMA=( $(get_n_min_distances "${SERVER_LOGICAL_NUMA_PER_SOCKET}" ${SERVER_NUMA_DISTS[@]}) )
    MIN_IDX=$(get_min ${SERVER_FIRST_SIBLING_NUMA[@]})
    SERVER_BASE_NUMA=${SERVER_FIRST_SIBLING_NUMA[$MIN_IDX]}

}

run_iperf3() {
    RESULT_FILE=/tmp/ngc_run_result.log

    PROC=$(printf "%s\n" "${CLIENT_AFFINITY_IRQ_COUNT}" "${SERVER_AFFINITY_IRQ_COUNT}" "${MAX_PROC}" | sort -h | head -n1)
    #check amount of IPs for interface asked, and run iperf3 mutli proccess each on another ip.
    IP_AMOUNT=$(printf "%s\n" ${#SERVER_IP[@]} ${#CLIENT_IP[@]} | sort -h | head -n1)

    log "-- starting iperf with ${PROC} processes ${THREADS} threads --"

    CLIENT_ACTIVE_CORES_LIST=()
    SERVER_ACTIVE_CORES_LIST=()
    for P in $(seq 0 $((PROC-1)))
    do
        index=$((P%CLIENT_LOGICAL_NUMA_PER_SOCKET*CLIENT_PHYSICAL_CORE_COUNT+P/CLIENT_LOGICAL_NUMA_PER_SOCKET))
        CLIENT_ACTIVE_CORES_LIST=(${CLIENT_ACTIVE_CORES_LIST[@]} ${CLIENT_PHYSICAL_CORES[$index]})
        index=$((P%SERVER_LOGICAL_NUMA_PER_SOCKET*SERVER_PHYSICAL_CORE_COUNT+P/SERVER_LOGICAL_NUMA_PER_SOCKET))
        SERVER_ACTIVE_CORES_LIST=(${SERVER_ACTIVE_CORES_LIST[@]} ${SERVER_PHYSICAL_CORES[$index]})

    done
    CLIENT_ACTIVE_CORES_LIST=(${CLIENT_ACTIVE_CORES_LIST[@]})
    SERVER_ACTIVE_CORES_LIST=(${SERVER_ACTIVE_CORES_LIST[@]})

    readarray -t sorted < <(for a in "${CLIENT_ACTIVE_CORES_LIST[@]}"; do echo "${a}"; done | sort -n)
    CLIENT_ACTIVE_CORES_LIST_STRING=$(printf ",%s" "${sorted[@]}")
    CLIENT_ACTIVE_CORES_LIST_STRING=${CLIENT_ACTIVE_CORES_LIST_STRING:1}
    sorted=()
    readarray -t sorted < <(for a in "${SERVER_ACTIVE_CORES_LIST[@]}"; do echo "${a}"; done | sort -n)
    SERVER_ACTIVE_CORES_LIST_STRING=$(printf ",%s" "${sorted[@]}")
    SERVER_ACTIVE_CORES_LIST_STRING=${SERVER_ACTIVE_CORES_LIST_STRING:1}

    ssh "${SERVER_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_servers.sh" \
        "${PROC}" "${SERVER_NUMA_NODE}" "${SERVER_LOGICAL_NUMA_PER_SOCKET}" \
        "${SERVER_BASE_NUMA}" "${BASE_TCP_PORT}" &
    if [ "${DUPLEX}" = "FULL" ]; then
        ssh "${CLIENT_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_servers.sh" \
            "${PROC}" "${CLIENT_NUMA_NODE}" "${CLIENT_LOGICAL_NUMA_PER_SOCKET}" \
            "${CLIENT_BASE_NUMA}" "${BASE_TCP_PORT}" &
    fi

    check_connection

    ssh "${CLIENT_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_clients.sh" \
        "${RESULT_FILE}" "${PROC}" "${CLIENT_NUMA_NODE}" "${CLIENT_LOGICAL_NUMA_PER_SOCKET}" \
        "${CLIENT_BASE_NUMA}" "${SERVER_IP[$((P%IP_AMOUNT))]}" \
        "${BASE_TCP_PORT}" "${THREADS}" "${TIME}" &
    if [ "${DUPLEX}" = "FULL" ]; then
        sleep 0.1
        ssh "${SERVER_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_clients.sh" \
            "${RESULT_FILE}" "${PROC}" "${SERVER_NUMA_NODE}" "${SERVER_LOGICAL_NUMA_PER_SOCKET}" \
            "${SERVER_BASE_NUMA}" "${CLIENT_IP[$((P%IP_AMOUNT))]}" \
            "${BASE_TCP_PORT}" "${THREADS}" "${TIME}" &
    fi

    DURATION=$((TIME - 1))
    ssh "${CLIENT_TRUSTED}" "sar -u -P ${CLIENT_ACTIVE_CORES_LIST_STRING},all ${DURATION} 1 | grep 'Average' | head -n $((PROC + 1)) > ${CLIENT_CORE_USAGES_FILE}$$" &
    ssh "${SERVER_TRUSTED}" "sar -u -P ${SERVER_ACTIVE_CORES_LIST_STRING},all ${DURATION} 1 | grep 'Average' | head -n $((PROC + 1)) > ${SERVER_CORE_USAGES_FILE}$$" &
    wait

    BITS=$(ssh "${CLIENT_TRUSTED}" "jq -s '[.[].end.sum_sent.bits_per_second] | add' <\"${RESULT_FILE}\"")

    log "${CLIENT_TRUSTED} Active cores: ${CLIENT_ACTIVE_CORES_LIST_STRING}"
    log "Active core usages on ${CLIENT_TRUSTED}"
    ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | sed 's/|/ /' | awk '{print $2 "\t" $5}' >&2
    USAGES=($(ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | tail -n +2 | sed 's/|/ /' | awk '{print $5}'))
    TOTAL_ACTIVE_AVERAGE=$(get_average ${USAGES[@]})
    >&2 printf "Overall Active: %s\tOverall All cores: %s\n" "${TOTAL_ACTIVE_AVERAGE}" \
        "$(ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | grep all | sed 's/|/ /' | awk '{print $5}')"

    log "${SERVER_TRUSTED} Active cores: ${SERVER_ACTIVE_CORES_LIST_STRING}"
    log "Active core usages on ${SERVER_TRUSTED}"
    ssh "${SERVER_TRUSTED}" "cat ${SERVER_CORE_USAGES_FILE}$$" | sed 's/|/ /' | awk '{print $2 "\t" $5}' >&2
    USAGES=($(ssh "${SERVER_TRUSTED}" "cat ${SERVER_CORE_USAGES_FILE}$$" | tail -n +2 | sed 's/|/ /' | awk '{print $5}'))
    TOTAL_ACTIVE_AVERAGE=$(get_average ${USAGES[@]})
    >&2 printf "Overall Active: %s\tOverall All cores: %s\n" "${TOTAL_ACTIVE_AVERAGE}" \
        "$(ssh "${SERVER_TRUSTED}" "cat ${SERVER_CORE_USAGES_FILE}$$" | grep all | sed 's/|/ /' | awk '{print $5}')"
    rates=("$(get_port_rate "${CLIENT_TRUSTED}" "${CLIENT_DEVICE}")" "$(get_port_rate "${SERVER_TRUSTED}" "${SERVER_DEVICE}")")
    min_rate=$(get_min_val ${rates[@]})
    log "Throughput is: $(awk "BEGIN {printf \"%.2f\n\",${BITS}/1000000000}") Gb/s (maximal expected line rate is: ${min_rate} Gb/s)."
}


find_cuda() {
    SERVER_TRUSTED=$1
    NICX=$2
    RELATION=$3
    CUDA_INDEX=-1
    LINE=$(ssh "${SERVER_TRUSTED}" "nvidia-smi topo -mp" | grep -w "^${NICX}" | grep "${RELATION}" )
    RES=""
    for RL in $LINE
    do
       if [ "$RL" = "$RELATION" ]
          then
          if  [ "$RES" = "" ]
          then
             RES="$CUDA_INDEX"
          else
             RES="${RES},$CUDA_INDEX"
          fi
       fi
       CUDA_INDEX=$((CUDA_INDEX+1))
       if (( CUDA_INDEX > $((GPUS_COUNT-1)) ))
       then
          break
       fi
    done
    if  [ "$RES" != "" ]
    then
       echo $RES
       exit 0
    fi
}

get_cudas_per_rdma_device() {
    SERVER_TRUSTED="${1}"
    RDMA_DEVICE="$2"
    GPUS_COUNT=$(ssh "${SERVER_TRUSTED}" "nvidia-smi -L" | wc -l)
    if ssh "${SERVER_TRUSTED}" "nvidia-smi topo -mp" | grep -q "NIC Legend"
    then
        NICX="$(ssh "${SERVER_TRUSTED}" "nvidia-smi topo -mp" | grep -w "$RDMA_DEVICE" | cut -d : -f 1 | xargs )"
    else
        NICX="$RDMA_DEVICE"
    fi
    if [ "$NICX" = "" ]
    then
        exit 1
    fi
    #loop over expected relations between NIC and GPU:
    #if there is a connection traversing at most a single PCIe bridge - PIX
    #if there is a connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge) - PXB
    for RELATION in "PIX" "PXB"
    do
        find_cuda "$SERVER_TRUSTED" "$NICX" "$RELATION"
    done
    exit 1
}
