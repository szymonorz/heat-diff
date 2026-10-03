#!/usr/bin/env bash
set -eu

pick_ip() {
    local ips
    ips=$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    if [[ -n "${CHPL_MPI_HOSTS:-}" ]]; then
        local hosts="${CHPL_MPI_HOSTS//,/ }"
        local ip h
        for ip in $ips; do
            for h in $hosts; do
                [[ "$ip" == "$h" ]] && { echo "$ip"; return; }
            done
        done
    fi
    local ip
    for ip in $ips; do
        case "$ip" in
            127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.122.*) continue ;;
            *) echo "$ip"; return ;;
        esac
    done
}

ip="$(pick_ip || true)"
if [[ -n "${ip:-}" ]]; then
    export MPICH_INTERFACE_HOSTNAME="$ip"
fi

exec "$@"
