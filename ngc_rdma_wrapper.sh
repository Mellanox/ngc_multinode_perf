#!/bin/bash
set -eE

# Variables
CLIENT_IP=${2}
SERVER_IP=${1}
WHITE='\033[1;37m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'
scriptdir="$(dirname "$0")"
LOGFILE="/tmp/ngc-rdma-test_$(date +%H:%M:%S__%d-%m-%Y).log"


help() {
    local WHITE RESET
    WHITE=$(tput bold)
    RESET=$(tput sgr0)
    cat <<EOF >&2

  Execute ngc_rdma_test.sh for each MLNX device on the hosts.
  Run as root and make sure the hosts are passwordless, you can use IP / Hostname.
  Note: Do not use splitters for external loopback connectivity!

  ${WHITE}Usage (b2b connectivity):
  $0 Server Client
  For external loopback:
  $0 Server
  For Hiper Servers:
  $0 Server --hiper ${RESET}

EOF
    exit 1
}


# Function to call the ngc_rdma_test.sh for each device on the host(s) - b2b connectivity
ngc_rdma_test() {
    local use_cuda
    local element
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="use_cuda"
        echo "NGC RDMA Test (Back2Back) in progress... (CUDA on)" | tee -a "${LOGFILE}"
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
            "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${MLX}","${MLX2}" "${CLIENT_IP}" "${MLX}","${MLX2}" ${use_cuda} &>> "${LOGFILE}"

        # If the device is Single Port:
        else
            echo -e "${WHITE}Single Port - ${MLX} Located on PCI: ${PCI_DEVICE}${NC}" &>> "${LOGFILE}"
            "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${MLX}" "${CLIENT_IP}" "${MLX}" ${use_cuda} &>> "${LOGFILE}"
        fi
    done
}

# Function to call the ngc_rdma_test.sh for each device on the host(s) - external loopback connectivity
ngc_rdma_test_external_loopback() {
    local use_cuda
    local element
    if [[ "${1}" == "use_cuda" ]]; then
        use_cuda="use_cuda"
        echo "NGC RDMA Test (External Loopback) in progress... (CUDA on)" | tee -a "${LOGFILE}"
    else
        use_cuda=""
        echo "NGC RDMA Test (External Loopback) in progress... (CUDA off)" | tee -a "${LOGFILE}"
    fi

    # Loop and store Cables SN in an array:
    for i in "${!SERVER_MLNX[@]}"; do
        CABLE_SN="$(ssh -q -oStrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SERVER_IP}" mlxlink -d mlx5_$i -m | awk '/Vendor Serial Number/{print $NF}')"
        CABLE_ARRAY+=("$CABLE_SN")
    done > /dev/null 2>&1

    # Save a new array, combined with the CABLE SN and MLNX devices:
    for j in "${!SERVER_MLNX[@]}"; do
        COMBINED_ARRAY+=("${SERVER_MLNX[j]} ${CABLE_ARRAY[j]}")
    done

    # Loop and check for similar Cables' SN, and send it to the script
    for element in "${COMBINED_ARRAY[@]}"; do
        # Skip iteration if one of the devices have already been iterated
        if (( ${#processed_array[@]} != 0 )) &&
            printf '%s\n' "${processed_array[@]}" | grep -q "^\(${another_element}\|${element}\|${dualmlx2}\|${dualmlx}\)\$"; then
            continue
        fi

        # Extract MLX and SN elements
        pcie_element=$(echo "${element}" | awk '{print $1}')
        mlx_element=$(echo "${element}" | awk '{print $2}')
        sn_element="$(echo "${element}" | awk '{print $3}')"
        PCI_PREFIX="${pcie_element%.*}"

        # Skip iteration if mlx was already processed
        if [[ "${mlx_element}" == "${dualmlx}" ]]; then
            continue
        fi

        # Skip iteration if the 3rd element is N/A, meaning the cable is probably disconnected
        if [[ "${sn_element}" == "N/A" ]]; then
            continue
        fi

        # Loop to check for identical SN numbers
        for another_element in "${COMBINED_ARRAY[@]}"; do
            pcie2_element=$(echo "${another_element}" | awk '{print $1}')
            mlx2_element=$(echo "${another_element}" | awk '{print $2}')
            sn2_element="$(echo "${another_element}" | awk '{print $3}')"
            PCI2_PREFIX="${pcie2_element%.*}"

            # If the mlx device is the same, continue to next iteration
            if [[ "${mlx2_element}" == "${mlx_element}" ]]; then
                continue
            fi
            dual_port=false
            # If the SN cable are identical - the devices are connected to each other
            if [[ "${sn2_element}" == "${sn_element}" ]]; then
                # Add the processed element to the array
                processed_array+=("$another_element")

                # Check for Dual Port
                for index in "${!COMBINED_ARRAY[@]}"; do
                    if echo "${COMBINED_ARRAY[index]}" | grep -q "${PCI_PREFIX}.1"; then
                        dual_port_value="${COMBINED_ARRAY[index]}"
                        dual_port=true
                        dualmlx=$(echo "$dual_port_value" | awk '{print $2}')
                        processed_array+=("$dualmlx")
                        break  # Exit the loop since we found a match
                    fi
                done
                for index2 in "${!COMBINED_ARRAY[@]}"; do
                    if echo "${COMBINED_ARRAY[index2]}" | grep -q "${PCI2_PREFIX}.1"; then
                        dual_port_value2="${COMBINED_ARRAY[index2]}"
                        dualmlx2=$(echo "$dual_port_value2" | awk '{print $2}')
                        processed_array+=("$dualmlx2")
                    fi
                done

                # If the device is Dual Port
                if [[ "${dual_port}" == true ]]; then
                    processed_array+=("$another_element")
                    echo -e "${WHITE}Dual Port -  Devices: ${mlx_element} ${dualmlx} PCI: ${pcie_element} | Devices: ${mlx2_element} ${dualmlx2} PCI: ${pcie2_element}${NC}"
                    echo -e "${WHITE}Dual Port -  Devices: ${mlx_element} ${dualmlx} PCI: ${pcie_element} | Devices: ${mlx2_element} ${dualmlx2} PCI: ${pcie2_element}${NC}" &>> "${LOGFILE}"
                    "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${mlx_element}","${dualmlx}" "${SERVER_IP}" "${mlx2_element}","${dualmlx2}" ${use_cuda} &>> "${LOGFILE}"

                # If the device is Single Port:
                else
                    echo -e "${WHITE}Single Port - Device: ${mlx_element} Located on PCI: ${pcie_element}${NC}" &>> "${LOGFILE}"
                    "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "${mlx_element}" "${SERVER_IP}" "${mlx2_element}" ${use_cuda} &>> "${LOGFILE}"

                fi
            fi
        done
    done
}

# Hiper Server Function
ngc_hiper_test() {
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
        use_cuda="use_cuda"
        echo "NGC RDMA Test (Hiper Server) in progress... (CUDA on)" | tee -a "${LOGFILE}"
    else
        use_cuda=""
        echo "NGC RDMA Test (Hiper Server) in progress... (CUDA off)" | tee -a "${LOGFILE}"
    fi

    # Loop through pairs and send to ngc test
    for pair in "${pairs[@]}"; do
        # Seperate the pairs to first and second element
        first="${pair%,*}"
        second="${pair#*,}"
        if [[ "$first" == "1" ]]; then
            echo -e "${WHITE}Dual Port -  1st Port: mlx5_1, mlx5_2 | 2nd Port: mlx5_7, mlx5_8 PCI: ${PCI_DEVICE2}${NC}" &>> "${LOGFILE}"
            "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "mlx5_1","mlx5_2" "${SERVER_IP}" "mlx5_7","mlx5_8" ${use_cuda} &>> "${LOGFILE}"
        # Skip to avoid duplicates of the second port
        elif [[ "$first" == "2" ]]; then
            continue
        # Single Ports
        else
            echo -e "${WHITE}Single Port - mlx5_${first} mlx5_${second}${NC}" &>> "${LOGFILE}"
            "${scriptdir}/ngc_rdma_test.sh" "${SERVER_IP}" "mlx5_${first}" "${SERVER_IP}" "mlx5_${second}" ${use_cuda} &>> "${LOGFILE}"
        fi
    done
}


# Check for SSH connectivity
check_ssh() {
    local failed_hosts=""
    for ip in "$@"; do
        if ! ssh -q -oStrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${ip}" exit; then
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


# Display results function(taken from the logfile)
results() {
  # Read the file line by line
    echo ""
    echo -e "${WHITE}--- Results: ---${NC}"
    echo -e "Without CUDA:"
    local prev_line=""
    while IFS= read -r line; do
        lowercase_line=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        if [[ $lowercase_line == *"passed"* ]]; then
            echo -e "${GREEN}$line${NC}"
        elif [[ $lowercase_line == *"ngc"* && $lowercase_line == *"failed"* ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ $lowercase_line == *"cuda on"* ]]; then
            echo ""
            echo "With CUDA:"
        fi
    done < "${LOGFILE}"
}


# If 1 host provided, run external loopback test:
if [[ $# == 1 ]]; then
    check_ssh "${SERVER_IP}"
    # Get MLNX devices (PCIe & RDMA):
    readarray -t SERVER_MLNX <<< "$(ssh -q -oStrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SERVER_IP}" mst status -v  | awk '/mlx/{print $3 " " $4}' | sort -t ' ' -k2,2V)"
    # Without CUDA
    ngc_rdma_test_external_loopback
    # Use CUDA:
    ngc_rdma_test_external_loopback "use_cuda"

# If 2 hosts provided (meaning b2b connectivity):
elif [[ $# == 2 ]]; then
    # Check if --hiper argument was passed
    if [[ $2 == "--hiper" ]]; then
        check_ssh "${SERVER_IP}"
        ssh "${SERVER_IP}" dmidecode -t 1 |grep -i serial | awk '{$1=$1};1' | grep -iv '^$' &>> "${LOGFILE}"
        ssh "${SERVER_IP}" dmidecode -t 0 |grep -i version | awk '{$1=$1};1' | sed 's/^/BIOS /' &>> "${LOGFILE}"
        # Without CUDA
        ngc_hiper_test
        # With CUDA
        ngc_hiper_test "use_cuda"
        results
        exit 0
    fi
    check_ssh "${SERVER_IP}" "${CLIENT_IP}"
    # Get MLNX devices (PCIe & RDMA):
    readarray -t SERVER_MLNX <<< "$(ssh -q -oStrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SERVER_IP}" mst status -v  | awk '/mlx/{print $3 " " $4}' | sort -t ' ' -k2,2V)"
    # Without CUDA
    ngc_rdma_test
    # Use CUDA
    ngc_rdma_test "use_cuda"
else
    help
fi


# Call the results function
results