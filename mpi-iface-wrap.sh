#!/usr/bin/env bash
#
# Per-rank launch wrapper for the GASNet mpi-conduit (MPICH ch3:sock).
#
# Problem: on multi-homed hosts (docker0/virbr0 bridges, wifi+wired) or hosts whose hostname
# resolves wrong (IPv6-only, or a stale IP), MPICH ch3:sock advertises an unroutable
# business-card address and MPI_Init_thread dies with "No route to host".
#
# Fix: before exec'ing the real program, force this rank to advertise the local IPv4 address
# that is actually part of the job's host list. The launcher exports that list as
# CHPL_MPI_HOSTS (space- or comma-separated). If unset, we fall back to the first non-loopback,
# non-virtual (no 172.16/12, no 192.168.122 libvirt default) IPv4.
#
# mpirun invokes this as:  mpi-iface-wrap.sh <program> [args...]
#
set -eu

pick_ip() {
    local ips
    ips=$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    # 1) prefer an IP that appears in the job host list
    if [[ -n "${CHPL_MPI_HOSTS:-}" ]]; then
        local hosts="${CHPL_MPI_HOSTS//,/ }"
        local ip h
        for ip in $ips; do
            for h in $hosts; do
                [[ "$ip" == "$h" ]] && { echo "$ip"; return; }
            done
        done
    fi
    # 2) fallback: first non-loopback, non-virtual-bridge IPv4
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
