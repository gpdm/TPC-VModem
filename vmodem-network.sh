#!/usr/bin/env bash
#
# TPC-VModem - shared network configuration
#
# License: Creative Commons Attribution-NonCommercial-ShareAlike 4.0
# https://creativecommons.org/licenses/by-nc-sa/4.0/
#
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# this function evalutes the default route
# and returns the matching interface as a
# default for our firewall rules
get_default_interface() {
    local default_interface
    default_interface="$(ip -4 route get 1.1.1.1 | awk '{
        for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }
    }')"
    [[ -n "$default_interface" ]] || fail 'Could not determine outgoing IPv4 interface.'
    printf '%s\n' "$default_interface"
}

start_network() {
    local default_interface
    default_interface="$(get_default_interface)"

    # enable IP forwarding for the network interface
    sysctl -q net.ipv4.ip_forward=1

    # check rules don't exist before adding them
    iptables -t nat -C POSTROUTING -o "$default_interface" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -o "$default_interface" -j MASQUERADE
    iptables -C FORWARD -i ppp+ -o "$default_interface" -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -i ppp+ -o "$default_interface" -j ACCEPT
    iptables -C FORWARD -i "$default_interface" -o ppp+ \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -i "$default_interface" -o ppp+ \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

stop_network() {
    local default_interface
    default_interface="$(get_default_interface)"

    # remove iptables rules for the network interface
    iptables -t nat -C POSTROUTING -o "$default_interface" -j MASQUERADE 2>/dev/null &&
        iptables -t nat -D POSTROUTING -o "$default_interface" -j MASQUERADE
    iptables -C FORWARD -i ppp+ -o "$default_interface" -j ACCEPT 2>/dev/null &&
        iptables -D FORWARD -i ppp+ -o "$default_interface" -j ACCEPT
    iptables -C FORWARD -i "$default_interface" -o ppp+ \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null &&
        iptables -D FORWARD -i "$default_interface" -o ppp+ \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    
    # disable IP forwarding for the network interface
    sysctl -q net.ipv4.ip_forward=0
}

case "${1:-}" in
    start) start_network ;;
    stop) stop_network ;;
    *) fail "Usage: $0 {start|stop}" ;;
esac
