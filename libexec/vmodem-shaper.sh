#!/bin/bash
# TPC-VModem traffic shaper, invoked by PPP ip-up.d and ip-down.d hooks.
# $1: PPP interface, $6: downstream:upstream in bits per second.

iface=$1
ifb="ifb${iface}"

# Only manage PPP interfaces belonging to these hooks.
[[ "$iface" =~ ^ppp[0-9]+$ && ${#ifb} -le 15 ]] || exit 0

case "$0" in
  */ip-up.d/*)
    [[ "$6" =~ ^[0-9]+:[0-9]+$ ]] || exit 0
    IFS=: read -r downstream upstream <<< "$6"
    (( downstream > 0 && upstream > 0 )) || exit 1

    # Shape traffic sent by the Pi towards the retro computer.
    tc qdisc replace dev "$iface" root tbf \
      rate "${downstream}bit" burst 1600b latency 10s || exit 1

    # Shape traffic received from the retro computer via a dedicated IFB.
    modprobe ifb || exit 1
    ip link add "$ifb" type ifb || exit 1
    ip link set "$ifb" up || exit 1
    tc qdisc replace dev "$ifb" root tbf \
      rate "${upstream}bit" burst 1600b latency 10s || exit 1
    tc qdisc add dev "$iface" ingress || exit 1
    tc filter add dev "$iface" ingress protocol all matchall \
      action mirred egress redirect dev "$ifb" || exit 1
    ;;

  */ip-down.d/*)
    tc qdisc del dev "$iface" ingress 2>/dev/null || true
    tc qdisc del dev "$iface" root 2>/dev/null || true
    ip link del "$ifb" 2>/dev/null || true
    ;;
esac