#!/bin/bash
# NGC Certification common functions v0.1
# Owner: dorko@nvidia.com
#

scriptdir="$(dirname "$0")"
WHITE='\033[1;37m'
GREEN='\033[1;32m'
ORANGE='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'


# Function to declare and clear GPU allocation tracking (called at start of each test run)
clear_gpu_allocations() {
    for ((i=0; i<NUM_DEVS; i++)); do
        declare -ga "ALLOCATED_SERVER_DEVICE_${i}_GPUS=()"
        declare -ga "ALLOCATED_CLIENT_DEVICE_${i}_GPUS=()"
    done
    
    log "Cleared GPU allocation tracking for new test run (${NUM_DEVS} devices)"
}

log() {
    local line prefix prio out color
    line="${1}"
    prefix="${2}"

    [ -n "${prefix}" ] || prefix="INFO"
    case "${prefix}" in
        "INFO")
            prio="info"
            out="stderr"
            ;;
        "RESULT_PASS")
            prio="info"
            color="${GREEN}"
            ;;
        "RESULT_FAIL")
            prio="info"
            color="${RED}"
            ;;
        "ERROR")
            prio="err"
            out="stderr"
            color="${RED}"
            ;;
        *)
            prio="warning"
            out="stderr"
            color="${ORANGE}"
            ;;
    esac

    if [ "${out}" = "stderr" ]
    then
        printf "${color}%s: %s${NC}\n" "${prefix}" "${line}" |
            tee >(systemd-cat -t ngc_multinode_perf -p "${prio}") >&2
    else
        printf "${color}%s: %s${NC}\n" "${prefix}" "${line}" |
            tee >(systemd-cat -t ngc_multinode_perf -p "${prio}")
    fi
}

fatal() {
    log "${*}" ERROR
    exit 1
}

check_connection() {
    ssh "${CLIENT_TRUSTED}" ping "${SERVER_IP}" -c 5 ||
        fatal "No ping from client to server, test aborted"
}

check_if_number(){
    local re num
    num=$1
    re='^[0-9]+(\.[0-9]+)?$'
    [[ $num =~ $re ]] || return 1
}

change_local_mtu() {
    local ibdev netdev mtu dev ns_prefix

    ibdev="${1}"
    netdev="${2}"
    mtu="${3}"
    ns_prefix=""${@:4}""

    echo "${mtu}" | sudo ${ns_prefix} tee "/sys/class/net/${netdev}/mtu"
    for dev in $(${ns_prefix} ls /sys/class/infiniband/${ibdev}/device/net/)
    do
        echo "${mtu}" | sudo ${ns_prefix} tee "/sys/class/net/${dev##*/}/mtu" > /dev/null
    done
}

change_mtu() {
    if [ "${LINK_TYPE}" -eq 1 ]; then
        MTU=9000
    elif [ "${LINK_TYPE}" -eq 32 ]; then
        MTU=4092
    fi
    num_devs=${#SERVER_DEVICES[@]}
    for i in "${!CLIENT_NETDEVS[@]}"
    do
        server_ns_prefix=$(get_command_prefix ${i})
        client_ns_prefix=$(get_command_prefix $((i+num_devs)))
        ssh "${CLIENT_TRUSTED}" "bash -c '$(typeset -f change_local_mtu); change_local_mtu ${CLIENT_DEVICES[i]} ${CLIENT_NETDEVS[i]} ${MTU} ${client_ns_prefix} " " '"
        ssh "${SERVER_TRUSTED}" "bash -c '$(typeset -f change_local_mtu); change_local_mtu ${SERVER_DEVICES[i]} ${SERVER_NETDEVS[i]} ${MTU} ${server_ns_prefix}'"
        CURR_MTU="$(ssh "${CLIENT_TRUSTED}" "${client_ns_prefix} cat /sys/class/net/${CLIENT_NETDEVS[i]}/mtu")"
        ((CURR_MTU == MTU)) || log 'Warning, MTU was not configured correctly on Client'
        CURR_MTU="$(ssh "${SERVER_TRUSTED}" " ${server_ns_prefix} cat /sys/class/net/${SERVER_NETDEVS[i]}/mtu")"
        ((CURR_MTU == MTU)) || log 'Warning, MTU was not configured correctly on Server'
    done
}

run_iperf2() {
    ssh "${SERVER_TRUSTED}" pkill iperf
    ssh "${SERVER_TRUSTED}" iperf -s &
    sleep 5
    ssh "${CLIENT_TRUSTED}" iperf -c "${SERVER_IP}" -P "${MAX_PROC}" -t 30
    ssh "${SERVER_TRUSTED}" pkill iperf
}

get_average() {
    (( $# != 0 )) || fatal "Average can not be called on an empty array."
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

get_netdevs() {
    local sdev cdev i
    SERVER_NETDEVS=()
    i=0
    for sdev in "${SERVER_DEVICES[@]}"
    do
        prefix=$(get_command_prefix ${i})
        SERVER_NETDEVS+=("$(ssh "${SERVER_TRUSTED}" "$(typeset -f get_netdev_from_ibdev); get_netdev_from_ibdev ${sdev} "${prefix}" ")")
        [ -n "${SERVER_NETDEVS[${#SERVER_NETDEVS[@]}-1]}" ] ||
            fatal "Can't find a server net device associated with the IB device '${sdev}'."
        i=$((i+1))
    done
    CLIENT_NETDEVS=()
    #Initialize i to first index of client namespaces
    i=${#SERVER_DEVICES[@]}
    for cdev in "${CLIENT_DEVICES[@]}"
    do
        prefix=$(get_command_prefix ${i})
        CLIENT_NETDEVS+=("$(ssh "${CLIENT_TRUSTED}" "$(typeset -f get_netdev_from_ibdev); get_netdev_from_ibdev ${cdev} "${prefix}" ")")
        [ -n "${CLIENT_NETDEVS[${#CLIENT_NETDEVS[@]}-1]}" ] ||
            fatal "Can't find a client net device associated with the IB device '${cdev}'."
        i=$((i+1))
    done
}

get_ips() {
    local sdev cdev i
    SERVER_IPS=()
    SERVER_IPS_MASK=()
    i=0
    for sdev in "${SERVER_DEVICES[@]}"
    do
        prefix=$(get_command_prefix ${i})
        if ! ip_str=$(ssh "${SERVER_TRUSTED}" "${prefix}ip a sh ${SERVER_NETDEVS[i]} | grep -w '^[[:space:]]\+inet'")
        then
            fatal "Interface ${SERVER_NETDEVS[i]} on ${SERVER_TRUSTED#*@} seems not to have an IPv4."
        fi
        SERVER_IPS+=("$( echo "$ip_str" | grep -ioP '(?<=inet )\d+\.\d+\.\d+\.\d+' | xargs | tr ' ' ',')")
        SERVER_IPS_MASK+=("$( echo "$ip_str" | grep -ioP "(?<=${SERVER_IPS[i]}/)\d+" | xargs | tr ' ' ',')")
        [ -z "${SERVER_IPS[${#SERVER_IPS[@]}-1]}" ] &&
            fatal "Can't find a server IP associated with the net device '${SERVER_NETDEVS[i]}'." ||
            log "Found $(awk -F',' '{print NF}' <<<"${SERVER_IPS[${#SERVER_IPS[@]}-1]}") IPs associated with the server net device '${SERVER_NETDEVS[i]}'."
        i=$((i+1))
    done
    CLIENT_IPS=()
    CLIENT_IPS_MASK=()
    i=0
    ns_i_offset=${#SERVER_DEVICES[@]}
    for cdev in "${CLIENT_DEVICES[@]}"
    do
        prefix=$(get_command_prefix $((i+ns_i_offset)))
        if ! ip_str=$(ssh "${CLIENT_TRUSTED}" "${prefix} ip a sh ${CLIENT_NETDEVS[i]} | grep -w '^[[:space:]]\+inet'")
        then
            fatal "Interface ${CLIENT_NETDEVS[i]} on ${CLIENT_TRUSTED#*@} seems not to have an IPv4."
        fi
        CLIENT_IPS+=("$( echo "$ip_str" | grep -ioP '(?<=inet )\d+\.\d+\.\d+\.\d+' | xargs | tr ' ' ',')")
        CLIENT_IPS_MASK+=("$( echo "$ip_str" | grep -ioP "(?<=${CLIENT_IPS[i]}/)\d+" | xargs | tr ' ' ',')")
        [ -z "${CLIENT_IPS[${#CLIENT_IPS[@]}-1]}" ] &&
            fatal "Can't find a client IP associated with the net device '${CLIENT_NETDEVS[i]}'." ||
            log "Found $(awk -F',' '{print NF}' <<<"${CLIENT_IPS[${#CLIENT_IPS[@]}-1]}") IPs associated with the client net device '${CLIENT_NETDEVS[i]}'."
        i=$((i+1))
    done
}

#return array of namespaces, "NGC_NA" if device was not in a namespace
get_configured_namespaces() {
    HOST="$1"
    DEVICES="$2"
    local i=0
    netns_list=$(ssh "${HOST}" "ip netns list | awk '{print \$1}'")
    for dev in "${DEVICES[@]}"
    do
       for netns in $netns_list; do
           dev_ns=$(ssh "${HOST}"     "ip netns exec $netns ls  /sys/class/infiniband/$dev/device/net 2> /dev/null")
           if ! [ "$dev_ns" = "" ]; then
               dev_ns_list[i]="${netns}"
           fi
       done
       if [ "${dev_ns_list[i]}" = "" ]; then
           dev_ns_list[i]="NGC_NA"
       fi
     i=$((i+1))
     done
     echo "${dev_ns_list[@]}"
}

#Return prefix to run on namespace context , or empty string if dev is not in namespace,
#assuming DEVICES_NS are SERVER name spaces followed by client namespaces
get_command_prefix(){
    INDEX=${1}
    if [[ -v DEVICES_NS && "${DEVICES_NS[INDEX]}" == ngc_ns_* ]]; then
        echo "ip netns exec ${DEVICES_NS[INDEX]} "
    else
        echo ""
    fi
}

#Add device with index i to namespace, it will keeping its IP.
#the new namespace will be ngc_ns_${TIME_STAMP}_${i}
add_dev_to_namespace() {
    HOST=$1
    HOST_DEVS=$2
    INDEX=$3
    SERVER_NETDEV=("$(ssh "${HOST}" "$(typeset -f get_netdev_from_ibdev); get_netdev_from_ibdev ${HOST_DEVS[INDEX]}")")
    NEW_NS=ngc_ns_${TIME_STAMP}_${INDEX}
    NS_PREFIX="ip netns exec ${NEW_NS}"
    #create namespace
    ssh "${HOST}" "ip netns add ${NEW_NS}"
    #Add dev to namespace
    ssh "${HOST}" "ip link set ${SERVER_NETDEV} netns ${NEW_NS}"
    ssh "${HOST}" "sudo ${NS_PREFIX} ip link set lo up"
    ssh "${HOST}" "sudo ${NS_PREFIX} ip l set ${SERVER_NETDEV} down; sudo ${NS_PREFIX} ip l set ${SERVER_NETDEV} up; sleep 1; sudo ${NS_PREFIX} ip a add ${SERVER_IPS[INDEX]}/${SERVER_IPS_MASK[INDEX]} broadcast + dev ${SERVER_NETDEV}" || :

    echo ${NEW_NS}
}

#delete the namespaces we created
delete_namespaces_from_host() {
    HOST=$1
    HOST_DEVS=$2
    DEVICES_NS=$3
    #loop over name spaces and delete the once we created, and reset there IPs
    for ((i=0; i<${#HOST_DEVS[@]} ; i++))
    do
        if [[ "${DEVICES_NS[i]}" == ngc_ns_* ]]; then
            prefix="$(get_command_prefix ${i})"
            HOST_NETDEV="$(ssh "${HOST}" "$(typeset -f get_netdev_from_ibdev); get_netdev_from_ibdev ${HOST_DEVS[i]} "${prefix}" ")"
               ssh "${HOST}" "ip netns delete ${DEVICES_NS[i]}"
            sleep 2
            ssh "${HOST}" "sudo ip l set ${HOST_NETDEV} down; sudo ip l set ${HOST_NETDEV} up; sleep 1 ;  sudo ip a add ${SERVER_IPS[i]}/${SERVER_IPS_MASK[i]} broadcast + dev ${HOST_NETDEV}" || :
            DEVICES_NS[i]="NGC_NA"
        fi
    done
}

manage_namespaces() {
    declare -g -a dev_ns_list
    read -ra SERVER_NS <<< $(get_configured_namespaces $SERVER_TRUSTED $SERVER_DEVICES)
    read -ra CLIENT_NS <<< $(get_configured_namespaces $CLIENT_TRUSTED $CLIENT_DEVICES)
    DEVICES_NS=("${SERVER_NS[@]}" "${CLIENT_NS[@]}")
    get_ips_and_ifs

    #Check if we intend to run external loopback
    if [ ${CLIENT_TRUSTED} = ${SERVER_TRUSTED} ]
    then
        #check if each pair of device are on different namespace, if not add the client devices to namespaces.
        #without doing so a kernel optimization traffic will pass though kernel and not though the physical layer.
         for ((i=0; i<${#SERVER_NS[@]} ; i++))
         do
             if [ "${CLIENT_NS[i]}" = "${SERVER_NS[i]}" ]; then
                 #This mean that there is 2 interfaces under same namespace.
                 SERVER_NS[i]=$(add_dev_to_namespace $SERVER_TRUSTED $SERVER_DEVICES $i)
             fi
         done
    #update array in case SERVER_NS changed
    DEVICES_NS=("${SERVER_NS[@]}" "${CLIENT_NS[@]}")
    fi

    echo "${DEVICES_NS[*]}"
}

get_ips_and_ifs() {
    get_netdevs
    get_ips
}

get_netdev_from_ibdev() {
    local ibdev netdev sfdev
    ibdev="${1}"
    if [ "$#" -ne 1 ]; then
       prefix="${@:2}"
    else
       prefix=""
    fi

    netdev="$( ${prefix} ls -1 "/sys/class/infiniband/${ibdev}/device/net" | head -1)"
    if mlnx-sf -h &> /dev/null
    then
        sfdev="$(mlnx-sf -ja show | sed 's/^No SF device found$/{}/' | jq -r --arg SF "${netdev}" '.[] | select(.netdev==$SF) | .sf_netdev' 2>/dev/null)"
    fi
    [ -z "${sfdev}" ] || netdev="${sfdev}"
    printf "%s" "${netdev}"
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
                CLIENT_NETDEV+=("$(ssh "${CLIENT_TRUSTED}" "$(typeset -f get_netdev_from_ibdev); get_netdev_from_ibdev ${cdev}")")
                [ -n "${CLIENT_NETDEV[${#CLIENT_NETDEV[@]}-1]}" ] ||
                    fatal "Can't find a client net device associated with the IB device '${cdev}'."
                CLIENT_IP+=("$(ssh "${CLIENT_TRUSTED}" "ip a sh ${CLIENT_NETDEV[${#CLIENT_NETDEV[@]}-1]}" | grep -ioP '(?<=inet )\d+\.\d+\.\d+\.\d+' | xargs | tr ' ' ',')")
                [ -z "${CLIENT_IP[${#CLIENT_IP[@]}-1]}" ] &&
                    fatal "Can't find a client IP associated with the net device '${CLIENT_NETDEV[${#CLIENT_NETDEV[@]}-1]}'." ||
                    log "Found $(awk -F',' '{print NF}' <<<"${CLIENT_IP[${#CLIENT_IP[@]}-1]}") IPs associated with the client net device '${CLIENT_NETDEV[${#CLIENT_NETDEV[@]}-1]}'."
            done
            ;;
        *)
            CLIENT_NETDEV="$(ssh "${CLIENT_TRUSTED}" "$(typeset -f get_netdev_from_ibdev); get_netdev_from_ibdev ${CLIENT_DEVICE}")"
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
                SERVER_NETDEV+=("$(ssh "${SERVER_TRUSTED}" "$(typeset -f get_netdev_from_ibdev); get_netdev_from_ibdev ${sdev}")")
                [ -n "${SERVER_NETDEV[${#SERVER_NETDEV[@]}-1]}" ] ||
                    fatal "Can't find a server net device associated with the IB device '${sdev}'."
                SERVER_IP+=("$(ssh "${SERVER_TRUSTED}" "ip a sh ${SERVER_NETDEV[${#SERVER_NETDEV[@]}-1]}" | grep -ioP '(?<=inet )\d+\.\d+\.\d+\.\d+' | xargs | tr ' ' ',')")
                [ -z "${SERVER_IP[${#SERVER_IP[@]}-1]}" ] &&
                    fatal "Can't find a server IP associated with the net device '${SERVER_NETDEV[${#SERVER_NETDEV[@]}-1]}'." ||
                    log "Found $(awk -F',' '{print NF}' <<<"${SERVER_IP[${#SERVER_IP[@]}-1]}") IPs associated with the server net device '${SERVER_NETDEV[${#SERVER_NETDEV[@]}-1]}'."
            done
            ;;
        *)
            SERVER_NETDEV="$(ssh "${SERVER_TRUSTED}" "$(typeset -f get_netdev_from_ibdev); get_netdev_from_ibdev ${SERVER_DEVICE}")"
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

    find_empty_numas=( "numactl" "-H" "|" "awk"
                       "'/node [0-9]+ size:/{print \$4}'" "|"
                       "grep" "-q" "'^0$'" )
    ! ssh "${CLIENT_TRUSTED}" "${find_empty_numas[*]}" ||
        fatal "${CLIENT_TRUSTED#*@} has empty NUMAs - please verify your BIOS/SMT settings."
    ! ssh "${SERVER_TRUSTED}" "${find_empty_numas[*]}" ||
        fatal "${SERVER_TRUSTED#*@} has empty NUMAs - please verify your BIOS/SMT settings."

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
    NUMACTL_HW=("numactl" "-H" "|" "grep" "-v" "node")
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
        "${SERVER_BASE_NUMA}" "${BASE_TCP_PORT}" "${SERVER_IP[$((P%IP_AMOUNT))]}" &
    if [ "$DUPLEX" = "true" ]; then
        ssh "${CLIENT_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_servers.sh" \
            "${PROC}" "${CLIENT_NUMA_NODE}" "${CLIENT_LOGICAL_NUMA_PER_SOCKET}" \
            "${CLIENT_BASE_NUMA}" "${BASE_TCP_PORT}" "${CLIENT_IP[$((P%IP_AMOUNT))]}" &
    fi

    check_connection

    ssh "${CLIENT_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_clients.sh" \
        "${RESULT_FILE}" "${PROC}" "${CLIENT_NUMA_NODE}" "${CLIENT_LOGICAL_NUMA_PER_SOCKET}" \
        "${CLIENT_BASE_NUMA}" "${SERVER_IP[$((P%IP_AMOUNT))]}" \
        "${BASE_TCP_PORT}" "${THREADS}" "${TIME}" "${CLIENT_IP[$((P%IP_AMOUNT))]}" &
    if [ "$DUPLEX" = "true" ]; then
        sleep 0.1
        ssh "${SERVER_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_clients.sh" \
            "${RESULT_FILE}" "${PROC}" "${SERVER_NUMA_NODE}" "${SERVER_LOGICAL_NUMA_PER_SOCKET}" \
            "${SERVER_BASE_NUMA}" "${CLIENT_IP[$((P%IP_AMOUNT))]}" \
            "${BASE_TCP_PORT}" "${THREADS}" "${TIME}" "${SERVER_IP[$((P%IP_AMOUNT))]}" &
    fi

    DURATION=$((TIME - 1))
    ssh "${CLIENT_TRUSTED}" "sar -u -P ${CLIENT_ACTIVE_CORES_LIST_STRING},all ${DURATION} 1 | grep 'Average' | head -n $((PROC + 1)) > ${CLIENT_CORE_USAGES_FILE}$$" &
    ssh "${SERVER_TRUSTED}" "sar -u -P ${SERVER_ACTIVE_CORES_LIST_STRING},all ${DURATION} 1 | grep 'Average' | head -n $((PROC + 1)) > ${SERVER_CORE_USAGES_FILE}$$" &
    wait

    BITS=$(ssh "${CLIENT_TRUSTED}" "jq -s '[.[].end.sum_sent.bits_per_second] | add' <\"${RESULT_FILE}\"")

    log "${CLIENT_TRUSTED#*@} Active cores: ${CLIENT_ACTIVE_CORES_LIST_STRING}"
    log "Active core usages on ${CLIENT_TRUSTED#*@}"
    ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | sed 's/|/ /' | awk '{print $2 "\t" $5}' >&2
    USAGES=($(ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | tail -n +2 | sed 's/|/ /' | awk '{print $5}'))
    TOTAL_ACTIVE_AVERAGE=$(get_average ${USAGES[@]})
    >&2 printf "Overall Active: %s\tOverall All cores: %s\n" "${TOTAL_ACTIVE_AVERAGE}" \
        "$(ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | grep all | sed 's/|/ /' | awk '{print $5}')"

    log "${SERVER_TRUSTED#*@} Active cores: ${SERVER_ACTIVE_CORES_LIST_STRING}"
    log "Active core usages on ${SERVER_TRUSTED#*@}"
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
    EXCLUDED_GPUS="${4:-}"  # Optional: comma-separated list of excluded GPU indices
    
    CUDA_INDEX=-1
    LINE=$(ssh "${SERVER_TRUSTED}" "nvidia-smi topo -mp" | grep -w "^${NICX}" | grep "${RELATION}" )
    RES=""
    
    # Convert excluded list to array for easy checking
    IFS=',' read -ra excluded_array <<< "$EXCLUDED_GPUS"
    
    for RL in $LINE
    do
       if [ "$RL" = "$RELATION" ]
          then
          # Check if this GPU is already allocated
          gpu_excluded=false
          for excluded_gpu in "${excluded_array[@]}"; do
              if [ "$CUDA_INDEX" = "$excluded_gpu" ]; then
                  gpu_excluded=true
                  break
              fi
          done
          
          # Only add if not excluded
          if [ "$gpu_excluded" = false ]; then
              if  [ "$RES" = "" ]
              then
                 RES="$CUDA_INDEX"
              else
                 RES="${RES},$CUDA_INDEX"
              fi
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
    local node_relations

    SERVER_TRUSTED="${1}"
    RDMA_DEVICE="$2"
    USER_DEF_CUDA="${3}"
    EXCLUDED_GPUS="${4:-}"  # Optional: comma-separated list of excluded GPU indices
    
    if [ -n "${USER_DEF_CUDA}" ]; then
        echo "${USER_DEF_CUDA}"
        return
    fi
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
    #[optional] connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node - NODE
    node_relations=( "PIX" "PXB" )
    [ "${ALLOW_GPU_NODE_RELATION}" != true ] || node_relations+=( "NODE" )
    for RELATION in "${node_relations[@]}"
    do
        find_cuda "$SERVER_TRUSTED" "$NICX" "$RELATION" "$EXCLUDED_GPUS"
    done
    exit 1
}

get_numa_nodes_array() {
    local ITER=0
    local IP=$1
    local RDMA_DEVICES=(${2//,/ })
    declare -a DEVCIES_NUMA=("${RDMA_DEVICES[@]/*/0}")
    for dev in "${RDMA_DEVICES[@]}"
    do
        if ssh ${IP} "test -e /sys/class/infiniband/${dev}/device/numa_node"; then
            NUMA_NODE=$(ssh ${IP} cat /sys/class/infiniband/${dev}/device/numa_node)
            if [[ $NUMA_NODE == "-1" ]]; then
                NUMA_NODE="0"
            fi
        else
            NUMA_NODE="0"
        fi
        DEVCIES_NUMA[$ITER]=$NUMA_NODE
        ITER=$((ITER+1))
     done
     echo "${DEVCIES_NUMA[*]}"
}

#Will return cores form the closest numa node
#param: NUMA_NODE index,  string of NUMASTL -H output , NEIGHBOR_LEVELS how many neighbors
get_more_cores_for_closest_numa(){
    local numa_index=$1
    local STR_NUMACTL="$2"
    local NEIGHBOR_LEVELS=$3

    distances=( $(echo "$STR_NUMACTL" | sed -n "s/ ${numa_index}://p") )
    sorted_indxes_and_dist=($(for i in "${!distances[@]}"; do echo "$i ${distances[$i]}"; done | sort -n -k2))
    echo "${sorted[@]}"
    #get only indexes without the first one - since distance to self will be the lower values.
    sorted_indexes=($(echo "${sorted_indxes_and_dist[@]}" | awk '{for(i=3; i<=NF; i+=2) print $i}'))

    local level=1
    res=()
    for nighbor_numa in "${sorted_indexes[@]}"
    do
        if [ $level -gt $NEIGHBOR_LEVELS ]
        then
            break
        fi
        res+=( $(echo "$STR_NUMACTL"| grep -i "node $nighbor_numa cpus" | awk '{print substr($0,14)}'))
        level=$((level+1))
    done

    echo ${res[@]}
}

#global params :
#NUMA_NODES
get_available_cores_per_device(){
    local CURRENT_TRUSTED=$1
    local REQ_CORE_NUM=$2
    local SIDE=$3  # "SERVER" or "CLIENT"
    local OTHER_TRUSTED=$4
    local i=0
    declare -a INDEX_OF_DEVICE_IN_NUMA
    declare -a NUM_ARRAY
    STR_NUMASTL=$(ssh ${CURRENT_TRUSTED} numactl -H)
    #Set max to number of cores in first numa
    local MAX_POSSIBLE_CORES_PER_DEVICE=$( echo "${STR_NUMASTL}" | grep -i "node ${NUMA_NODES[0]} cpus" | awk '{print substr($0,14)}' | wc -w )
    if [ $MAX_POSSIBLE_CORES_PER_DEVICE -gt $REQ_CORE_NUM ]
    then
        MAX_POSSIBLE_CORES_PER_DEVICE=$REQ_CORE_NUM
    fi
    MAX_POSSIBLE_CORES_PER_DEVICE=85
    for n in "${NUMA_NODES[@]}"
    do
        CORES_IN_NUMA_REF="CORES_IN_NUMA_${n}"
        if [  "$(eval "echo \${#${CORES_IN_NUMA_REF}[@]}")" -eq 0 ]
        then
            #Save core list on NUMA n
            eval "declare -a CORES_IN_NUMA_${n}=($(ssh ${CURRENT_TRUSTED} numactl -H | grep -i "node $n cpus" | awk '{print substr($0,14)}')) ";
            if [ "$(eval "echo \${#${CORES_IN_NUMA_REF}[@]}")" -lt $REQ_CORE_NUM ]
            then
                eval "${CORES_IN_NUMA_REF}+=( $(get_more_cores_for_closest_numa $n "$STR_NUMASTL" $NEIGHBOR_LEVELS) )"
            fi
            NUM_ARRAY["num_devices_${n}"]=1
        else
            curr_value="${NUM_ARRAY["num_devices_${n}"]}"
            NUM_ARRAY["num_devices_${n}"]=$((curr_value+1))
        fi

        INDEX_OF_DEVICE_IN_NUMA[$i]="${NUM_ARRAY["num_devices_${n}"]}"
        i=$((i+1))
        curr_value="${NUM_ARRAY["num_devices_${n}"]}"
        eval 'array_count=${#CORES_IN_NUMA_'"$n"'[@]}'
        COUNT_CORES=$(( array_count / curr_value))
        if [ $MAX_POSSIBLE_CORES_PER_DEVICE -gt $COUNT_CORES ]
        then
            MAX_POSSIBLE_CORES_PER_DEVICE=$COUNT_CORES
        fi
    done
    #reset i
    i=0
    log "Each device can use up to $MAX_POSSIBLE_CORES_PER_DEVICE cores (may include core 0)"
    local j
    for n in "${NUMA_NODES[@]}"
    do
        device_cores=()
        # Split cores between server and client if they are on the same host
        local start_index=0
        local end_index=MAX_POSSIBLE_CORES_PER_DEVICE
        if [ ${CURRENT_TRUSTED#*@} = ${OTHER_TRUSTED#*@} ]; then
            if [ "$SIDE" = "SERVER" ]; then
                end_index=$((MAX_POSSIBLE_CORES_PER_DEVICE/2))
            elif [ "$SIDE" = "CLIENT" ]; then
                start_index=$((MAX_POSSIBLE_CORES_PER_DEVICE/2))
            fi
        fi
        for ((j=start_index; j<end_index; j++))
        do
            index=$((j + (INDEX_OF_DEVICE_IN_NUMA[i]-1)*MAX_POSSIBLE_CORES_PER_DEVICE))

            eval "res=\${CORES_IN_NUMA_${n}[\$index]}"
            eval "all=\${CORES_IN_NUMA_${n}[@]}"
            if [ "$ALLOW_CORE_ZERO" = "true" ] || [ "$res" != "0" ]; then
                device_cores+=($res)
            fi
        done
        declare -ga "${SIDE}_DEVICE_${i}_CORES=(${device_cores[*]})"
        i=$((i+1))
    done
}


#Normalize core list:
#use same number of cores on each side
#avoid using core 0 if needed.
#when running full duplex make sure w
normalize_core_lists() {
    # Find minimum cores across all devices
    eval "local first_server_cores=(\${SERVER_DEVICE_0_CORES[@]})"
    eval "local first_client_cores=(\${CLIENT_DEVICE_0_CORES[@]})"
    local min_server_cores=${#first_server_cores[@]}
    local min_client_cores=${#first_client_cores[@]}
    
    for((i=1; i<NUM_DEVS; i++)); do
        eval "local server_cores=(\${SERVER_DEVICE_${i}_CORES[@]})"
        eval "local client_cores=(\${CLIENT_DEVICE_${i}_CORES[@]})"
        (( ${#server_cores[@]} < min_server_cores )) && min_server_cores=${#server_cores[@]}
        (( ${#client_cores[@]} < min_client_cores )) && min_client_cores=${#client_cores[@]}
    done
    local max_usable_cores=$((min_server_cores<min_client_cores ? min_server_cores : min_client_cores))
    #TODO check if need to limit number of cores to number of channels
    max_usable_cores=$((84<max_usable_cores ? 84 : max_usable_cores))
    e_offset=0
    #in case of duplex make sure the #core is even
    if [ "$DUPLEX" = "true" ] && [ $((max_usable_cores%2)) -eq 1 ]
    then
        e_offset=1
    fi
    #Reduce #core to up to opt_proc
    finial_core_count=$((max_usable_cores<opt_proc ? max_usable_cores : opt_proc))
    #make sure even number of cores is used for full duplex
    if [ $((finial_core_count%2)) -eq 1 ] && [ "$DUPLEX" = "true" ]
    then
        finial_core_count=$((finial_core_count-1))
    fi
    if [ $((max_usable_cores-NUM_DEVS)) -lt $finial_core_count ]
    then
        up_to=$((finial_core_count - e_offset))
    else
        up_to=$finial_core_count
    fi
    local shead_array=()
    local chead_array=()
    for((i=0; i<NUM_DEVS; i++))
    do
        eval "local client_device_cores=(\${CLIENT_DEVICE_${i}_CORES[@]})"
        eval "local server_device_cores=(\${SERVER_DEVICE_${i}_CORES[@]})"

        chead_array+=(${client_device_cores[@]:0:$up_to})
        shead_array+=(${server_device_cores[@]:0:$up_to})
    done
    echo "${shead_array[@]} ${chead_array[@]}"
}

get_cores_for_devices(){
    local CLIENT_TRUSTED="${1}"
    local CLIENT_DEVICES=(${2})
    local SERVER_TRUSTED="${3}"
    local SERVER_DEVICES=(${4})

    NUMA_NODES=($(get_numa_nodes_array "$SERVER_TRUSTED" "$SERVER_DEVICES"))
    get_available_cores_per_device $SERVER_TRUSTED $5 "SERVER" "$CLIENT_TRUSTED"
    NUMA_NODES=($(get_numa_nodes_array "$CLIENT_TRUSTED" "$CLIENT_DEVICES"))
    get_available_cores_per_device $CLIENT_TRUSTED $5 "CLIENT" "$SERVER_TRUSTED"
    normalize_core_lists
}

get_min_channels(){
    server_prefix="$(get_command_prefix 0)"
    min=$(ssh "${SERVER_TRUSTED}" "${server_prefix} ethtool -l ${SERVER_NETDEVS[0]} | awk -F: '/Combined/{print $2;exit;}' | grep -Eo '[0-9]+\$'")
    i=0
    for dev in "${SERVER_NETDEVS[@]}"
    do
        server_prefix="$(get_command_prefix $i)"
        tmp=$(ssh "${SERVER_TRUSTED}" "${server_prefix} ethtool -l ${dev} |  awk -F: '/Combined/{print $2;exit;}' | grep -Eo '[0-9]+\$'")
        if [ $tmp -lt $min ]
        then
            min=$tmp
        fi
        i=$((i+1))
    done
    i=${#SERVER_NETDEVS[@]}
    for dev in "${CLIENT_NETDEVS[@]}"
    do
        client_prefix="$(get_command_prefix $i)"
        tmp=$(ssh "${CLIENT_TRUSTED}" "${client_prefix} ethtool -l ${dev} |  awk -F: '/Combined/{print $2;exit;}' | grep -Eo '[0-9]+\$'")
        if [ $tmp -lt $min ]
        then
            min=$tmp
        fi
    done
    echo $min
}

#Disable PCI relaxed ordering
disable_pci_RO() {
    local SERVER=$1
    local SERVER_NETDEV=$2
    if [ "$#" -ne 1 ]; then
       prefix="${@:3}"
    else
       prefix=""
    fi
    pci=$(ssh "${SERVER}" "sudo ${prefix} ethtool -i ${SERVER_NETDEV} | grep "bus-info" | awk '{print \$2}' ")
    sleep 5
    curr_val=$(ssh "${SERVER}" "sudo setpci -s ${pci} CAP_EXP+8.b")
    update_val=$(printf '%X\n' "$(( 0x$curr_val & 0xEF ))")
    if ! [ "${curr_val,,}" = "${update_val,,}" ]
    then
        ssh "${SERVER}" "sudo setpci -s ${pci} CAP_EXP+8.b=$update_val"
        log "PCIe ${pci} relaxed ordering was disabled - please restart driver" WARNING
        FORCE_EXIT=true
    fi
}

# Enable aRFS for ethernet links
enable_aRFS() {
    local SERVER=$1
    local SERVER_NETDEV=$2
    if [ "$#" -ne 1 ]; then
       prefix="${@:3}"
    else
       prefix=""
    fi
    #TODO: check if supported
    ssh "${SERVER}" "${prefix}sudo ethtool -K ${SERVER_NETDEV} ntuple off"
    ssh "${SERVER}" "echo 0 | sudo tee /proc/sys/net/core/rps_sock_flow_entries > /dev/null"
}

enable_flow_stearing(){
    local CLIENT_NETDEV=$1
    local SERVER_NETDEV=$2
    local index=$3
    local i
    local -a cmd_arr
    server_ns_prefix=$(get_command_prefix ${i})
    client_ns_prefix=$(get_command_prefix $((num_devs+i)))
    ssh "${CLIENT_TRUSTED}" "for ((j=0; j<100; j++)); do sudo ${client_ns_prefix} ethtool -U ${CLIENT_NETDEV} delete \${j} &> /dev/null; done" || :
    ssh "${SERVER_TRUSTED}" "for ((j=0; j<100; j++)); do sudo ${server_ns_prefix} ethtool -U ${SERVER_NETDEV} delete \${j} &> /dev/null; done" || :
    log "done attempting to delete any existing rules, ethtool -U $SERVER_NETDEV delete "
    sleep 1
    for ((i=0; i < $NUM_INST; i++))
    do
        cmd_arr=("${server_ns_prefix} ethtool" "-U" "${SERVER_NETDEV}" "flow-type" "tcp4" "dst-port" "$((10000*(index+1) + i))" "loc" "${i}" "queue" "${i}")
        ssh "${SERVER_TRUSTED}" "sudo ${cmd_arr[*]}" &> /dev/null
        log "flow starting ${SERVER_TRUSTED#*@}: ${cmd_arr[*]}"
        if [ "$DUPLEX"  = true ]
        then
            cmd_arr=("${server_ns_prefix} ethtool" "-U" "${SERVER_NETDEV}" "flow-type" "tcp4" "src-port" "$((10000*(index+1) + i))" "loc" "$((i+NUM_INST))" "queue" "$((i+NUM_INST))")
            ssh "${SERVER_TRUSTED}" "sudo ${cmd_arr[*]}" &> /dev/null
            log "flow starting ${SERVER_TRUSTED}: ${cmd_arr[*]}"
            cmd_arr=("${client_ns_prefix} ethtool" "-U" "${CLIENT_NETDEV}" "flow-type" "tcp4" "dst-port" "$((11000*(index+1) + i))" "loc" "${i}" "queue" "${i}")
            ssh "${CLIENT_TRUSTED}" "sudo ${cmd_arr[*]}" &> /dev/null
            log "flow starting ${CLIENT_TRUSTED}: ${cmd_arr[*]}"
            cmd_arr=("${client_ns_prefix} ethtool" "-U" "${CLIENT_NETDEV}" "flow-type" "tcp4" "src-port" "$((11000*(index+1) + i))" "loc" "$((i+NUM_INST))" "queue" "$((i+NUM_INST))")
            ssh "${CLIENT_TRUSTED}" "sudo ${cmd_arr[*]}" &> /dev/null
            log "flow starting ${CLIENT_TRUSTED#*@}: ${cmd_arr[*]}"
        else
            cmd_arr=("${client_ns_prefix} ethtool" "-U" "${CLIENT_NETDEV}" "flow-type" "tcp4" "src-port" "$((10000*(index+1) + i))" "loc" "${i}" "queue" "${i}")
            ssh "${CLIENT_TRUSTED}" "sudo ${cmd_arr[*]}" &> /dev/null
            log "flow starting ${CLIENT_TRUSTED#*@}: ${cmd_arr[*]}"
        fi

    done
}

is_SPR() {
    #Sapphire Rapids CPU Model
    #https://en.wikichip.org/wiki/intel/microarchitectures/sapphire_rapids#CPUID
    SPR=143
    cpu_model=$(ssh $1 lscpu | grep -A 10 "Vendor ID:" | grep -A 10 "Intel" | grep "Model:" | awk '{print $2}')
    [[ $cpu_model -eq $SPR ]] &&  echo true || echo false
}

#ِAvailable Prams:
#CLIENT_TRUSTED,CLIENT_DEVICES,SERVER_TRUSTED,SERVER_DEVICES,NUM_INST,NUM_CORES_PER_DEVICE,CORES_ARRAY
tune_tcp() {
    # Stop IRQ balancer service
    ssh "${CLIENT_TRUSTED}" '! systemctl is-active --quiet irqbalance.service || sudo systemctl stop irqbalance.service'
    ssh "${SERVER_TRUSTED}" '! systemctl is-active --quiet irqbalance.service || sudo systemctl stop irqbalance.service'
    #Check if special tuning for Sapphire Rapid system is needed
    IS_SERVER_SPR=$(is_SPR "${SERVER_TRUSTED}")
    IS_CLIENT_SPR=$(is_SPR "${CLIENT_TRUSTED}")
    CHANNELS=$(($NUM_CORES_PER_DEVICE > 63 ? 63 : $NUM_CORES_PER_DEVICE))
    num_devs=${#SERVER_DEVICES[@]}

    local i=0
    for ((; i<num_devs; i++))
    do
        server_netdev="${SERVER_NETDEVS[i]}"
        client_netdev="${CLIENT_NETDEVS[i]}"
        server_ns_prefix=$(get_command_prefix ${i})
        client_ns_prefix=$(get_command_prefix $((num_devs+i)))
        #Set number of channels to number of cores per process
        ssh "${SERVER_TRUSTED}" sudo ${server_ns_prefix} ethtool -L "${server_netdev}" combined "$CHANNELS"
        ssh "${CLIENT_TRUSTED}" sudo ${client_ns_prefix} ethtool -L "${client_netdev}" combined "$CHANNELS"
        if $IS_SERVER_SPR
        then
            #Enhancement:to have multiple profile for SPR , when it is single 400Gb/s port you can set  rx-usecs 128 and rx-frames 512
            ssh "${SERVER_TRUSTED}" "sudo ${server_ns_prefix} ethtool -C ${server_netdev} adaptive-rx off ; sudo ${server_ns_prefix} ethtool -C $server_netdev rx-usecs 128 ; sudo ${server_ns_prefix} ethtool -C $server_netdev rx-frames 512 ; sudo ${server_ns_prefix} ethtool -G $server_netdev rx 4096"
            [ $DISABLE_RO = true ] && disable_pci_RO "${SERVER_TRUSTED}" "${server_netdev}" "${server_ns_prefix}"
        fi

        if $IS_CLIENT_SPR
        then
            ssh "${CLIENT_TRUSTED}" "sudo ethtool -C ${client_netdev} adaptive-rx off ; sudo ethtool -C $client_netdev rx-usecs 128 ; sudo ethtool -C $client_netdev rx-frames 512 ; sudo ethtool -G $client_netdev rx 4096"
            [ $DISABLE_RO = true ] && disable_pci_RO "${CLIENT_TRUSTED}" "${client_netdev}" ${client_ns_prefix}
        fi

        NUM_CORES_AFFINITY=$((NUM_INST/2))
        if [ "$DUPLEX"  = true ]
        then
            NUM_CORES_AFFINITY=$NUM_INST
        fi
        offset_c=$NUM_CORES_AFFINIT

        s_core=$((i*NUM_CORES_PER_DEVICE + offset_c ))
        #indexes of cores for client side starts from the second half of the device.
        c_core=$((i*NUM_CORES_PER_DEVICE +num_devs*NUM_CORES_PER_DEVICE + offset_c ))

        #add dummy core at the start since the first one is used to sync, this will allow us to have one

        ssh "${SERVER_TRUSTED}" sudo ${server_ns_prefix} set_irq_affinity_cpulist.sh "$(tr " " "," <<< "${CORES_ARRAY[@]:s_core:$((NUM_CORES_AFFINITY))}")" "${SERVER_DEVICES[i]}" &> /dev/null
        ssh "${CLIENT_TRUSTED}" sudo ${client_ns_prefix} set_irq_affinity_cpulist.sh "$(tr " " "," <<< "${CORES_ARRAY[@]:c_core:$((NUM_CORES_AFFINITY))}")" "${CLIENT_DEVICES[i]}" &> /dev/null
        log "Device ${SERVER_DEVICES[i]} in server side core affinity is $(tr " " "," <<< "${CORES_ARRAY[@]:s_core:$((NUM_CORES_AFFINITY))}")"
        log "Device ${CLIENT_DEVICES[i]} in client side core affinity is $(tr " " "," <<< "${CORES_ARRAY[@]:c_core:$((NUM_CORES_AFFINITY))}")"
        #Enable aRFS
        if [ ${LINK_TYPE} -eq 9 ]; then
            enable_aRFS "${SERVER_TRUSTED}" "${server_netdev} ${server_ns_prefix}"
            enable_aRFS "${CLIENT_TRUSTED}" "${client_netdev} ${client_ns_prefix}"
        fi
        enable_flow_stearing $client_netdev $server_netdev $i

        ssh "${SERVER_TRUSTED}" "sudo ${server_ns_prefix} ip l set ${server_netdev} down; sudo ${server_ns_prefix} ip l set ${server_netdev} up; sleep 1 ; sudo ${server_ns_prefix} ip a add ${SERVER_IPS[i]}/${SERVER_IPS_MASK[i]} broadcast + dev ${server_netdev}" || :
        ssh "${CLIENT_TRUSTED}" "sudo ${client_ns_prefix} ip l set ${client_netdev} down; sudo ${client_ns_prefix} ip l set ${client_netdev} up; sleep 1 ; sudo ${client_ns_prefix} ip a add ${CLIENT_IPS[i]}/${CLIENT_IPS_MASK[i]} broadcast + dev ${client_netdev}" || :
    done
}

run_iperf_servers() {
    local dev_idx=0
    local -a cmd_arr
    for ((; dev_idx<NUM_DEVS; dev_idx++))
    do
        server_ns_prefix=$(get_command_prefix ${i})
        client_ns_prefix=$(get_command_prefix $((NUM_DEVS+i)))
        local OFFSET_S=$((dev_idx*NUM_CORES_PER_DEVICE ))
        for i in $(seq 0 $((NUM_INST-1))); do
            sleep 0.1
            index=$((i+OFFSET_S))
            core="${CORES_ARRAY[index]}"
            prt=$((BASE_TCP_POTR + 10000*dev_idx + i ))
            bind_ip_i=${SERVER_IPS[dev_idx]}
            cmd_arr=("${server_ns_prefix}" "taskset" "-c" "${core}" "iperf3" "-s" "-B" "${bind_ip_i}" "-p" "${prt}" "--one-off")
            ssh "${SERVER_TRUSTED}" "${cmd_arr[*]} &> /dev/null" &
            log "run iperf3 server on ${SERVER_TRUSTED#*@}: ${cmd_arr[*]}"
        done
        #IF full duplex then create iperf3 servers on client side
        if [ "$DUPLEX"  = "true" ]
        then
            local OFFSET_C=$((dev_idx*NUM_CORES_PER_DEVICE+ NUM_DEVS*NUM_CORES_PER_DEVICE))
            for i in $(seq 0 $((NUM_INST-1)))
            do
                sleep 0.1
                index=$(( i+OFFSET_C ))
                core="${CORES_ARRAY[index]}"
                prt=$((BASE_TCP_POTR + 1000 + 11000*dev_idx + i ))
                bind_ip_i=${CLIENT_IPS[dev_idx]}
                cmd_arr=("${client_ns_prefix}" "taskset" "-c" "${core}" "iperf3" "-s" "-B" "${bind_ip_i}" "-p" "${prt}" "--one-off")
                ssh "${CLIENT_TRUSTED}" "${cmd_arr[*]} &> /dev/null " &
                log "run iperf3 server on ${CLIENT_TRUSTED#*@} core index=${index}: ${cmd_arr[*]}"
            done
        fi
    done
}

run_iperf_clients() {

    DUPLEX_CLIENT_OFFSET=0
    DUPLEX_SERVER_OFFSET=0
    iperf_clients_to_run_client_side="/tmp/client_cmds_${TIME_STAMP}_$$.sh"
    echo "#!/bin/bash" > ${iperf_clients_to_run_client_side}
    if [ "$DUPLEX"  = "true" ]
    then
        iperf_clients_to_run_server_side="/tmp/server_cmds_${TIME_STAMP}_$$.sh"
        echo "#!/bin/bash" > ${iperf_clients_to_run_server_side}
        DUPLEX_OFFSET=$NUM_INST
    fi
    local dev_idx=0

    for ((; dev_idx<NUM_DEVS; dev_idx++))
    do
        local OFFSET_S=$((dev_idx*NUM_CORES_PER_DEVICE + NUM_DEVS*NUM_CORES_PER_DEVICE + DUPLEX_OFFSET))
        client_ns_prefix=$(get_command_prefix $((NUM_DEVS+dev_idx)))
        server_ns_prefix=$(get_command_prefix ${dev_idx})
        for i in $(seq 0 $((NUM_INST-1))); do
            sleep 0.1
            index=$((i+OFFSET_S))
            core="${CORES_ARRAY[index]}"
            dev_base_port=$((BASE_TCP_POTR + 10000*dev_idx))
            prt=$((dev_base_port + i ))
            ip_i=${SERVER_IPS[dev_idx]}
            bind_ip_i=${CLIENT_IPS[dev_idx]}
            cmd_arr=("${client_ns_prefix}" "taskset" "-c" "${core}" "iperf3" "-Z" "-N" "-i" "60"
                     "-c" "${ip_i}" "-B" "${bind_ip_i}" "-t" "${TEST_DURATION}" "-p" "${prt}" "-J"
                     "--logfile"
                     "/tmp/iperf3_c_output_${TIME_STAMP}_${dev_base_port}_${i}.log"
                     "&")
            echo "${cmd_arr[*]}" >> ${iperf_clients_to_run_client_side}
            log "Run ${cmd_arr[*]}"
        done
        #If full duplex then create iperf3 clients on server side
        if [ "$DUPLEX"  = true ]
        then
            local OFFSET_C=$((dev_idx*NUM_CORES_PER_DEVICE+ DUPLEX_OFFSET))
            for i in $(seq 0 $((NUM_INST-1)))
            do
                sleep 0.1
                index=$(( i+OFFSET_C ))
                core="${CORES_ARRAY[index]}"
                dev_base_port=$((BASE_TCP_POTR + 1000 + 11000*dev_idx))
                prt=$((dev_base_port + i ))
                ip_i=${CLIENT_IPS[dev_idx]}
                bind_ip_i=${SERVER_IPS[dev_idx]}
                cmd_arr=("${server_ns_prefix}" "taskset" "-c" "${core}" "iperf3" "-Z" "-N" "-i" "60"
                         "-c" "${ip_i}" "-B" "${bind_ip_i}" "-t" "${TEST_DURATION}" "-p" "${prt}"
                         "-J" "--logfile"
                         "/tmp/iperf3_s_output_${TIME_STAMP}_${dev_base_port}_${i}.log"
                         "&")
                echo "${cmd_arr[*]}" >> ${iperf_clients_to_run_server_side}
                log "Run on server side the iperf clients: ${cmd_arr[*]}"
            done
        fi
    done
    #Copy the file to the servers to ensure running all iperf3 clients at the same time
    scp -q ${iperf_clients_to_run_client_side} ${CLIENT_TRUSTED}:${iperf_clients_to_run_client_side}
    if [ "$DUPLEX"  = "true" ]
    then
        scp -q ${iperf_clients_to_run_server_side} ${SERVER_TRUSTED}:${iperf_clients_to_run_server_side}
        ssh ${SERVER_TRUSTED} "sleep 0.01 ; bash ${iperf_clients_to_run_server_side}" &> /dev/null &
    fi
    #Run all iperf clients
    ssh ${CLIENT_TRUSTED} "bash ${iperf_clients_to_run_client_side}" &> /dev/null &
    log "iperf3 clietns start to run, wait for ${TEST_DURATION}sec for the test to finish"
}

ports_device_identifier() {
    # Input: Server name & ports list
    # Output: Displays the PCI bus numbers of the ports.
    local server_name=$1
    shift
    local ports_list=$@
    local -a devices_pci_list=()
    for i in ${ports_list[@]}; do
        cmd="readlink /sys/class/infiniband/${i}/device | awk -F'[/.]' '{print \$(NF-1)}'"
        device_pci=$(ssh "${server_name}" "$cmd")
        devices_pci_list+=("$device_pci")
    done
    echo "${devices_pci_list[@]}"
}

default_qps_optimization() {
    # By default, set 4 QPs per device.
    local server_name=$1
    shift
    local ports_list=$@
    local counter=0
    local -a default_qps_list=()
    devices_pci_list=$(ports_device_identifier "$server_name" "${ports_list[@]}")
    for i in ${devices_pci_list[@]}; do
        counter=$(grep -o $i <<< ${devices_pci_list[*]} | wc -l)
        if [ "$counter" -eq 1 ]; then
            default_qps_list+=(4)
        else
            default_qps_list+=(2)
        fi
    done
    echo "${default_qps_list[@]}"
}

run_perftest_servers() {
    local test_idx=0
    local -a cmd_arr
    local extra_server_args_str
    for ((; test_idx<NUM_TESTS; test_idx++))
    do
        # Map test index to device index (cycle through devices)
        local dev_idx=$((test_idx % NUM_DEVS))
        local device="${SERVER_DEVICES[dev_idx]}"
        
        local OFFSET_S=$((test_idx*NUM_CORES_PER_DEVICE ))
        sleep 0.1
        index=$((OFFSET_S))
        core="${CORES_ARRAY[index]}"
        prt=$((BASE_RDMA_PORT + test_idx ))
        
        # Allocate GPU for this test if CUDA is enabled
        allocate_gpu_for_test "server" $test_idx "$device"
            
        extra_server_args_str="${extra_server_args[*]//%%QPS%%/${server_QPS[dev_idx]}}"
      
        cmd_arr=("sudo" "${cuda_order}" "taskset" "-c" "${core}" "${TEST}" "-d" "$device"
                 "-s" "${message_size}" "-D" "${TEST_DURATION}" "-p" "${prt}" "-F"
                 "${conn_type_cmd[*]}" "${server_cuda}" "${dmabuf}" "${datadirect}" "${null_mr}" "${post_list}" "${extra_server_args_str}")
        ssh "${SERVER_TRUSTED}" "${cmd_arr[*]} >> /dev/null &" &
        log "run ${TEST} server on ${SERVER_TRUSTED#*@}: ${cmd_arr[*]}"
    done
}

run_perftest_clients() {
    local bg_pid="bg_pid"
    local -a cmd_arr=()
    local extra_client_args_str
    local test_idx=0
    [ "${RDMA_UNIDIR}" = true ] && multiplier=1 || multiplier=2
    for ((; test_idx<NUM_TESTS; test_idx++))
    do
        # Map test index to device index (cycle through devices)
        local dev_idx=$((test_idx % NUM_DEVS))
        
        local OFFSET_S=$((test_idx*NUM_CORES_PER_DEVICE + NUM_TESTS*NUM_CORES_PER_DEVICE + DUPLEX_OFFSET))
        sleep 0.1
        index=$((OFFSET_S))
        core="${CORES_ARRAY[index]}"
        dev_base_port=$((BASE_RDMA_PORT + test_idx))
        prt=$((dev_base_port))
        
        # Allocate GPU for this test if CUDA is enabled
        allocate_gpu_for_test "client" $test_idx "${CLIENT_DEVICES[dev_idx]}"
            
        # Map server IP by device index
        ip_i=${SERVER_IPS[dev_idx]}
        extra_client_args_str="${extra_client_args[*]//%%QPS%%/${client_QPS[dev_idx]}}"
        cmd_arr+=("sudo" "${cuda_order}" "taskset" "-c" "${core}" "${TEST}" "-d" "${CLIENT_DEVICES[dev_idx]}"
                 "-D" "${TEST_DURATION}" "${SERVER_TRUSTED#*@}" "-s" "${message_size}" "-p" "${prt}"
                 "-F" "${conn_type_cmd[*]}" "${client_cuda}" "${dmabuf}" "${datadirect}" "${null_mr}" "${post_list}"
                 "${extra_client_args_str}" "--out_json"
                 "--out_json_file=/tmp/perftest_${TEST}_${CLIENT_DEVICES[dev_idx]}_test${test_idx}.json"
                 "&")
    done
    ssh "${CLIENT_TRUSTED}" "${cmd_arr[*]}" & declare ${bg_pid}=$!
    log "run ${TEST} client on ${CLIENT_TRUSTED#*@}: ${cmd_arr[*]}"
    wait "${bg_pid}"
    validate_test_results ${multiplier}
}

# Wrapper function to choose validation strategy based on test configuration
validate_test_results() {
    local multiplier=$1
    
    # Check if we should aggregate results per device (multi-GPU per device)
    if [[ $NUM_TESTS -gt $NUM_DEVS ]] && [[ "${SD}" != true ]]; then
        validate_aggregated_device_results ${multiplier}
    else
        validate_individual_test_results ${multiplier}
    fi
}

# Validate results by aggregating per device (multi-GPU scenarios)
validate_aggregated_device_results() {
    local multiplier=$1
    
    if [ "${bw_test}" = "true" ]
    then
        for ((dev_idx=0; dev_idx<NUM_DEVS; dev_idx++))
        do
            port_rate=$(get_port_rate "${CLIENT_TRUSTED}" "${CLIENT_DEVICES[dev_idx]}")
            BW_PASS_RATE="$(awk "BEGIN {printf \"%.0f\n\", ${multiplier}*0.9*${port_rate}}")"
            total_bw=0
            test_count=0
            
            # Sum bandwidth from all tests on this device
            for ((test_idx=0; test_idx<NUM_TESTS; test_idx++)); do
                if [[ $((test_idx % NUM_DEVS)) -eq $dev_idx ]]; then
                    BW=$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/BW_average/{print \$2}' /tmp/perftest_${TEST}_${CLIENT_DEVICES[dev_idx]}_test${test_idx}.json | cut -d. -f1 | xargs")
                    check_if_number "${BW}" || PASS=false
                    total_bw=$((total_bw + BW))
                    test_count=$((test_count + 1))
                    log "  Test ${test_idx} on device ${CLIENT_DEVICES[dev_idx]}: ${BW} Gb/s"
                fi
            done
            
            log "Device ${CLIENT_DEVICES[dev_idx]} aggregate: ${total_bw} Gb/s from ${test_count} parallel tests (max possible: $((port_rate * multiplier)) Gb/s)"
            if [[ ${total_bw} -lt ${BW_PASS_RATE} ]]
            then
                log "Device ${CLIENT_DEVICES[dev_idx]} didn't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
                PASS=false
            fi
        done
    else
        for ((dev_idx=0; dev_idx<NUM_DEVS; dev_idx++))
        do
            grep -q 'send\|write' <<<"${TEST}" && LAT_PASS_VAL='2.5'
            grep -q 'read' <<<"${TEST}" && LAT_PASS_VAL='4.5'
            min_lat=999999
            test_count=0
            
            # Find minimum latency from all tests on this device
            for ((test_idx=0; test_idx<NUM_TESTS; test_idx++)); do
                if [[ $((test_idx % NUM_DEVS)) -eq $dev_idx ]]; then
                    LAT_VAL="$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/t_avg/{print \$2}' /tmp/perftest_${TEST}_${CLIENT_DEVICES[dev_idx]}_test${test_idx}.json | xargs")"
                    check_if_number "${LAT_VAL}" || PASS=false
                    test_count=$((test_count + 1))
                    log "  Test ${test_idx} on device ${CLIENT_DEVICES[dev_idx]}: ${LAT_VAL} μs"
                    if awk "BEGIN {exit !(${LAT_VAL} < ${min_lat})}"; then
                        min_lat="${LAT_VAL}"
                    fi
                fi
            done
            
            log "Device ${CLIENT_DEVICES[dev_idx]} best latency: ${min_lat} μs from ${test_count} parallel tests"
            if awk "BEGIN {exit !(${min_lat} > ${LAT_PASS_VAL})}"
            then
                log "Device ${CLIENT_DEVICES[dev_idx]} didn't achieve latency of ${LAT_PASS_VAL} μs."
                PASS=false
            fi
        done
    fi
}

# Validate results individually per test (traditional approach)
validate_individual_test_results() {
    local multiplier=$1
    
    if [ "${bw_test}" = "true" ]
    then
        for ((test_idx=0; test_idx<NUM_TESTS; test_idx++))
        do
            dev_idx=$((test_idx % NUM_DEVS))
            port_rate=$(get_port_rate "${CLIENT_TRUSTED}" "${CLIENT_DEVICES[dev_idx]}")
            BW_PASS_RATE="$(awk "BEGIN {printf \"%.0f\n\", ${multiplier}*0.9*${port_rate}}")"
            # Check if the device is using Socket Direct
            if [ "${SD}" = true ]; then
                if (( ${#CLIENT_DEVICES[@]} % 2 == 0 )); then
                    halfway=$((${#CLIENT_DEVICES[@]} / 2))
                    MLNX_DEVICES=(${CLIENT_DEVICES[@]:0:halfway})
                    SD_DEVICES=(${CLIENT_DEVICES[@]:halfway})
                fi
                if [[ "${dev_idx}" -ge "${halfway}" ]]; then
                    break
                else
                    sd_func
                    continue
                fi
            fi
            
            BW=$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/BW_average/{print \$2}' /tmp/perftest_${TEST}_${CLIENT_DEVICES[dev_idx]}_test${test_idx}.json | cut -d. -f1 | xargs")
            check_if_number "${BW}" || PASS=false
            log "Test ${test_idx} on device ${CLIENT_DEVICES[dev_idx]} reached ${BW} Gb/s (max possible: $((port_rate * multiplier)) Gb/s)"
            if [[ ${BW} -lt ${BW_PASS_RATE} ]]
            then
                log "Test ${test_idx} on device ${CLIENT_DEVICES[dev_idx]} didn't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
                PASS=false
            fi
        done
    else
        for ((test_idx=0; test_idx<NUM_TESTS; test_idx++))
        do
            dev_idx=$((test_idx % NUM_DEVS))
            grep -q 'send\|write' <<<"${TEST}" && LAT_PASS_VAL='2.5'
            grep -q 'read' <<<"${TEST}" && LAT_PASS_VAL='4.5'
            LAT_VAL="$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/t_avg/{print \$2}' /tmp/perftest_${TEST}_${CLIENT_DEVICES[dev_idx]}_test${test_idx}.json | xargs")"
            check_if_number "${LAT_VAL}" || PASS=false
            log "Test ${test_idx} on device ${CLIENT_DEVICES[dev_idx]} avg. latency: ${LAT_VAL} μs."
            if awk "BEGIN {exit !(${LAT_VAL} > ${LAT_PASS_VAL})}"
            then
                log "Test ${test_idx} on device ${CLIENT_DEVICES[dev_idx]} didn't achieve latency of ${LAT_PASS_VAL} μs."
                PASS=false
            fi
        done
    fi
}

# Unified GPU allocation function for both server and client tests
allocate_gpu_for_test() {
    local side="$1"       # "server" or "client"
    local test_idx="$2"
    local device="$3"
    local device_idx=$((test_idx % NUM_DEVS))
    
    if [ $RUN_WITH_CUDA ]; then
        # Set side-specific variables using indirect references
        local -n device_allocated_gpus_ref="ALLOCATED_${side^^}_DEVICE_${device_idx}_GPUS"
        local -n cuda_idx_ref="${side}_cuda_idx"                # server_cuda_idx or client_cuda_idx
        local trusted_host_var="${side^^}_TRUSTED"              # SERVER_TRUSTED or CLIENT_TRUSTED
        local trusted_host="${!trusted_host_var}"
        
        # Build exclusion list from previously allocated GPUs (per-device)
        excluded_gpus=$(IFS=,; echo "${device_allocated_gpus_ref[*]}")
        
        # Map test to GPU: use manual specification if provided, otherwise auto-allocate  
        if [ ${#cuda_idx_ref[@]} -gt 0 ]; then
            gpu_idx=$((test_idx % ${#cuda_idx_ref[@]}))
            specified_gpu="${cuda_idx_ref[gpu_idx]}"
        else
            specified_gpu=""
        fi
        
        # Get CUDA index using topology analysis
        CUDA_INDEX=$(get_cudas_per_rdma_device "$trusted_host" "$device" "$specified_gpu" "$excluded_gpus" | cut -d , -f 1)
        
        # Track this allocation per device
        device_allocated_gpus_ref+=("$CUDA_INDEX")
        
        # Set output variables dynamically  
        declare -g "${side}_cuda=--use_cuda=${CUDA_INDEX}"
        declare -g "cuda_order=CUDA_DEVICE_ORDER=PCI_BUS_ID"
        
        log "${side^} test ${test_idx}: device ${device} allocated to GPU ${CUDA_INDEX}"
    fi
}

collect_stats(){
    DURATION=$((TEST_DURATION-3))
    num_cores=$(( ${#CORES_ARRAY[@]}/2 ))
    client_cores_list="$(tr " " "," <<< "${CORES_ARRAY[@]:$num_cores:$num_cores}")"
    server_cores_list="$(tr " " "," <<< "${CORES_ARRAY[@]:0:$num_cores}")"
    ssh ${CLIENT_TRUSTED} "sar -u -P $client_cores_list,all $DURATION 1 | grep \"Average\"  > /tmp/ngc_tcp_core_usages_${TIME_STAMP}.txt" &
    ssh ${SERVER_TRUSTED} "sar -u -P $server_cores_list,all $DURATION 1 | grep \"Average\"  > /tmp/ngc_tcp_core_usages_${TIME_STAMP}.txt" &
}

#param : string of files prefix to sum and return BW.
#files are the output of iperf3 clients
get_bandwidth_from_combined_files(){
    local S=$1
    local tag=$2
    local file_prefix=$3
    local out="/tmp/iperf3_${tag}_${TIME_STAMP}.log"
    ssh ${S} "cat ${file_prefix}*" > ${out}
    throughput_bits=$(cat ${out} | grep sum_sent -A7 | grep bits_per_second | tr "," " " | awk '{ SUM+=$NF } END { print SUM } ')
    #convert to bytes
    BITS=$(printf '%.0f' $throughput_bits)
    throughput_Gbytes=$(bc -l <<< "scale=2; $BITS/1000000000")
    echo ${throughput_Gbytes}
}

collect_BW() {
    local outstr

    totalBW=0
    [ -n "${PASS_CRITERION}" ] || PASS_CRITERION=0.9
    local dev_idx=0
    failed_tcp_test=false
    for ((; dev_idx<NUM_DEVS; dev_idx++))
    do
        prt=$((BASE_TCP_POTR + 10000*dev_idx + i ))
        dev_base_port=$((BASE_TCP_POTR + 10000*dev_idx))
        port_rate=$(get_port_rate "${CLIENT_TRUSTED}" "${CLIENT_DEVICES[dev_idx]}")
        passing_port_rate="$(awk "BEGIN {printf \"%.0f\n\", ${PASS_CRITERION}*${port_rate}}")"
        BW=$(get_bandwidth_from_combined_files ${CLIENT_TRUSTED} "CLIENT" "/tmp/iperf3_c_output_${TIME_STAMP}_${dev_base_port}")
        S_BW=0
        suffix=" - linerate ${port_rate}Gb/s"
        if [ "$DUPLEX"  = false ]
        then
            outstr="Throughput ${CLIENT_TRUSTED#*@}:${CLIENT_DEVICES[dev_idx]} ->  ${SERVER_TRUSTED#*@}:${SERVER_DEVICES[dev_idx]} :  ${BW}Gb/s${suffix}"
            if [ $(echo "$BW < ${passing_port_rate}" | bc) -ne 0 ]
            then
                failed_tcp_test=true
                log "${outstr}" RESULT_FAIL
            else
                log "${outstr}" RESULT_PASS
            fi
        else
            dev_base_port=$((BASE_TCP_POTR + 1000 + 11000*dev_idx))
            S_BW=$(get_bandwidth_from_combined_files ${SERVER_TRUSTED} "SERVER" "/tmp/iperf3_s_output_${TIME_STAMP}_${dev_base_port}")
            outstr="Throughput ${CLIENT_TRUSTED#*@}:${CLIENT_DEVICES[dev_idx]} <->  ${SERVER_TRUSTED#*@}:${SERVER_DEVICES[dev_idx]} :  ${BW}Gb/s <-> ${S_BW}Gb/s${suffix}"
            if [ $(echo "$BW < ${passing_port_rate}" | bc) -ne 0 ] || [ $(echo "$S_BW < ${passing_port_rate}" | bc) -ne 0 ]
            then
                failed_tcp_test=true
                log "${outstr}" RESULT_FAIL
            else
                log "${outstr}" RESULT_PASS
            fi
            #echo "Server side(act as client for full duplex ) ${SERVER_DEVICES[dev_idx]} report throughput of ${S_BW}Gb/s"
            dupBW=$(echo "$S_BW + $BW" | bc)
            echo "Full duplex: ${dupBW}Gb/s"
            totalBW=$(echo "$totalBW + $dupBW" | bc)
        fi
    done
    if [ "$DUPLEX"  = "true" ]
    then
        echo "Total throughput in systems is ${totalBW}Gb/s"
    fi

    if [ $failed_tcp_test = "true" ]
    then
        [[ "$IS_CLIENT_SPR" = "true" ]] && log "Client side has Sapphire Rapid CPU, Make sure BIOS has the following fix : Socket Configuration > IIO Configuration > Socket# Configuration > PE# Restore RO Write Perf > Enabled , if not please re-run with flag --disable_ro" WARNING
        [[ "$IS_SERVER_SPR" = "true" ]] && log "Server side has Sapphire Rapid CPU, Make sure BIOS has the following fix : Socket Configuration > IIO Configuration > Socket# Configuration > PE# Restore RO Write Perf > Enabled , if not please re-run with flag --disable_ro" WARNING
        log "Failed - servers failed ngc_tcp_test with the given HCAs" RESULT_FAIL
        delete_namespaces_from_host ${SERVER_TRUSTED} ${SERVER_DEVICES} ${DEVICES_NS}
        return 1
    else
        log "Passed - servers passed ngc_tcp_test with the given HCAs" RESULT_PASS
        return 0
    fi
}

print_stats(){
    server=$1
    file="/tmp/ngc_tcp_core_usages_${TIME_STAMP}.txt"
    log "Server: ${server#*@}"
    ssh "${server}" "awk '{print \$2 \"\t\" \$5}' $file"
    usages=( $(ssh "${server}" "awk 'NR>1 {print \$5}' $file") )
    total_active_avarage=$(get_average ${usages[@]})
    paste <(echo "${server#*@}: Overall Active: $total_active_avarage") <(echo "Overall All cores: ") <(ssh ${server} "awk 'NR==2 {print \$5}' ${file}")
}

sd_func(){
    BW1=$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/BW_average/{print \$2}' /tmp/perftest_${TEST}_${MLNX_DEVICES[dev_idx]}.json | cut -d. -f1 | xargs")
    BW2=$(ssh "${CLIENT_TRUSTED}" "sudo awk -F'[:,]' '/BW_average/{print \$2}' /tmp/perftest_${TEST}_${SD_DEVICES[dev_idx]}.json | cut -d. -f1 | xargs")
    BW=$((BW1 + BW2))
    log "Device ${MLNX_DEVICES[dev_idx]} & ${SD_DEVICES[dev_idx]} reached ${BW} Gb/s (max possible: $((port_rate * multiplier)) Gb/s)"
    if [[ ${BW} -lt ${BW_PASS_RATE} ]]; then
            log "Device ${MLNX_DEVICES[dev_idx]} & ${SD_DEVICES[dev_idx]} didn't reach pass bw rate of ${BW_PASS_RATE} Gb/s"
            PASS=false
    fi
}
