#!/bin/bash

set -eE

api_url="https://api.github.com/repos/Mellanox/ngc_multinode_perf"

kind="${1}"

log() {
    >&2 printf "%s\n" "${*}"
}

fatal() {
    log "ERROR: ${*}"
    exit 1
}

dl() {
    mkdir "ngc_multinode_perf-${ref}"
    curl -Lsf "${tarball_url}" |
        tar -zx -C "ngc_multinode_perf-${ref}" --strip-components=1
}

get_latest_ver() {
    local rc last_ver

    [ "${1}" != "rc" ] || rc='-rc[0-9]\+'
    last_ver="$(curl -Lsf "${api_url}/tags" |
                    jq -r '.[] | [.name, .tarball_url] | @tsv' |
                    grep "^v\([0-9]\+\.\)\{2\}[0-9]\+${rc}[[:space:]]" |
                    sort -V -k1 | tail -n1)"

    [ -n "${last_ver}" ] ||
        fatal "No versions exist, or the API was called too many times."

    ref="${last_ver%%[[:space:]]*}"
    tarball_url="${last_ver##*[[:space:]]}"
}

main() {
    if [ -z "${kind}" ]
    then
        get_latest_ver
        log "Downloading the latest stable..."
    elif [ "${kind}" = "rc" ]
    then
        get_latest_ver "rc"
        log "Experimental version ('${ref}') is being downloaded..."
    else
        fatal "The only accepted (optional) argument is 'rc'."
    fi
    dl
    log "Done. ngc_multinode_perf-${ref} is ready."
}

main
