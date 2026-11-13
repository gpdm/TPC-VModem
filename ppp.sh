#!/bin/bash
#
# TPC-VModem - PPP connection handler
#
# Original VMODEM implementation by Oliver Molini (2021)
# Original contributions:
#   Billy Stoughton II - Bug fixes and contributions
#
# TPC-VModem modifications and extensions:
#   Gianpaolo Del Matto (THE PHINTAGE COLLECTOR), 2026
#
# Original project:
# https://www.steptail.com/guides:virtual_modem
#
# License: Creative Commons Attribution-NonCommercial-ShareAlike 4.0
# https://creativecommons.org/licenses/by-nc-sa/4.0/
#
# Note on PPPD settings:
# - Make sure the noauth option is set (instead of auth)
# - Make sure DNS servers are defined (add ms-dns 1.2.3.4 twice)
#

# PPP record stream
# pppd writes its live serial record stream into this FIFO. The noise
# reader must keep draining the FIFO for the whole PPP session, even
# after it has stopped generating sound.
recordfifo="/run/tpc-vmodem-ppp-$$.fifo"
noisereader="./ppp_noise.py"
noisereader_pid=
pppd_pid=
monitor_pid=

# CNI host-local assigns one remote IP per PPP session.
ipam_config="/opt/vmodem/ipam.json"
ipam_binary="/usr/lib/cni/host-local"
ipam_reserved=0


# Function: ipam_command
# Executes the CNI host-local IPAM plugin with the specified command (ADD or DEL).
# Sets up the necessary environment variables for the plugin to operate.
#
ipam_command () {
  CNI_COMMAND="$1" \
  CNI_CONTAINERID="vmodem-$$" \
  CNI_NETNS=/dev/null \
  CNI_IFNAME=vmodem0 \
  CNI_PATH=/usr/lib/cni \
    "$ipam_binary" < "$ipam_config"
}

# Function: exit_handler
# Cleans up the PPP record FIFO and releases the CNI IP reservation on exit.
#
exit_handler () {
  # Stop the PPP daemon if this script exits while the session is active.
  if [[ -n "$pppd_pid" ]] && kill -0 "$pppd_pid" 2>/dev/null; then
    kill "$pppd_pid" 2>/dev/null
    wait "$pppd_pid" 2>/dev/null
  fi

  # Stop the traffic statistics monitor.
  if [[ -n "$monitor_pid" ]]; then
    kill "$monitor_pid" 2>/dev/null
    wait "$monitor_pid" 2>/dev/null
  fi

  # Stop the record reader if it is still running.
  if [[ -n "$noisereader_pid" ]] && kill -0 "$noisereader_pid" 2>/dev/null; then
    kill "$noisereader_pid" 2>/dev/null
    wait "$noisereader_pid" 2>/dev/null
  fi
  rm -f "$recordfifo"

  # Release the CNI IP reservation if it was acquired.
  if [[ "$ipam_reserved" == 1 ]]; then
    if ! ipam_command DEL >/dev/null; then
      printf 'WARNING: Unable to release CNI IP reservation.\n' >&2
    fi
    ipam_reserved=0
  fi
}

# catch signals and ensure cleanup is performed
trap exit_handler EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Reserve an IP address before showing the fake login prompt.
if ! ipam_result="$(ipam_command ADD)"; then
  printf 'ERROR: Unable to allocate a remote IP address.\n' >&2
  exit 1
fi
ipam_reserved=1

# CNI returns CIDR notation, while pppd expects a plain IPv4 address.
if ! remote_ip="$(printf '%s\n' "$ipam_result" | jq -er '.ips[] | select(.address | contains(":") | not) | .address | split("/")[0]')" || [[ -z "$remote_ip" ]]; then
  printf 'ERROR: Invalid IPv4 allocation returned by CNI.\n' >&2
  exit 1
fi


# Trumpet Winsock 3.0 revision D for Windows 3.1
# by default requires a fake login shell.
#
# Windows 95 and 98 will not care for a login shell
# unless specifically told to expect one.
#
sleep 2
sendtty "\n\n`uname -sn`****\n\n"
sendtty  "Username: "; sleep 1; sendtty "\n"
sendtty  "Password: "; sleep 1; sendtty "\n"
sendtty  "Starting pppd...\n"
sendtty  "PPP>"
# End of fake login prompt.

# Optional PPP parameters, empty values add no pppd argument.
pppd_proxyarp=
pppd_debug=
[[ "${option_proxyarp:-0}" == 1 ]] && pppd_proxyarp=proxyarp
[[ "${option_debug:-0}" == 1 ]] && pppd_debug=debug

# Use DCD carrier detection when modem control is enabled.
[[ "${option_modem_control:-1}" == 1 ]] && pppd_modem_control=modem || pppd_modem_control=local

# Only record the PPP stream when modem audio is enabled.
pppd_record_options=()
if [[ "${option_ppp_record:-0}" == 1 ]]; then
  if [[ -f "$noisereader" ]]; then
    if ! mkfifo "$recordfifo"; then
      printf 'ERROR: Unable to create PPP record FIFO.\n' >&2
      exit 1
    fi

    # The reader must start before pppd opens the FIFO.
    python3 "$noisereader" "$recordfifo" &
    noisereader_pid=$!
    pppd_record_options=(record "$recordfifo")
  else
    printf 'WARNING: PPP noise reader missing; recording disabled.\n' >&2
  fi
fi

# Run PPP daemon and establish a link.
pppd noauth nodetach "$pppd_modem_control" lock \
  $pppd_proxyarp $pppd_debug \
  lcp-echo-interval "$lcp_echo_interval" lcp-echo-failure "$lcp_echo_failure" \
  ms-dns "$dns_primary" ms-dns "$dns_secondary" \
  "10.0.100.1:$remote_ip" \
  ipparam "$profile_downstream:$profile_upstream" \
  "${pppd_record_options[@]}" \
  "/dev/$serport" "$baud" &
pppd_pid=$!

# Monitor the current session's PPP interface, if enabled.
if [[ "${option_tcstatus:-1}" == 1 ]]; then
  (
    # Wait until IPCP assigns the remote IP, then resolve the interface once.
    iface=
    while kill -0 "$pppd_pid" 2>/dev/null && [[ -z "$iface" ]]; do
      iface=$(ip -o -4 addr show | awk -v peer="$remote_ip" \
        '$0 ~ (" peer " peer "/") && $2 ~ /^ppp[0-9]+$/ {print $2; exit}')
      [[ -n "$iface" ]] || sleep 1
    done

    # Keep using the same interface throughout this PPP session.
    while [[ -n "$iface" ]] && kill -0 "$pppd_pid" 2>/dev/null; do
      printf 'Traffic Shaper Status (%s):\n' "$iface"
      tc -s qdisc show dev "$iface"
      tc -s qdisc show dev "ifb$iface"
      sleep "${tc_status_interval:-60}"
    done
  ) &
  monitor_pid=$!
fi

# Wait for the connection to end, then stop monitoring immediately.
wait "$pppd_pid"
pppd_status=$?
pppd_pid=

if [[ -n "$monitor_pid" ]]; then
  kill "$monitor_pid" 2>/dev/null
  wait "$monitor_pid" 2>/dev/null
  monitor_pid=
fi

printf "\nPPP link terminated with status %s.\n" "$pppd_status"
