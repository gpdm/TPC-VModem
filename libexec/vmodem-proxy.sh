#!/bin/bash
# TPC-VModem transparent proxy membership, invoked by PPP ip-up and ip-down.
# $1: PPP interface, $5: subscriber address, $6: downstream:upstream[:dnsproxy].

iface=${1:-}
remote_ip=${5:-}
ipparam=${6:-}

# ensure we get consistent locale for string operations
LC_ALL=C

case "$0" in
  */ip-up.d/*) event=up ;;
  */ip-down.d/*) event=down ;;
  *) exit 0 ;;
esac

# Ignore unrelated PPP sessions.
[[ "$iface" =~ ^ppp[0-9]+$ ]] || exit 0
[[ "$ipparam" =~ ^[0-9]{1,7}:[0-9]{1,7}(:.*)?$ ]] || exit 0

log_error() {
  printf 'ERROR: vmodem-proxy: %s\n' "$*" >&2
}

if [[ ! "$ipparam" =~ ^[0-9]{1,7}:[0-9]{1,7}(:[01])?$ ]]; then
  log_error "Invalid PPP session metadata: $ipparam"
  exit 1
fi
IFS=: read -r downstream upstream dnsproxy <<< "$ipparam"
dnsproxy=${dnsproxy:-0}
if (( 10#$downstream == 0 || 10#$upstream == 0 )); then
  log_error "Invalid PPP bandwidth metadata: $ipparam"
  exit 1
fi

if [[ "$remote_ip" =~ ^100\.64\.254\.([0-9]{1,3})$ ]]; then
  remote_octet=$((10#${BASH_REMATCH[1]}))
else
  log_error "Invalid subscriber address: $remote_ip"
  exit 1
fi
if (( remote_octet < 2 || remote_octet > 254 )); then
  log_error "Subscriber address is outside the VModem allocation range: $remote_ip"
  exit 1
fi

add_proxy_client() {
  local output
  if output=$(nft add element ip visp proxy_clients "{ $remote_ip }" 2>&1); then
    return 0
  fi
  case "$output" in
    *"File exists"*|*"already exists"*) return 0 ;;
    *) log_error "Could not add $remote_ip to proxy_clients: ${output:-nft failed}"; return 1 ;;
  esac
}

delete_proxy_client() {
  local output
  if output=$(nft delete element ip visp proxy_clients "{ $remote_ip }" 2>&1); then
    return 0
  fi
  case "$output" in
    *"No such file or directory"*)
      if nft list set ip visp proxy_clients >/dev/null 2>&1; then
        return 0
      fi
      log_error "Could not access proxy_clients while removing $remote_ip."
      return 1
      ;;
    *)
      log_error "Could not remove $remote_ip from proxy_clients: ${output:-nft failed}"
      return 1
      ;;
  esac
}

if [[ "$event" == up && "$dnsproxy" == 1 ]]; then
  add_proxy_client
else
  delete_proxy_client
fi
