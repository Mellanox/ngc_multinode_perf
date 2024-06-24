#!/bin/bash
# NGC Certification TCP test v2.3
# Owner: amira@nvidia.com
#
set -eE
trap 'printf "Error in function %s, on line %d.\n" "${FUNCNAME[1]}" "${BASH_LINENO[0]}"' ERR

if (($# < 4)); then
    echo "usage: $0 [<client username>@]<client trusted ip> <client ib device>[,client ib device2] [<server username>@]<server trusted ip> <server ib device>[,server ib device2] [--duplex=<'HALF','FULL'>] [--change_mtu=<'CHANGE','DONT_CHANGE'>] [--duration=<sec>] [--max_proc=<number>]"
    echo "		   duplex - options: HALF,FULL, default: HALF"
    echo "		   change_mtu - options: CHANGE,DONT_CHANGE, default: CHANGE"
    echo "		   duration - time in seconds, default: 120"
    echo "		   max_proc - use up to max_proc of process for each port"
    echo "		   disable_ro - add this flag as workaround for Sapphire Rapid CPU that missing/disabled the following tuning in BIOS (Socket Configuration > IIO Configuration > Socket# Configuration > PE# Restore RO Write Perf > Enabled)"
    echo "		                You will need to restart the driver and re run again"
    echo "		   allow_core_zero - allow binding process on core 0, default:false"
    echo "		   neighbor_levels - in case there is no enough cores on NIC numa, specify the number of closet neighbor numa to collect cores form it, default:2"
    echo "		   --ipsec: Enable IPsec packet offload (full-offload) on the Arm cores."
    exit 1
fi
scriptdir="$(dirname "$0")"
source "${scriptdir}/common.sh"
source "${scriptdir}/ipsec_full_offload_setup.sh"

while [ $# -gt 0 ]
do
    case "${1}" in
        --duplex=*)
            DUPLEX="${1#*=}"
            shift
            ;;
        --change_mtu=*)
            CHANGE_MTU="${1#*=}"
            shift
            ;;
        --duration=*)
            TEST_DURATION="${1#*=}"
            shift
            ;;
        --max_proc=*)
            MAX_PROC="${1#*=}"
            shift
            ;;
        --disable_ro)
            DISABLE_RO=true
            shift
            ;;
        --allow_core_zero)
            ALLOW_CORE_ZERO=true
            shift
            ;;
        --neighbor_levels=*)
            NEIGHBOR_LEVELS="${1#*=}"
            shift
            ;;
        --ipsec)
            IPSEC=true
            shift
            ;;
        --*)
            fatal "Unknown option ${1}"
            ;;
        *)
            POSITIONAL_ARGS+=("${1}")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

CLIENT_TRUSTED="${1}"
CLIENT_DEVICES=(${2//,/ })
SERVER_TRUSTED="${3}"
SERVER_DEVICES=(${4//,/ })
IS_CLIENT_SPR=false
IS_SERVER_SPR=false


[[ "$DUPLEX" == "FULL" ]] && DUPLEX=true || DUPLEX=false
[ -n "${CHANGE_MTU}" ] || CHANGE_MTU="CHANGE"
[ -n "${DISABLE_RO}" ] || DISABLE_RO=false
[ -n "${TEST_DURATION}" ] || TEST_DURATION="120"
[ -n "${MAX_PROC}" ] || MAX_PROC="32"
[ -n "${ALLOW_CORE_ZERO}" ] || ALLOW_CORE_ZERO=false
[ -n "${NEIGHBOR_LEVELS}" ] || NEIGHBOR_LEVELS=1


CLIENT_CORE_USAGES_FILE="/tmp/ngc_client_core_usages.log"
SERVER_CORE_USAGES_FILE="/tmp/ngc_server_core_usages.log"

if [ "$DISABLE_RO" = true ]
then
    log "Apply WA for Sapphire system - please apply the following tuning in BIOS - Socket Configuration > IIO Configuration > Socket# Configuration > PE# Restore RO Write Perf > Enabled instead of using this WA" WARNING
    sleep 2
fi

if [ "${#SERVER_DEVICES[@]}" -ne "${#CLIENT_DEVICES[@]}" ]
then
    fatal "The number of server and client devices must be equal."
fi
NUM_DEVS=${#SERVER_DEVICES[@]}

case "${DUPLEX}" in
    "true")
        (( MAX_PROC > (NUM_DEVS * 2 + 1) )) || fatal "max_proc is set too low."
        ;;
    "false")
        (( MAX_PROC > (NUM_DEVS + 1) )) || fatal "max_proc is set too low."
        ;;
esac

#init the arrays SERVER_IPS,CLIENT_IPS,SERVER_NETDEVS,CLIENT_NETDEVS
get_ips_and_ifs

[ -n "${IPSEC}" ] || IPSEC=false
if [ "$IPSEC" = true ]
then
    LOCAL_BF=(${5//,/ })
    LOCAL_BF_device=(${6//,/ })
    REMOTE_BF=(${7//,/ })
    REMOTE_BF_device=(${8//,/ })
    CHANGE_MTU=DONT_CHANGE
    NUM_BF_DEVS=${#LOCAL_BF[@]}
    PASS_CRITERION=0.85
#---------------------Configure IPsec full offload--------------------
    if [ -z "${MTU_SIZE}" ]; then
        for dev in "${CLIENT_DEVICES[@]}"
        do
            echo "$dev"
            net_name="$(ssh "${CLIENT_TRUSTED}" "ls -1 /sys/class/infiniband/${dev}/device/net/ | head -1")"
            mtu_sizes+=("$(ssh "${CLIENT_TRUSTED}" "ip a show ${net_name} | awk '/mtu/{print \$5}'")")
            echo "$mtu_sizes"
        done
        MTU_SIZE="$(get_min_val ${mtu_sizes[@]})"
        echo "MTU_SIZE"
        echo "$MTU_SIZE"
    fi

    index=0
    for ((; index<NUM_BF_DEVS; index++))
    do
        # IPsec full-offload configuration flow:
        update_mlnx_bf_conf ${LOCAL_BF[index]}
        update_mlnx_bf_conf ${REMOTE_BF[index]}
        generate_next_ip # Generate local_IP & remote_IP
        set_mtu ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} $(( MTU_SIZE + 400 ))
        set_ip ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} "${local_IP}/24" ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} "${remote_IP}/24"
        in_key=$(generete_key)
        out_key=$(generete_key)
        in_reqid=$(generete_req)
        out_reqid=$(generete_req)
        set_representor ${LOCAL_BF_device[index]} ${REMOTE_BF_device[index]}
        set_ipsec_rules ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} "${local_IP}" "${remote_IP}" ${in_key} ${out_key} ${in_reqid} ${out_reqid} "offload packet"
        set_ipsec_rules ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} "${remote_IP}" "${local_IP}" ${out_key} ${in_key} ${out_reqid} ${in_reqid} "offload packet"
        ovs_configure ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${representor1} "${local_IP}" "${remote_IP}" "${index}"
        ovs_configure ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} ${representor2} "${remote_IP}" "${local_IP}" "${index}"
    done
    for ((index1=0; index1<NUM_DEVS; index1++))
    do 
        set_ip ${CLIENT_TRUSTED} ${CLIENT_NETDEVS[index1]} "${CLIENT_IPS[index1]}/${CLIENT_IPS_MASK[index1]}" ${SERVER_TRUSTED} ${SERVER_NETDEVS[index1]} "${SERVER_IPS[index1]}/${SERVER_IPS_MASK[index1]}"
    done
fi
LINK_TYPE="$(ssh "${CLIENT_TRUSTED}" "cat /sys/class/net/${CLIENT_NETDEVS[0]}/type")"
[ $CHANGE_MTU = "CHANGE" ] && change_mtu
min_l=$(get_min_channels)
opt_proc=$((min_l<MAX_PROC ? min_l : MAX_PROC))

#try collect 2 more cores than needed incase we need to ditch core 0 (this is why we need opt_proc+2)
read -ra CORES_ARRAY <<< $(get_cores_for_devices $1 $2 $3 $4 $((opt_proc+2)))
#NUM_CORES_PER_DEVICE will be the actual cores that need to be used
NUM_CORES_PER_DEVICE=$(( ${#CORES_ARRAY[@]}/(${#CLIENT_DEVICES[@]}*2) ))
log "Number of cores per device to be used is $NUM_CORES_PER_DEVICE, if duplex then half of them will act as servers and half as clients."

log "${CORES_ARRAY[*]}"

if [ "$DUPLEX" = true ]
then
    log "Running Full duplex."
    NUM_INST=$((NUM_CORES_PER_DEVICE/2))
else
    log "Running half duplex."
    NUM_INST=${NUM_CORES_PER_DEVICE}
fi

BASE_TCP_POTR=10000

FORCE_EXIT=false
#Set number of cores to use and apply tuning according to #core and list of cores
#Expected global params :
#CLIENT_TRUSTED,CLIENT_DEVICES,SERVER_TRUSTED,SERVER_DEVICES,NUM_INST,opt_proc,CORES_ARRAY
tune_tcp
#Relaxed ordring was disabled - user need to restart the driver so that the change take affect.
[ "${FORCE_EXIT}" != "true" ] || fatal "Please restart driver after disabling relaxed ordering (RO), and run the script again."

TIME_STAMP=$(date +%s)
#Run server side
run_iperf_servers
sleep 2
#Run client side
run_iperf_clients

#Post traffic -collect stats
collect_stats

#wait for traffic to finish
wait
sleep 1
#Print statistics
print_stats $SERVER_TRUSTED
print_stats $CLIENT_TRUSTED

#Collect the output
collect_BW
#---------------------Revert IPsec full offload configuration--------------------
if [ "$IPSEC" = true ]
then
    index=0
    for ((; index<NUM_BF_DEVS; index++))
    do

        # IPsec full-offload configuration *flush* flow:
        set_representor ${LOCAL_BF_device[index]} ${REMOTE_BF_device[index]}
        ovs_configure_revert ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${representor1} "${index}"
        ovs_configure_revert ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} ${representor2} "${index}"
        remove_ipsec_rules ${LOCAL_BF[index]}
        remove_ipsec_rules ${REMOTE_BF[index]}
        flush_ip ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${REMOTE_BF[index]} ${REMOTE_BF_device[index]}
        set_mtu ${LOCAL_BF[index]} ${LOCAL_BF_device[index]} ${REMOTE_BF[index]} ${REMOTE_BF_device[index]} ${MTU_SIZE}
        update_mlnx_bf_conf_revert ${LOCAL_BF[index]}
        update_mlnx_bf_conf_revert ${REMOTE_BF[index]}
        for ((index1=0; index1<NUM_DEVS; index1++))
        do 
            set_ip ${CLIENT_TRUSTED} ${CLIENT_NETDEVS[index1]} "${CLIENT_IPS[index1]}/${CLIENT_IPS_MASK[index1]}" ${SERVER_TRUSTED} ${SERVER_NETDEVS[index1]} "${SERVER_IPS[index1]}/${SERVER_IPS_MASK[index1]}"
        done
    done
fi
