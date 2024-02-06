#!/bin/bash
set -eE

# Variables
CLIENT_IP=${2}
SERVER_IP=${1}
scriptdir="$(dirname "$0")"
LOGFILE="/tmp/ngc-rdma-test_$(date +%H:%M:%S__%d-%m-%Y).log"
tests="--tests=ib_write_bw,ib_read_bw,ib_send_bw"
source "${scriptdir}/common.sh"


help() {
    local WHITE RESET
    WHITE=$(tput bold)
    RESET=$(tput sgr0)
    cat <<EOF >&2

  Execute ngc_rdma_test.sh for each MLNX device on the hosts.
  * Passwordless SSH access to the participating nodes is required.
  * Passwordless sudo root access is required from the SSH'ing user.
  * Dependencies which need to be installed: numctl, perftest.
  For external loopback, you may edit the pairs according to your connectivity.

  ${WHITE}Usage (b2b connectivity):
  $0 Server Client
  External Loopback connectivity:
  $0 Server${RESET}
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
    else
        use_cuda=""
        echo "NGC RDMA Test (Back2Back) in progress... (CUDA off)" | tee -a "${LOGFILE}"
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

        # Store  the next index in the SERVER_MLNX
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
            "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${MLX}","${MLX2}" "${CLIENT_IP}" "${MLX}","${MLX2}" "${tests}" ${use_cuda} &>> "${LOGFILE}"

        # If the device is Single Port:
        else
            echo -e "${WHITE}Single Port - ${MLX} Located on PCI: ${PCI_DEVICE}${NC}" &>> "${LOGFILE}"
            "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${MLX}" "${CLIENT_IP}" "${MLX}" "${tests}" ${use_cuda} &>> "${LOGFILE}"
        fi
    done
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
    else
        use_cuda=""
        echo "NGC RDMA Test (External Loopback) in progress... (CUDA off)" | tee -a "${LOGFILE}"
    fi

    # Loop through pairs and send to ngc test
    for pair in "${pairs[@]}"; do
        # Seperate the pairs to first and second element
        first="${pair%,*}"
        second="${pair#*,}"
        if [[ "$first" == "1" ]]; then
            echo -e "${WHITE}Dual Port -  1st Card: mlx5_1, mlx5_2 | 2nd Card: mlx5_7, mlx5_8${NC}" &>> "${LOGFILE}"
            "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "mlx5_1","mlx5_2" "${SERVER_IP}" "mlx5_7","mlx5_8" "${tests}" ${use_cuda} &>> "${LOGFILE}"
        # Skip to avoid duplicates of the second port
        elif [[ "$first" == "2" ]]; then
            continue
        # Single Ports
        else
            echo -e "${WHITE}Single Port - mlx5_${first} mlx5_${second}${NC}" &>> "${LOGFILE}"
            "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "mlx5_${first}" "${SERVER_IP}" "mlx5_${second}" "${tests}" ${use_cuda} &>> "${LOGFILE}"
        fi
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
        echo "SSH connection failed for:${failed_hosts}. Exiting.."
        exit 1
    else
        echo "Created log file: ${LOGFILE}"
    fi
}


# If 1 host provided, run external loopback test:
if [[ $# == 1 ]]; then
    check_ssh "${SERVER_IP}"
    # Get MLNX devices (PCIe & RDMA):
    ssh "${SERVER_IP}" dmidecode -t 1 |grep -i serial | awk '{$1=$1};1' | grep -iv '^$' &>> "${LOGFILE}"
    ssh "${SERVER_IP}" dmidecode -t 0 |grep -i version | awk '{$1=$1};1' | sed 's/^/BIOS /' &>> "${LOGFILE}"
    readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" mst status -v  | awk '/mlx/{print $3 " " $4}' | sort -t ' ' -k2,2V)"
    # Without CUDA
    ngc_rdma_test_external_loopback
    # Use CUDA:
    ngc_rdma_test_external_loopback "use_cuda"

# If 2 hosts provided (meaning b2b connectivity):
elif [[ $# == 2 ]]; then
    check_ssh "${SERVER_IP}" "${CLIENT_IP}"
    # Get MLNX devices (PCIe & RDMA):
    ssh "${SERVER_IP}" dmidecode -t 1 |grep -i serial | awk '{$1=$1};1' | grep -iv '^$' &>> "${LOGFILE}"
    ssh "${SERVER_IP}" dmidecode -t 0 |grep -i version | awk '{$1=$1};1' | sed 's/^/BIOS /' &>> "${LOGFILE}"
    readarray -t SERVER_MLNX <<< "$(ssh "${SERVER_IP}" mst status -v  | awk '/mlx/{print $3 " " $4}' | sort -t ' ' -k2,2V)"
    # Without CUDA
    ngc_rdma_test
    wrapper_results
    # Use CUDA
    ngc_rdma_test "use_cuda"
    wrapper_results "cuda"
else
    help
fi
