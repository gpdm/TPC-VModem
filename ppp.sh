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

# Variable: etherp
# Override the ethernet device to use to connect to your network.
# This is set in vmodem.sh, but can be overridden here.
#
# Default:    #etherp=eth0 (commented out)
#etherp=eth0

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

cleanup_record () {
  if [[ -n "$recordpid" ]] && kill -0 "$recordpid" 2>/dev/null; then
    kill "$recordpid" 2>/dev/null
    wait "$recordpid" 2>/dev/null
  fi

  rm -f "$recordfifo"
}

trap cleanup_record EXIT

#
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

# Set the kernel to router mode
sysctl -q net.ipv4.ip_forward=1

# Share eth0 over ppp0
iptables -t nat -A POSTROUTING -o $etherp -j MASQUERADE
iptables -t filter -A FORWARD -i ppp0 -o $etherp -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t filter -A FORWARD -i $etherp -o ppp0 -j ACCEPT

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
  10.0.100.1:10.0.100.2 \
  record "$recordfifo" \
  /dev/$serport $baud

# pppd is finished, so the record reader is no longer needed.
# Normally it will already have seen EOF and exited. If it is still
# around, stop it here so a failed pppd startup cannot leave us waiting.
if [[ -n "$recordpid" ]]; then
  if kill -0 "$recordpid" 2>/dev/null; then
    kill "$recordpid" 2>/dev/null
  fi
  wait "$recordpid" 2>/dev/null
  recordpid=
fi

rm -f "$recordfifo"

# Flush iptables
iptables -t filter -F FORWARD
iptables -t nat -F POSTROUTING

printf "\nPPP link terminated.\n"
