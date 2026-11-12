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

# Variable: lcpidle
# Specifies the idle timeout period in seconds for lcp-echo-interval.
# This is to ensure that pppd will not run indefinitely after sudden
# hangup and will relinquish control back to the vmodem.sh.
#
# Default:    lcpidle=5
lcpidle=10

# PPP record stream
# pppd writes its live serial record stream into this FIFO. The noise
# reader must keep draining the FIFO for the whole PPP session, even
# after it has stopped generating sound.
recordfifo="/run/tpc-vmodem-ppp-$$.fifo"
noisereader="./ppp_noise.py"
recordpid=

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
  # Stop the record reader if it is still running.
  if [[ -n "$recordpid" ]] && kill -0 "$recordpid" 2>/dev/null; then
    kill "$recordpid" 2>/dev/null
    wait "$recordpid" 2>/dev/null
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

# Create the record FIFO before pppd starts.
rm -f "$recordfifo"
if ! mkfifo "$recordfifo"; then
  printf "\nUnable to create PPP record FIFO.\n"
  exit 1
fi

# Start the record reader first.
# It will block on the FIFO until pppd opens the write side.
[[ -f "$noisereader" ]] || speaker_mode=0
case "${speaker_mode:-0}" in
    1|2)
	    python3 "$noisereader" "$recordfifo" &
	    ;;
    *)
      cat "$recordfifo" >/dev/null &
      ;;
esac

recordpid=$!

# Run PPP daemon and establish a link.
pppd noauth nodetach local lock \
  lcp-echo-interval $lcpidle lcp-echo-failure 3 \
  proxyarp ms-dns 8.8.4.4 ms-dns 8.8.8.8 \
  "10.0.100.1:$remote_ip" \
  ipparam "$profile_downstream:$profile_upstream" \
  record "$recordfifo" \
  /dev/$serport $baud

printf "\nPPP link terminated.\n"