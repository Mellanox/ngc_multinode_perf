#!/bin/bash
set -eE

# Variables
scriptdir="$(dirname "$0")"
LOGFILE="/tmp/ngc-rdma-test_$(date +%H:%M:%S__%d-%m-%Y).log"
tests="--tests=ib_write_bw,ib_read_bw,ib_send_bw"
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
  A Logfile is created under /tmp/.
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

  Options:
  --vm        # Use this flag when running on a VM
  --aff       # Used with the --vm flag to provide a different NIC<->GPU affinity
  --write     # Run write tests only
  --read      # Run read tests only
  --with_cuda # Run both RDMA and GPUDirect
  --cuda_only # Run only GPUDirect

  ${WHITE}Usage:
  RDMA & GPUDirect:
  $0 Server Client --with_cuda

  External Loopback connectivity (Without GPUDirect):
  $0 Server${RESET}

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
        echo -e "\nNGC RDMA Test (Back2Back) in progress... (CUDA on)" | tee -a "${LOGFILE}"
        echo "With CUDA:"
    else
        if [ "${ONLY_CUDA}" = "true" ]; then
            return
        fi
        use_cuda=""
        echo "NGC RDMA Test (Back2Back) in progress... (CUDA off)" | tee -a "${LOGFILE}"
        echo "Without CUDA:"
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
            echo -e "${WHITE}Dual Port -  1st Port: ${MLX} PCI: ${PCI_DEVICE} | 2nd Port: ${MLX2} PCI: ${PCI_DEVICE2}${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${MLX}","${MLX2}" "${CLIENT_IP}" "${MLX}","${MLX2}" "${tests}" ${use_cuda} &>> "${LOGFILE}" ; then
                echo "${RED}Issue with device ${MLX} <-> ${MLX2}" | tee -a "${LOGFILE}${NC}"
            fi

        # If the device is Single Port:
        else
            echo -e "${WHITE}Single Port - ${MLX} Located on PCI: ${PCI_DEVICE}${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${MLX}" "${CLIENT_IP}" "${MLX}" "${tests}" ${use_cuda} &>> "${LOGFILE}" ; then
                echo "${RED}Issue with device ${MLX} <-> ${MLX}" | tee -a "${LOGFILE}${NC}"
            fi
        fi
        wrapper_results
    done
}


# Internal loopback function for VMs
ngc_rdma_vm_test() {
    local use_cuda
    # Determine the current test being run (CUDA on/off)
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="--use_cuda"
        echo -e "\nNGC BW RDMA Test (Internal Loopback) in progress... (CUDA on)" | tee -a "${LOGFILE}"
        echo "With CUDA:" | tee -a "${LOGFILE}"

        # Loop over the Host devices
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            gpu_index="${GPU_ARR[i]//[!0-9]/}"
            echo -e "${WHITE}=== Devices: ${SERVER_MLNX[i]} <-> ${GPU_ARR[i]} ===${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${tests}" ${use_cuda} --server_cuda="${gpu_index}" --client_cuda="${gpu_index}" "--unidir" &>> "${LOGFILE}" ; then
                echo -e "${RED}Issue with device ${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}${NC}" | tee -a "${LOGFILE}"
            fi
            wrapper_results
        done

    else
        if [ "${ONLY_CUDA}" = "true" ]; then
            return
        fi
        use_cuda=""
        echo "NGC BW RDMA Test (Internal Loopback) in progress... (CUDA off)" | tee -a "${LOGFILE}"
        echo "Without CUDA:" | tee -a "${LOGFILE}"

          # Loop over the Host devices
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            echo -e "${WHITE}=== Device: ${SERVER_MLNX[i]} ===${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${SERVER_IP}" "${SERVER_MLNX[i]}" "${tests}" ${use_cuda} "--unidir" &>> "${LOGFILE}" ; then
                echo -e "${RED}Issue with device ${SERVER_MLNX[i]} <-> ${SERVER_MLNX[i]}${NC}"  | tee -a "${LOGFILE}"
            fi
            wrapper_results
        done
    fi
}



# Function to call the ngc_rdma_test.sh for each device on the host(s) - External loopback connectivity
ngc_rdma_test_external_loopback() {
    local use_cuda
    # Define the pairs using regular arrays
    pairs=(
    "0,6"
    "1,7"
    "2,8"
    "3,9"
    "4,10"
    "5,11"
    )
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="--use_cuda"
        echo "NGC RDMA Test (External Loopback) in progress... (CUDA on)" | tee -a "${LOGFILE}"
        echo "With CUDA:"
    else
        if [ "${ONLY_CUDA}" = "true" ]; then
            return
        fi
        use_cuda=""
        echo "NGC RDMA Test (External Loopback) in progress... (CUDA off)" | tee -a "${LOGFILE}"
        echo "Without CUDA:"
    fi

    # Loop through pairs and send to ngc test
    for pair in "${pairs[@]}"; do
        # Seperate the pairs to first and second element
        first="${pair%,*}"
        second="${pair#*,}"
        if [[ "$first" == "1" ]]; then
            echo -e "${WHITE}Dual Port -  1st Card: mlx5_1, mlx5_2 | 2nd Card: mlx5_7, mlx5_8${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "mlx5_1","mlx5_2" "${SERVER_IP}" "mlx5_7","mlx5_8" "${tests}" ${use_cuda} &>> "${LOGFILE}" ; then
                echo "${RED}Issue with device mlx5_1, mlx5_2 <-> mlx5_7, mlx5_8" | tee -a "${LOGFILE}${NC}"
            fi
        # Skip to avoid duplicates of the second port
        elif [[ "$first" == "2" ]]; then
            continue
        # Single Ports
        else
            echo -e "${WHITE}Single Port - mlx5_${first} mlx5_${second}${NC}" &>> "${LOGFILE}"
            if ! "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "mlx5_${first}" "${SERVER_IP}" "mlx5_${second}" "${tests}" ${use_cuda} &>> "${LOGFILE}" ; then
                echo "${RED}Issue with device mlx5_${first} <-> mlx5_${second}" | tee -a "${LOGFILE}${NC}"
            fi
        fi
        wrapper_results
    done
}


# Determine nic <-> gpu affinity
nic_to_gpu_affinity() {
    # Display NIC & GPU affinity according to file
    if [ -n "${AFFINITY_FILE}" ]; then
        if [ -f "${AFFINITY_FILE}" ]; then
            echo "NIC to GPU affinity according to ${AFFINITY_FILE} file:" | tee -a "${LOGFILE}"
            GPU_LINE=$(grep -ni "gpu" "${AFFINITY_FILE}" | cut -d ':' -f1)
            NIC_LINE=$(grep -ni "mlx" "${AFFINITY_FILE}" | cut -d ':' -f1)
            if [[ -z $NIC_LINE || -z $GPU_LINE ]]; then
                fatal "Error with file ${AFFINITY_FILE}"
            fi
            SERVER_MLNX=($(awk "NR==${NIC_LINE}" "${AFFINITY_FILE}"))
            GPU_ARR=($(awk "NR==${GPU_LINE}" "${AFFINITY_FILE}"))
            for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
                echo "${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}" | tee -a "${LOGFILE}"
            done
        else
            echo "Error with file ${AFFINITY_FILE}."
            exit 1
        fi
    else
        # Display default NIC & GPU affinity
        # Find CUDA & RDMA devices
        readarray -t GPU_ARR <<< "$(ssh "${SERVER_IP}" nvidia-smi -L | awk '{print $1 $2}' | tr -d ':')" ||
        fatal "Couldn't get CUDA devices"
        readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" ibdev2netdev  | awk '{print $1}')"  ||
        fatal "Couldn't get NICs from ibdev2netdev"
        echo "NIC to GPU affinity:" | tee -a "${LOGFILE}"
        for ((i=0; i<${#SERVER_MLNX[@]}; i++)); do
            echo "${SERVER_MLNX[i]} <-> ${GPU_ARR[i]}" | tee -a "${LOGFILE}"
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
            echo "Please provide affinity file (see README)"
            exit 0
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
        log "Created log file: ${LOGFILE}"
    fi
}


# If 1 host provided, run external loopback test:
if [[ $# == 1 ]]; then
    check_ssh "${SERVER_IP}"
    echo "=== Server: ${SERVER_IP} ===" > "${LOGFILE}"
    ssh "${SERVER_IP}" sudo dmidecode -t 0,1 &>> "${LOGFILE}"

    # Without CUDA
    ngc_rdma_test_external_loopback
    # Use CUDA:
    ngc_rdma_test_external_loopback "use_cuda"

# If 2 hosts provided (meaning b2b connectivity):
elif [[ $# == 2 ]]; then
    check_ssh "${SERVER_IP}" "${CLIENT_IP}"
    echo "=== Server: ${SERVER_IP} ===" > "${LOGFILE}"
    ssh "${SERVER_IP}" sudo dmidecode -t 0,1 &>> "${LOGFILE}"
    echo "=== Client: ${CLIENT_IP} ===" >> "${LOGFILE}"
    ssh "${CLIENT_IP}" sudo dmidecode -t 0,1 &>> "${LOGFILE}"

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
