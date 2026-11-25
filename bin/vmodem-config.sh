#!/usr/bin/env bash

config_appdir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
source "$config_appdir/lib/vmodem/common.inc" || exit 1

# The SETUP menu uses vmodem's sendtty() and readtty() functions,
# which direct input and output from/to the USB console.
# For the shell config, this is not meaningful, as this runs through
# a vty/shell interface rather than a USB serial console.
# Instead of infesting the SETUP menus with IF/ELSEs to handle both cases,
# here I'm simply providing vty-compatible shims to for sendtty() and readtty().
sendtty() { printf '%b' "$1"; }
readtty() { IFS= read -r "$1"; }

config_restart_pending=0

setup_saved() {
  config_restart_pending=1
}

setup_offer_restart() {
  local answer prompt_status=0
  (( config_restart_pending )) || return 0
  sendtty "Settings saved. Running modem instances must restart to apply them.\n"
  setup_prompt answer "Restart all running vmodem instances now?\nThis will disconnect any active modem sessions. [y/N]: " || prompt_status=$?
  if (( prompt_status == 0 )) && [[ "$answer" == y || "$answer" == Y ]]; then
    if ! systemctl try-restart 'vmodem@*.service'; then
      sendtty "ERROR: Could not restart all running modem instances; settings remain saved.\n"
      return 1
    fi
  else
    sendtty "Settings will apply when the system or modem services next restart.\n"
    sendtty "To restart a specific instance later, simply unplug and reconnect its USB serial adapter.\n"
  fi
  return "$prompt_status"
}

if [[ "${1:-}" == --help ]]; then
  printf 'Usage: sudo bash %s\nConfigure global defaults or select a connected USB serial port.\n' "$0"
  exit 0
fi
if (( $# != 0 )); then
  printf 'ERROR: Unexpected arguments. Use --help for usage.\n' >&2
  exit 1
fi
if (( EUID != 0 )); then
  printf 'ERROR: Run this configurator with sudo to save settings and manage Wi-Fi.\n' >&2
  exit 1
fi
setup_status=0
vmodem_setup console || setup_status=$?
setup_offer_restart || exit 1
exit "$setup_status"
