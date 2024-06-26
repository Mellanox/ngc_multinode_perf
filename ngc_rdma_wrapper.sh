#!/bin/bash
set -eE

# Variables
scriptdir="$(dirname "$0")"
tests="--tests=ib_write_bw,ib_read_bw,ib_send_bw"
CURRENT_DATE=$(date +'%F %H:%M:%S')
source "${scriptdir}/common.sh"

# Parse command line options
while [ $# -gt 0 ]; do
    case "${1}" in
        --vm)
            RUN_AS_VM=true
            shift
            ;;
        --aff)
            if [ -f "${2}" ]; then
                AFFINITY_FILE="${2}"
                RUN_AS_VM=true
                shift 2
            else
                fatal "--aff parameter requires a file"
            fi
            ;;
        --with_cuda)
            RUN_WITH_CUDA=true
            shift
            ;;
        --cuda_only)
            ONLY_CUDA=true
            RUN_WITH_CUDA=true
            shift
            ;;
        --write)
            tests="--tests=ib_write_bw"
            shift
            ;;
        --read)
            tests="--tests=ib_read_bw"
            shift
            ;;
        --pairs)
            PAIRS_FILE="${2}"
            shift 2
            ;;
        -h|--help)
            help
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
CLIENT_IP=${2}
SERVER_IP=${1}


# Check if --aff is provided without --with_cuda or --cuda_only
if [ -n "${AFFINITY_FILE}" ] && [ -z "${RUN_WITH_CUDA}" ] && [ -z "${ONLY_CUDA}" ]; then
    fatal "If --aff is provided, either --with_cuda or --cuda_only must also be provided."
fi


help() {
    local WHITE RESET
    WHITE=$(tput bold)
    RESET=$(tput sgr0)
    cat <<EOF >&2
  Wrapper for ngc_rdma_test.sh for each MLNX device on the host.
  For debugging, you can see results and other information using: journalctl --since "${CURRENT_DATE}" -t ngc_multinode_perf.
  Criteria for Pass/Fail - 90% line rate of the port speed.
  For external loopback, you may edit the pairs according to your connectivity.

  * Passwordless SSH access to the participating nodes is required.
  * Passwordless sudo root access is required from the SSH'ing user.
  * Dependencies which need to be installed: numctl, perftest.

  * For Virtual Machines, you can change the NIC<->GPU affinity by
  providing the affinity in a file.
  The file should consist two lines, one for GPUs and the other for NICs.
  Example:
  echo "mlx5_0 mlx5_1 mlx5_2 mlx5_3 mlx5_4 mlx5_5 mlx5_6 mlx5_7" > gpuaff.txt
  echo "GPU6 GPU3 GPU1 GPU7 GPU4 GPU2 GPU0 GPU5" >> gpuaff.txt

  * For External Loopback, you need to provide the pairs in a file.
  Example:
  echo "mlx5_0 mlx5_1 mlx5_2,mlx5_3 mlx5_4,mlx5_5 mlx5_6 mlx5_7 mlx5_8,mlx5_9 mlx5_10,mlx5_11" > pairs.txt
  Coma separated devices are indication for dual port devices.

  Options:
  --vm        # Use this flag when running on a VM
  --aff       # Used with the --vm flag to provide a different NIC<->GPU affinity
  --write     # Run write tests only
  --read      # Run read tests only
  --with_cuda # Run both RDMA and GPUDirect
  --cuda_only # Run only GPUDirect
  --pairs     # Pairs file used for External Loopback

  ${WHITE}Usage:
  RDMA & GPUDirect:
  $0 Server Client --with_cuda

  External Loopback connectivity (Without GPUDirect):
  $0 Server --pairs \$FILE

  Hosts with different NIC<->GPU affinity:
  $0 Server Client --vm --aff \$FILE --with_cuda${RESET}
EOF
    exit 1
}


# Function to call the ngc_rdma_test.sh for each device on the host(s) - b2b connectivity
ngc_rdma_test() {
    local use_cuda
    local element
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="--use_cuda"
        log "NGC RDMA Test (Back2Back) in progress... (CUDA on)"
    else
        if [ "${ONLY_CUDA}" = "true" ]; then
            return
        fi
        use_cuda=""
        log "NGC RDMA Test (Back2Back) in progress... (CUDA off)"
    fi

    # Loop over the Host devices
    for i in "${!SERVER_MLNX[@]}"; do
        # Store the current element's value in a variable
        element="${SERVER_MLNX[i]}"

        # Seperate the element to PCI_DEVICE and MLX
        PCI_DEVICE="$(echo "${element}" | cut -d ' ' -f 1)"
        MLX="$(echo "${element}" | cut -d ' ' -f 2)"

        # If the current element ends in .1, skip to next iteration
        [[ "${PCI_DEVICE}" != *.1 ]] || continue

        # Store PCI Prefix & Set dual_port to false
        PCI_PREFIX="${element%.*}"
        dual_port=false

        # Loop and check if the current device is Dual Port
        for device in "${SERVER_MLNX[@]}"; do
            if [[ "${device}" == "${PCI_PREFIX}"*".1 "* ]]; then
                dual_port=true
                break
            fi
        done

        # Store the next index in the SERVER_MLNX
        next_index=$((i + 1))
        # Determine whether there is another element in the SERVER_MLNX to skip to
        if [ "${next_index}" -lt "${#SERVER_MLNX[@]}" ]; then
            # Store the next element's value in a variable
            next_element="${SERVER_MLNX[next_index]}"
            PCI_DEVICE2="$(echo "${next_element}" | cut -d ' ' -f 1)"
            MLX2="$(echo "${next_element}" | cut -d ' ' -f 2)"
            i="${next_index}"  # Skip the next element
        fi

        # If the device is Dual Port
        if [[ $dual_port == true ]]; then
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${MLX}","${MLX2}" "${CLIENT_IP}" "${MLX}","${MLX2}" "${tests}" ${use_cuda} 2> /dev/null | sed -n '/RESULT_\(PASS\|FAIL\):/p' ; then
                log "Issue with device ${MLX} <-> ${MLX2}" WARNING
            fi

        # If the device is Single Port:
        else
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${MLX}" "${CLIENT_IP}" "${MLX}" "${tests}" ${use_cuda} 2> /dev/null | sed -n '/RESULT_\(PASS\|FAIL\):/p' ; then
                log "Issue with device ${MLX} <-> ${MLX}" WARNING
            fi
        fi
    done
}


# ngc_rdma_test with different affinity (for VMs mostly)
ngc_rdma_vm_test() {
    local use_cuda
    # Determine the current test being run (CUDA on/off)
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="--use_cuda"
        log "NGC BW RDMA Test in progress... (CUDA on)"

        # Loop over the Host devices
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            gpu_index="${GPU_ARR[i]//[!0-9]/}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${CLIENT_IP}" "${SERVER_MLNX[i]}" "${tests}" ${use_cuda} --server_cuda="${gpu_index}" --client_cuda="${gpu_index}" 2> /dev/null | sed -n '/RESULT_\(PASS\|FAIL\):/p' ; then
                log "Issue with device ${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}${NC}" WARNING
            fi
        done

    else
        if [ "${ONLY_CUDA}" = "true" ]; then
            return
        fi
        use_cuda=""
        log "NGC BW RDMA Test in progress... (CUDA off)"

          # Loop over the Host devices
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${CLIENT_IP}" "${SERVER_MLNX[i]}" "${tests}" ${use_cuda} 2> /dev/null | sed -n '/RESULT_\(PASS\|FAIL\):/p' ; then
                log "Issue with device ${SERVER_MLNX[i]} <-> ${SERVER_MLNX[i]}${NC}" WARNING
            fi
        done
    fi
}


# Function to call the ngc_rdma_test.sh for each device on the host(s) - External loopback connectivity
ngc_rdma_test_external_loopback() {
    local use_cuda
    # Define the pairs using regular arrays
    elements=($(cat "${PAIRS_FILE}"))
    # Ask the user to confirm
    echo "== Interface Pairs: =="
    for ((i = 0; i < ${#elements[@]}; i += 2)); do
    echo "${elements[i]} <-> ${elements[i + 1]}"
    done
    # Ask the user to confirm
    tries=0
    while true; do
        read -r -p "Are the pairs correct? [yY]/[nN]: " user_confirm
        case "${user_confirm}" in
        [yY])
            break
            ;;
        [nN])
            fatal "Please provide the pairs in a file (see README)"
            ;;
        *)
            tries=$(( tries + 1 ))
            if (( tries == 3 )); then
                fatal "Reached maximum attempts. Exiting.."
            fi
            ;;
        esac
    done

    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="--use_cuda"
        log "NGC RDMA Test (External Loopback) in progress... (CUDA on)"
    else
        if [ "${ONLY_CUDA}" = "true" ]; then
            return
        fi
        use_cuda=""
        log "NGC RDMA Test (External Loopback) in progress... (CUDA off)"
    fi

    for ((i = 0; i < ${#elements[@]}; i += 2)); do
        if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${elements[i]}" "${SERVER_IP}" "${elements[i + 1]}" "${tests}" ${use_cuda} 2> /dev/null | sed -n '/RESULT_\(PASS\|FAIL\):/p' ; then
            log "Issue with device ${elements[i]} <-> ${elements[i + 1]}" WARNING
        fi
    done
}


# Determine nic <-> gpu affinity
nic_to_gpu_affinity() {
    # Display NIC & GPU affinity according to file
    if [ -n "${AFFINITY_FILE}" ]; then
        if [ -f "${AFFINITY_FILE}" ]; then
            echo "NIC to GPU affinity according to ${AFFINITY_FILE} file:"
            GPU_LINE=$(grep -ni "gpu" "${AFFINITY_FILE}" | cut -d ':' -f1)
            NIC_LINE=$(grep -ni "mlx" "${AFFINITY_FILE}" | cut -d ':' -f1)
            if [[ -z $NIC_LINE || -z $GPU_LINE ]]; then
                fatal "Error with file ${AFFINITY_FILE}"
            fi
            SERVER_MLNX=($(awk "NR==${NIC_LINE}" "${AFFINITY_FILE}"))
            GPU_ARR=($(awk "NR==${GPU_LINE}" "${AFFINITY_FILE}"))
            for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
                echo "${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}"
            done
        else
            fatal "Error with file ${AFFINITY_FILE}."
        fi
    else
        # Display default NIC & GPU affinity
        # Find CUDA & RDMA devices
        readarray -t GPU_ARR <<< "$(ssh "${SERVER_IP}" nvidia-smi -L | awk '{print $1 $2}' | tr -d ':')" ||
        fatal "Couldn't get CUDA devices"
        readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" ibdev2netdev  | awk '{print $1}')"  ||
        fatal "Couldn't get NICs from ibdev2netdev"
        echo "NIC to GPU affinity:"
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            echo "${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}"
        done
    fi

    # Ask the user to confirm
    tries=0
    while true; do
        read -r -p "Is the affinity correct? [yY]/[nN]: " user_confirm
        case "${user_confirm}" in
        [yY])
            break
            ;;
        [nN])
            fatal "Please provide affinity file (see README)"
            ;;
        *)
            tries=$(( tries + 1 ))
            if (( tries == 3 )); then
                fatal "Reached maximum attempts. Exiting.."
            fi
            ;;
        esac
    done
}


# Check for SSH connectivity
check_ssh() {
    local failed_hosts=""
    for ip in "$@"; do
        if ! ssh "${ip}" exit; then
            failed_hosts+=" ${ip}"
        fi
    done
    if [[ -n "${failed_hosts}" ]]; then
        fatal "SSH connection failed for:${failed_hosts}."
    else
        log "For debugging, please use: journalctl --since \"${CURRENT_DATE}\" -t ngc_multinode_perf"
    fi
}


# If 1 host provided, run external loopback test:
if [[ $# == 1 ]]; then
    if [ ! -f "${PAIRS_FILE}" ]; then
        fatal "For External Loopback, please provide pairs file."
    fi
    { (( $(wc -l "${PAIRS_FILE}" | cut -d' ' -f1) == 1 )) &&
        grep -q '^\(mlx5_[0-9]\+\(,mlx5_[0-9]\+\)\?\([[:space:]]\|$\)\)\+$' "${PAIRS_FILE}"
    } || fatal "Verify that ${PAIRS_FILE} is formatted correctly."
    check_ssh "${SERVER_IP}"

    # Without CUDA
    ngc_rdma_test_external_loopback
    # Use CUDA:
    if [ "${RUN_WITH_CUDA}" = "true" ]; then
        ngc_rdma_test_external_loopback "use_cuda"
    fi

# If 2 hosts provided (meaning b2b connectivity):
elif [[ $# == 2 ]]; then
    check_ssh "${SERVER_IP}" "${CLIENT_IP}"

    # Determine if running as VM
    if [ "${RUN_AS_VM}" = "true" ]; then
       # Check GPU affinity if cuda is required
        if [ "${RUN_WITH_CUDA}" ]; then
            nic_to_gpu_affinity
        else
            # Get MLNX devices
            readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" ibdev2netdev | awk '{print $1}')" ||
            fatal "Couldn't get NICs from ibdev2netdev"
        fi
        # VM b2b without CUDA
        ngc_rdma_vm_test
        # VM b2b with CUDA
        if [ "${RUN_WITH_CUDA}" = "true" ]; then
            ngc_rdma_vm_test "use_cuda"
        fi
    else
        # Get MLNX devices (PCIe & RDMA):
        readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" "sudo mst status -v"  | awk '/mlx/{print $3 " " $4}' | sort -t ' ' -k2,2V)" ||
            fatal "Couldn't get NICs from mst status -v"
        # b2b Without CUDA
        ngc_rdma_test
        # b2b With CUDA
        if [ "${RUN_WITH_CUDA}" = "true" ]; then
            ngc_rdma_test "use_cuda"
        fi
    fi
else
    help
fi
