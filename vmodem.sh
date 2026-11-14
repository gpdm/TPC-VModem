#!/bin/bash
#
# TPC-VModem - Hayes-compatible virtual modem
#
# Original VMODEM by Oliver Molini (2020-2022)
# Original contributions:
#   Billy Stoughton II - Bug fixes and contributions
#   Hamish - Windows 2000 compatibility testing
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

# Tested working out of box with the following client configurations:
#
# o Standard VT100 terminal
# o HyperTerminal
# o PuTTY
#
# PPP dial-up connectivity tested to initialize under the following configurations:
#
# o Windows 3.1
#   - Trumpet Winsock 3.0 revision D
#
# o Windows 95 OSR 2.5 + DUN 1.4
#   - Generic Modem
#     - Standard 28800 bps Modem
#
# o Windows 98
#   - Generic Modem
#     - Standard 9 600 bps modem
#     - Standard 33 600 bps modem
#     - Standard 56 000 bps V90 modem
#     - Standard 56 000 bps X2 modem
#     - Standard 56 000 bps K56Flex modem
#
# o Windows 2000
#   - Generic Modem
#     - Standard 19200 bps Modem
#
# Help us test and add more supported systems! 
# Contact us on Discord, links at the bottom of the Virtual Modem page.
#

# Script version
vmodver=2.0

# Directory where configuration files are stored.
config_dir=/opt/vmodem/config

# Specifies the configuration file to use.
# initialized at runtime based on the serial port.
# Do not modify this manually!
#
config_file=

# Variable: serport
# serport specifies which local serial device to use.
# For example, "ttyUSB0" will tell the script to use
# to use /dev/ttyUSB0 for communication.
#
# NOTE: This variable is passed as an argument from systemd
# and must not be modified within the script.
#
serport=${1:-ttyUSB0}


# -----------------------
# Pre-init Functions
# -----------------------

# Function: load_config
# Loads the configuration file for the specified serial port, if it exists.
load_config () {
  config_file=$(udevadm info --query=property --name="/dev/$serport" |
              awk -F'=' -v dir="$config_dir" '/^ID_PATH=/ {print dir "/" $2 ".conf"}')

  if [[ ! -f "${config_file}" ]]; then
    echo "WARNING: No config file found; will be using defaults." >&2
    return
  else
    source "${config_file}"
  fi
}


# -----------------------
# CONFIGURATION
# -----------------------

# load the configuration file (if it exists)
load_config


# Array: modem_profiles
# Contains the supported modem profiles.
# Each entry is in the format:
# ID|display name|downstream bps|upstream bps|minimum DTE baud
modem_profiles=(
  'V21|V.21|300|300|9600'
  'V22|V.22|1200|1200|9600'
  'V22BIS|V.22bis|2400|2400|9600'
  'V32|V.32|9600|9600|19200'
  'V32BIS|V.32bis|14400|14400|19200'
  'V34|V.34|28800|28800|38400'
  'V34BIS|V.34bis|33600|33600|57600'
  'V90|V.90|56000|33600|115200'
  'X2|X2|56000|33600|115200'
  'K56flex|K56flex|56000|33600|115200'
  'V92|V.92|56000|48000|115200'
  'ISDN64|ISDN 64k|64000|64000|115200'
  'ISDN128|ISDN 128k|128000|128000|230400'
)

# Variable: echoser
# echoser sets the default behaviour of echoing serial
# data back to the client terminal. The default is 1.
#
echoser=1

# Variable: resultverbose
# Controls default behavior when printing Hayes result
# codes. 
# When 0, prints result codes in numerical form. (eg. 0)
# When 1, prints result codes in english. (eg. CONNECT)
# Default is 1.
resultverbose=1

# Variable: TERM
# Tells the script and environment which type of terminal to emulate.
# It is only useful to change this, if you're using a serial 
# terminal to connect to this script. If you're connecting form a ANSI 
# cabable machine such as DOS, you may want to use TERM="ansi"
#
TERM="vt100"

# Variable: baud
# baud specifies the default serial communication speed.
# If not set, it defaults to 57600.
: "${baud:=57600}"

# Variable: modem_profile
# Specifies the default modem profile to use.
# If not set, it defaults to V34BIS.
: "${modem_profile:=V34BIS}"

# Per-modem PPP configuration
: "${option_proxyarp:=0}"
: "${option_modem_control:=1}"
: "${option_debug:=0}"
: "${option_tcstatus:=1}"
: "${tc_status_interval:=60}"
: "${lcp_echo_interval:=10}"
: "${lcp_echo_failure:=3}"
: "${dns_primary:=9.9.9.9}"
: "${dns_secondary:=149.112.112.112}"


# Audio daemon socket. The daemon exclusively owns GPIO18.
audio_socket="/run/vmodem/sound.sock"
noisehelper="./ppp_noise.py"
noisecache="ppp_noise_cache_v1.json.gz"

# Hayes speaker mode.
# ISDN is always silent (M0), analog modems default to M1.
[[ "$modem_profile" == ISDN* ]] && speaker_mode_default=0 || speaker_mode_default=1
speaker_mode=${speaker_mode_default}  

# Dialtone is only heard briefly after ATD, not while idle.
dialtone_time=2

# number of ringbacks and pauses
ringback_cycles=2
ringback_pause=3

# Only Raspberry Pi 1 needs a cache. Other models synthesize live.
# ppp_noise.py --check handles the model detection and cache validation.
if [[ -f "$noisehelper" ]] && ! python3 "$noisehelper" --check; then
    python3 "$noisehelper" --prepare || \
        echo 'WARNING: PPP noise cache could not be prepared.' >&2
fi


# EXPORT SHELL VARS
# -----------------
export serport
export baud
export modem_profile
export TERM


# -----------------------
# Functions
# -----------------------

# Function: ttyinit
# Initializes serial settings for the specified TTY port.
ttyinit () {
  stty -F /dev/$serport $baud
  stty -F /dev/$serport sane
  stty -F /dev/$serport raw
  stty -F /dev/$serport -echo -icrnl onlcr opost clocal -crtscts
}

# Function: sendtty
# Parameters:
# - $1: Message to send
sendtty () {
  # Prints message in console and over serial. Message is given as first parameter.
  message="$1"
  echo -en "$message" | tee /dev/$serport
}

# Function: readtty
# Reads input from TTY and stores it in variable given as first parameter.
readtty () {
  # Reads input from TTY and stores it in variable given as first parameter
  line=
  while [[ -z "$line" ]]; do
    charhex=`head -c 1 /dev/$serport | xxd -p -`
    char="`echo -e "\x$charhex"`"
    echo -n "$char"
    echo -n "$char" > /dev/$serport
    # Newline received
    if [ "$charhex" = "0d" -o "$charhex" = "0a" ]; then
      line=$buffer
      buffer=
      char=
      sendtty "\n"
    fi
    buffer=$buffer$char
  done
  local __resultvar=$1
  local result="$line"
  printf -v "$__resultvar" '%s' "$result"
}

# Function: dohayes
# Executes Hayes commands based on the provided command and parameter.
# Sets the result code accordingly.
dohayes () {
  # default to error result code, if command not recognized
  result=4

  # Debugging
  #sendtty "COMMAND: $hcmd $hparm\n"

  # ATA
  # - A Answer
  if [[ $hcmd == 'A' ]]; then result=0; fi

  # ATD Dial a number
  if [[ $hcmd == 'D' ]]; then
    if [[ ! -z "$hparm" ]]; then
      number=$(echo $hparm |tr -dc '0-9')
      result=0
    fi
  fi

  # ATE Command echo to host
  # - E0 Commands are not echoed
  # - E1 Commands are echoed
  if [[ $hcmd == 'E' ]]; then
    if [[ $hparm == '' ]]; then echoser=0; result=0; fi
    if [[ $hparm == '0' ]]; then echoser=0; result=0; fi
    if [[ $hparm == '1' ]]; then echoser=1; result=0; fi
  fi

  # ATH Hang up or pick-up.
  # - H0 Go on-hook (Hang up)
  # - H1 Go off-hook
  if [[ $hcmd == 'H' ]]; then result=0; fi

  # ATI System information
  if [[ $hcmd == 'I' && $hparm == '' ]]; then
    if systeminfo; then result=0; fi
  fi

  # ATM Speaker control
  # - M0 Speaker always off
  # - M1 Speaker on until carrier detected
  # - M2 Speaker always on
  # - M3 Speaker off while dialing
  if [[ $hcmd == 'M' ]]; then
    # ATM0
    if [[ $hparm == '0' ]]; then
      speaker_mode=0
      result=0
    fi
    # ATM1
    if [[ $hparm == '' || $hparm == '1' ]]; then
      speaker_mode=1
      result=0
    fi
    # ATM2
    if [[ $hparm == '2' ]]; then
      speaker_mode=2
      result=0
    fi
    # ATM3
    if [[ $hparm == '3' ]]; then
      speaker_mode=3
      result=0
    fi

    # ISDN doesn't support audio output.
    # discard ATM settings and revert to the default speaker mode (ATM0).
    [[ "$modem_profile" == ISDN* ]] && speaker_mode=$speaker_mode_default
  fi

  # ATQn Result codes
  # Q0 Modem returns result codes
  # Q1 Quiet mode. Modem gives no result codes.
  if [[ $hcmd == 'Q' ]]; then
    if [[ $hparm == '' ]]; then resultverbose=0; result=0; fi
    if [[ $hparm == '0' ]]; then resultverbose=0; result=0; fi
    if [[ $hparm == '1' ]]; then resultverbose=2; result=0; fi
  fi

  # S Registers (just auto-accept)
  if [[ $hcmd == 'S' ]]; then
    result=0;
  fi

  # ATV Result codes in numerical or verbose form
  # - V0 Returns the code in numerical form
  # - V1 Full-word result codes
  if [[ $hcmd == 'V' ]]; then
    if [[ $hparm == '' ]]; then resultverbose=0; result=0; fi
    if [[ $hparm == '0' ]]; then resultverbose=0; result=0; fi
    if [[ $hparm == '1' ]]; then resultverbose=1; result=0; fi
  fi

  # ATXn Extended result codes
  # - X0 Disable extended result codes (Hayes Smartmodem 300 compatible result codes)
  # - X1 Add connection speed to basic result codes (e.g. CONNECT 1200)
  # - X2 Add dial tone detection (preventing blind dial, and sometimes preventing ATO)
  # - X3 Add busy signal detection
  # - X4 Add both busy signal and dial tone detection
  if [[ $hcmd == 'X' ]]; then
    if [[ $hparm == '' ]]; then resultverbose=1; result=0; fi
    if [[ $hparm == '0' ]]; then resultverbose=1; result=0; fi
    if [[ $hparm == '1' ]]; then resultverbose=0; result=0; fi
    if [[ $hparm == '2' ]]; then resultverbose=0; result=0; fi
    if [[ $hparm == '3' ]]; then resultverbose=0; result=0; fi
    if [[ $hparm == '4' ]]; then resultverbose=0; result=0; fi
  fi

  # ATZ Reset modem
  # - Zn  Restore stored profile n
  if [[ $hcmd == 'Z' ]]; then echoser=1; resultverbose=1; carrierdetect=0; speaker_mode=${speaker_mode_default}; result=0; fi

  # AT&Cn Carrier-detect
  # - &C0 Force DCD signal active
  # - &C1 DCD signal indicates true state of remote carrier signal
  if [[ $hcmd == '&C' ]]; then
    if [[ $hparm == '' ]]; then result=0; carrierdetect=0; fi
    if [[ $hparm == '0' ]]; then result=0; carrierdetect=0; fi
    if [[ $hparm == '1' ]]; then result=0; carrierdetect=1; fi
  fi

  # AT&Dn Data Terminal Ready settings
  # - &D0 Modem ignores DTR
  # - &D1 Go to command mode on ON-to-OFF DTR transition.
  # - &D2 Hang up on DTR-drop and go to command mode
  # - &D3 Reset (ATZ) on DTR-drop. Modem hangs up.
  if [[ $hcmd == '&D' ]]; then
    if [[ $hparm == '' ]]; then result=0; fi
    if [[ $hparm == '0' ]]; then result=0; fi
    if [[ $hparm == '1' ]]; then result=0; fi
    if [[ $hparm == '2' ]]; then result=0; fi
    if [[ $hparm == '3' ]]; then result=0; fi
  fi

  # AT&F Restore factory settings
  # - &Fn Use profile n
  if [[ $hcmd == '&F' ]]; then echoser=1; resultverbose=1; carrierdetect=0; speaker_mode=${speaker_mode_default}; result=0; fi

  # AT&K DTE - MODEM Flow control
  # - &K0 Local flow control off
  # - &K1 Not used
  # - &K2 Not used
  # - &K3 RTS/CTS
  # - &K4 XON/XOFF
  # - &K5 Transparent XON/XOFF
  # - &K6 RTS/CTS and XON/XOFF
  if [[ $hcmd == '&K' ]]; then result=0; fi

  # AT&Sn DSR Override
  # - &S0 DSR will remain on at all times.
  # - &S1 DSR will become active after answer tone has been detected and inactive after the carrier has been lost
  if [[ $hcmd == '&S' ]]; then
    if [[ $hparm == '' ]]; then result=0; fi
    if [[ $hparm == '0' ]]; then result=0; fi
    if [[ $hparm == '1' ]]; then result=0; fi
  fi
}


# Function: soundd_disconnect
# Close the socket and release any held lease if this client disappears.
soundd_disconnect () {
  if [[ -n "${audio_write_fd:-}" ]]; then
    exec {audio_write_fd}>&-
    audio_write_fd=
  fi
  if [[ -n "${audio_read_fd:-}" ]]; then
    exec {audio_read_fd}<&-
    audio_read_fd=
  fi
  if [[ -n "${audio_orig_write_fd:-}" ]]; then
    exec {audio_orig_write_fd}>&-
    audio_orig_write_fd=
  fi
  if [[ -n "${audio_orig_read_fd:-}" ]]; then
    exec {audio_orig_read_fd}<&-
    audio_orig_read_fd=
  fi
  if [[ -n "${audio_pid:-}" ]]; then
    wait "$audio_pid" 2>/dev/null || true
    audio_pid=
  fi
}

# Function: soundd_connect
# Keep one socket open for the complete dial sequence and its lease.
soundd_connect () {
  if [[ ! -S "$audio_socket" ]]; then
    echo "ERROR: Audio daemon socket unavailable: $audio_socket" >&2
    return 1
  fi

  coproc AUDIO_SOCKET { socat - "UNIX-CONNECT:$audio_socket"; }
  audio_pid=$AUDIO_SOCKET_PID
  audio_orig_read_fd=${AUDIO_SOCKET[0]}
  audio_orig_write_fd=${AUDIO_SOCKET[1]}
  exec {audio_read_fd}<&"$audio_orig_read_fd"
  exec {audio_write_fd}>&"$audio_orig_write_fd"
  exec {audio_orig_read_fd}<&-
  exec {audio_orig_write_fd}>&-
  audio_orig_read_fd=
  audio_orig_write_fd=
}

# Function: soundd_command
# The response is stored in soundd_response without a subshell.
soundd_command () {
  soundd_response=
  if ! printf '%s\n' "$1" >&"$audio_write_fd" ||
     ! IFS= read -r -t 180 soundd_response <&"$audio_read_fd"; then
    echo "ERROR: Audio daemon communication failed." >&2
    return 1
  fi

  case "$soundd_response" in
    OK|DONE|RELEASED) return 0 ;;
    BUSY) return 3 ;;
    *) echo "ERROR: Audio daemon replied: $soundd_response" >&2; return 1 ;;
  esac
}

# Function: emit_sound
# Acquire atomically, play the complete dial sequence, then release before PPP.
# Return 3 for BUSY, 1 for an audio failure, 0 on success.
emit_sound () {
  local digits=$1 status=0
  local dial_mode=AUDIBLE
  local ring_mode=AUDIBLE
  local handshake_mode=AUDIBLE

  # ISDN does not emit analog modem audio.
  [[ "$modem_profile" == ISDN* ]] && return 0

  # set non-audible modes based on speaker_mode
  case "$speaker_mode" in
      # ATM0
      0) dial_mode=SILENT; ring_mode=SILENT; handshake_mode=SILENT ;;
      # ATM3
      3) dial_mode=SILENT ;;
  esac

  # initialize soundd connection
  soundd_connect || return 1

  # acquire exclusive lease
  soundd_command ACQUIRE || status=$?

  if (( status == 0 )); then
    soundd_command "DIALTONE $dialtone_time $dial_mode" || status=$?
    if (( status == 0 )); then
      soundd_command "DTMF $digits $dial_mode" || status=$?
    fi

    if (( status == 0 )); then
        [[ "$resultverbose" == 1 ]] && sendtty "RINGING\n"

        soundd_command "RINGBACK $ringback_cycles $ringback_pause $ring_mode" || status=$?
        if (( status == 0 )); then
            soundd_command "HANDSHAKE V34 $handshake_mode" || status=$?
        fi
    fi

    # Explicit release only if the handshake did not release the lease.
    if [[ "$soundd_response" != RELEASED ]]; then
      soundd_command RELEASE >/dev/null || status=1
    fi
  fi

  soundd_disconnect
  return "$status"
}

# Close any active socket if the modem process exits unexpectedly.
trap soundd_disconnect EXIT


# Function: systeminfo
# Displays system uptime, IP addresses and current settings.
systeminfo () {
  local system_uptime interfaces

  if ! system_uptime=$(uptime); then
    sendtty "Could not read system uptime.\n"
    return 1
  fi
  sendtty "System uptime:\n$system_uptime\n"

  sendtty "\nNetwork interfaces and IP addresses:\n"
  if ! interfaces=$(ip -4 -brief address show); then
    sendtty "Could not read network interfaces.\n"
    return 1
  fi
  interfaces=$(printf '%s\n' "$interfaces" | awk '$1 != "lo" && $1 != "lo0" { print "* " $0 }')
  sendtty "$interfaces\n"

  sendtty "\nCurrent Modem Settings:\n"
  sendtty "* Baud rate: $baud\n"
  sendtty "* Modem profile: $modem_profile ($profile_downstream/$profile_upstream bps)\n"

  sendtty "\nCurrent PPP Settings:\n"
  sendtty "* Proxy ARP: $([[ "$option_proxyarp" == 1 ]] && echo Enabled || echo Disabled)\n"
  sendtty "* Modem control (DCD): $([[ "$option_modem_control" == 1 ]] && echo Enabled || echo Disabled)\n"
  sendtty "* PPP debug: $([[ "$option_debug" == 1 ]] && echo Enabled || echo Disabled)\n"
  sendtty "* Traffic statistics: $([[ "$option_tcstatus" == 1 ]] && echo Enabled || echo Disabled) ($tc_status_interval seconds)\n"
  sendtty "* LCP echo interval: $lcp_echo_interval seconds\n"
  sendtty "* LCP echo failures: $lcp_echo_failure\n"
  sendtty "* DNS servers: $dns_primary, $dns_secondary\n"
}


# Function: find_modem_profile
# Finds a modem profile by its ID.
# Returns 0 if found, 1 otherwise.
find_modem_profile () {
  local entry id
  for entry in "${modem_profiles[@]}"; do
    IFS='|' read -r id name down up min_baud <<< "$entry"

    if [[ "$id" == "$modem_profile" ]]; then
      profile_name=$name
      profile_downstream=$down
      profile_upstream=$up
      profile_min_baud=$min_baud
      return 0
    fi
  done
  return 1
}


# Function: modem_configuration
# Interactively configures the modem baud rate and emulation profile.
# Prompts the user to select a baud rate and modem profile from available options.
# Saves the configuration if it has changed.
modem_configuration () {
  local selection new_baud new_modem entry id name down up min_baud i
  local baud_rates=() available_profiles=()

  # Build baud rate list from modem profiles.
  mapfile -t baud_rates < <(
    printf '%s\n' "${modem_profiles[@]}" |
      cut -d'|' -f5 | sort -nu
  )

  # Baud rate selection.
  sendtty "\nModem Configuration\n===================\n\n"
  sendtty "Select Serial Baud Rate\n\n"

  for i in "${!baud_rates[@]}"; do
    sendtty "$((i + 1)). ${baud_rates[i]}\n"
  done

  sendtty "0. Cancel\n\nEnter your selection: "
  readtty selection

  [[ "$selection" == 0 ]] && return

  if [[ ! "$selection" =~ ^[1-9][0-9]*$ ]] ||
     (( selection > ${#baud_rates[@]} )); then
    sendtty "Invalid selection.\n"
    return
  fi

  new_baud=${baud_rates[selection-1]}

  # Modem profile selection.
  sendtty "\nSelect Modem Emulation\n\n"

  for entry in "${modem_profiles[@]}"; do
    IFS='|' read -r id name down up min_baud <<< "$entry"

    if (( new_baud >= min_baud )); then
      available_profiles+=("$id")
      sendtty "${#available_profiles[@]}. $name ($down/$up bps)\n"
    fi
  done

  sendtty "0. Cancel\n\nEnter your selection: "
  readtty selection

  [[ "$selection" == 0 ]] && return

  if [[ ! "$selection" =~ ^[1-9][0-9]*$ ]] ||
     (( selection > ${#available_profiles[@]} )); then
    sendtty "Invalid selection.\n"
    return
  fi

  new_modem=${available_profiles[selection-1]}

  # Save only if the configuration changed.
  if [[ "$new_baud" == "$baud" && "$new_modem" == "$modem_profile" ]]; then
    sendtty "Configuration unchanged.\n"
    return
  fi

  if ! save_config "$new_baud" "$new_modem" "$option_proxyarp" "$option_debug" "$option_tcstatus" \
      "$tc_status_interval" "$lcp_echo_interval" "$lcp_echo_failure" "$dns_primary" "$dns_secondary" "$option_modem_control"; then
    sendtty "Cannot save configuration.\n"
    return
  fi

  sendtty "\nConfiguration saved successfully.\n\n"
  sendtty "The virtual modem session will restart shortly\n"
  sendtty "to apply the new settings.\n\n"
  sendtty "If the serial baud rate has changed, please\n"
  sendtty "configure your terminal to use the new speed.\n\n"

  # extra wait time for user to read the message before restarting
  # note: systemd adds another 5 seconds (RestartSec=5)
  sleep 5

  exit 75
}


# Function: valid_ipv4
# Accepts a dotted IPv4 address with four decimal octets (0 through 255).
valid_ipv4 () {
  local address=$1 octet
  local -a parts
  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$address"
  for octet in "${parts[@]}"; do
    (( ${#octet} <= 3 && 10#$octet <= 255 )) || return 1
  done
}

# Function: ppp_configuration
# Configures and persists optional PPP settings.
ppp_configuration () {
  local selection input
  local new_proxyarp=$option_proxyarp new_debug=$option_debug new_tcstatus=$option_tcstatus
  local new_modem_control=$option_modem_control
  local new_tc_interval=$tc_status_interval new_lcp_interval=$lcp_echo_interval
  local new_lcp_failure=$lcp_echo_failure new_dns_primary=$dns_primary new_dns_secondary=$dns_secondary

  while true; do
    sendtty "\nPPP Configuration\n=================\n\n"
    sendtty "1. Proxy ARP           : $([[ "$new_proxyarp" == 1 ]] && echo Enabled || echo Disabled)\n"
    sendtty "2. PPP Debug           : $([[ "$new_debug" == 1 ]] && echo Enabled || echo Disabled)\n"
    sendtty "3. Traffic Statistics  : $([[ "$new_tcstatus" == 1 ]] && echo Enabled || echo Disabled)\n"
    sendtty "4. Statistics Interval : $new_tc_interval seconds\n"
    sendtty "5. LCP Echo Interval   : $new_lcp_interval seconds\n"
    sendtty "6. LCP Echo Failures   : $new_lcp_failure\n"
    sendtty "7. Primary DNS         : $new_dns_primary\n"
    sendtty "8. Secondary DNS       : $new_dns_secondary\n"
    sendtty "9. Modem Control (DCD) : $([[ "$new_modem_control" == 1 ]] && echo Enabled || echo Disabled)\n"
    sendtty "0. Save and return\n\nEnter your selection: "
    readtty selection

    case "$selection" in
      1) (( new_proxyarp = 1 - new_proxyarp )) ;;
      2) (( new_debug = 1 - new_debug )) ;;
      3) (( new_tcstatus = 1 - new_tcstatus )) ;;
      9) (( new_modem_control = 1 - new_modem_control )) ;;
      4|5|6)
        sendtty "Enter new value: "
        readtty input
        if [[ "$input" =~ ^[0-9]+$ ]] && (( ${#input} <= 4 )) &&
           (( (selection == 4 && 10#$input >= 1 && 10#$input <= 3600) ||
              (selection == 5 && 10#$input <= 3600) ||
              (selection == 6 && 10#$input <= 100) )); then
          case "$selection" in
            4) new_tc_interval=$((10#$input)) ;;
            5) new_lcp_interval=$((10#$input)) ;;
            6) new_lcp_failure=$((10#$input)) ;;
          esac
        else
          sendtty "Invalid value. Statistics: 1..3600, LCP interval: 0..3600, failures: 0..100.\n"
        fi
        ;;
      7|8)
        sendtty "Enter IPv4 address: "
        readtty input
        if valid_ipv4 "$input"; then
          if [[ "$selection" == 7 ]]; then
            new_dns_primary=$input
          else
            new_dns_secondary=$input
          fi
        else
          sendtty "Invalid IPv4 address.\n"
        fi
        ;;
      0) break ;;
      *) sendtty "Invalid selection.\n" ;;
    esac
  done

  if [[ "$new_proxyarp" == "$option_proxyarp" &&
        "$new_debug" == "$option_debug" &&
        "$new_tcstatus" == "$option_tcstatus" &&
        "$new_tc_interval" == "$tc_status_interval" &&
        "$new_lcp_interval" == "$lcp_echo_interval" &&
        "$new_lcp_failure" == "$lcp_echo_failure" &&
        "$new_dns_primary" == "$dns_primary" &&
        "$new_dns_secondary" == "$dns_secondary" &&
        "$new_modem_control" == "$option_modem_control" ]]; then
    sendtty "Configuration unchanged.\n"
    return
  fi

  if ! save_config "$baud" "$modem_profile" "$new_proxyarp" "$new_debug" "$new_tcstatus" \
       "$new_tc_interval" "$new_lcp_interval" "$new_lcp_failure" "$new_dns_primary" "$new_dns_secondary" "$new_modem_control"; then
    sendtty "Cannot save configuration.\n"
    return
  fi

  sendtty "\nConfiguration saved successfully.\n"
  sendtty "The virtual modem session will restart shortly\n"
  sendtty "to apply the new settings.\n"
  sleep 5
  exit 75
}


# Function: save_config
# Saves modem and PPP settings to the configuration file.
#
# FIXME: could be a bit more sophisticated here,
# for example, use a temporary file and atomic move to avoid partial writes.
save_config () {
  mkdir -p "$config_dir" || return 1

  cat > "$config_file" <<EOF
baud=$1
modem_profile=$2
option_proxyarp=$3
option_debug=$4
option_tcstatus=$5
tc_status_interval=$6
lcp_echo_interval=$7
lcp_echo_failure=$8
dns_primary=$9
dns_secondary=${10}
option_modem_control=${11}
EOF
}



# -----------------------
# Main
# -----------------------

# export the tty functions
export -f sendtty
export -f readtty
export -f ttyinit

# resolve the current modem profile based on the configuration
find_modem_profile "$modem_profile"

# Open serial port for use. Allocate file descriptor
# and treat the serial port as a file.
ttyinit
exec 99<>/dev/$serport

# print info banner
sendtty "\n"
sendtty "Virtual Modem bootstrap for PPP link v$vmodver\n\n"
systeminfo
sendtty "\n"
sendtty "TYPE \"HELP\" FOR COMMAND REFERENCE.\n"
sendtty "READY.\n"


# MAIN LOOP
while [ "$continue" != "1" ]; do
  charhex=`head -c 1 /dev/$serport | xxd -p -`
  char="`echo -e "\x$charhex"`"

  #ECHO SERIAL INPUT TO TTY
  echo -n "$char"

  #ECHO SERIAL INPUT
  if [ "$echoser" = "1" ]; then echo -n "$char" > /dev/$serport; fi

  #CHECK IF NEWLINE IS SENT
  if [ "$charhex" = "0d" -o "$charhex" = "0a" ]; then
    line=$buffer
    # PARSE COMMAND
    cmd=`echo -en $buffer | tr a-z A-Z`
    buffer=
    char=

    #NEWLINE SENT - ECHO NEWLINE TO CONSOLE
    if [ "$echoser" = "0" ]; then echo; fi
    if [ "$echoser" = "1" ]; then sendtty "\n"; fi

    #
    # --- HAYES EMULATION ---
    #
    if [[ $cmd == AT* ]]; then
      # Attention! Client issued an AT command
      #
      # default to error result code, if command not recognized
      result=4; resultc=0

      if [[ $cmd == AT ]]; then result=0; fi

      # Get full hayes string and parse it
      seq=`echo $cmd |cut -b3-`
      ptr=1
      until [ $ptr -gt 64 ]; do
        hchar=$(echo "$seq" |cut -b$ptr)
        #sendtty "$ptr $hchar\n"
        if [[ $hchar =~ [A-Z\&] ]]; then
          if [[ $hchar == '&' ]]; then
            hcmd="$hchar"
            ptr=$((ptr+1))
            hchar=$(echo "$seq" |cut -b$ptr)
            if [[ $hchar =~ [A-Z] ]]; then
              hcmd="$hcmd$hchar"
              until [ $hdone ]; do
                ptr=$((ptr+1))
                hchar=$(echo "$seq" |cut -b$ptr)
                if [[ $hchar =~ [0-9] ]]; then
                  hparm="$hparm$hchar"
                else
                  ptr=$((ptr-1))
                  hdone=1
                fi
              done
            fi
          elif [[ $hchar =~ [A-CE-Z] ]]; then
            hcmd="$hcmd$hchar"
            until [ $hdone ]; do
              ptr=$((ptr+1))
              hchar=$(echo "$seq" |cut -b$ptr)
              if [[ $hchar =~ [0-9] ]]; then
                hparm="$hparm$hchar"
              else
                ptr=$((ptr-1))
                hdone=1
              fi
            done
          elif [[ $hchar == 'D' ]]; then
            hcmd="$hcmd$hchar"
            until [ $hdone ]; do
              ptr=$((ptr+1))
              hchar=$(echo "$seq" |cut -b$ptr)
              if [[ $hchar =~ [0-9PRT,!] ]]; then
                hparm="$hparm$hchar"
              else
                ptr=$((ptr-1))
                hdone=1
              fi
            done
          fi
        fi
        ptr=$((ptr+1))
        if [[ ! -z "$hcmd" ]]; then
          dohayes
          # preserve error if one was encountered
          if [[ $result == '4' ]]; then resultc='4'; fi
        else
          break
        fi
        hcmd=""
        hparm=""
        hdone=""
      done

      if [[ $resultc == '4' ]]; then result='4'; fi

      # ATD Dial number
      if [[ ! -z "$number" ]]; then
        # Acquire before any sound. BUSY must not start PPP.
        audio_status=0
        emit_sound "$number" || audio_status=$?
        if (( audio_status == 0 )); then
          # A number-specific script wins. Everything else is handled
          # by the default PPP service.
          if [ -f "$number.sh" ]; then
            dialscript="./$number.sh"
          else
            dialscript="./ppp.sh"
          fi

          if [ -f "$dialscript" ]; then
            if [[ $resultverbose == 1 ]]; then sendtty "CONNECT $baud\n"; else sendtty "1\n"; fi

            # Assert DCD when carrier detection is turned on (for Trumpet Winsock)
            if [[ $carrierdetect == 1 ]]; then exec 99>&-; fi

            # Tell the terminal to use CR/LF for newlines instead of just CR.
            echo -en "\x1b[20h" > /dev/$serport

            # Run the selected service. vmodem waits here until it returns.
            # Record PPP traffic only when modem audio is requested.
            option_ppp_record=0
            [[ "$speaker_mode" == 1 || "$speaker_mode" == 2 ]] && option_ppp_record=1

            speaker_mode="$speaker_mode" \
            profile_downstream="$profile_downstream" \
            profile_upstream="$profile_upstream" \
            option_proxyarp="$option_proxyarp" \
            option_modem_control="$option_modem_control" \
            option_debug="$option_debug" \
            option_tcstatus="$option_tcstatus" \
            tc_status_interval="$tc_status_interval" \
            lcp_echo_interval="$lcp_echo_interval" \
            lcp_echo_failure="$lcp_echo_failure" \
            dns_primary="$dns_primary" \
            dns_secondary="$dns_secondary" \
            option_ppp_record="$option_ppp_record" \
              "$dialscript"

            if [[ $carrierdetect == 1 ]]; then exec 99<>/dev/$serport; fi

            # Reset serial settings
            ttyinit
            result=3
          else
            # The default PPP service is missing.
            result=3
          fi

        elif (( audio_status == 3 )); then
          result=7
        else
          result=3
        fi

        number=""

        # Stay silent after disconnect. Wait for the next ATD.
      fi

      #
      # --- PRINT RESULT CODE ---
      #
      if [[ $resultverbose == 0 ]]; then
        sendtty "$result\n";
      elif [[ $resultverbose == 1 ]]; then
        if [[ $result == 0 ]]; then sendtty "OK\n"; fi
        if [[ $result == 1 ]]; then sendtty "CONNECT\n"; fi
        if [[ $result == 2 ]]; then sendtty "RING\n"; fi
        if [[ $result == 3 ]]; then sendtty "NO CARRIER\n"; fi
        if [[ $result == 4 ]]; then sendtty "ERROR\n"; fi
        if [[ $result == 5 ]]; then sendtty "CONNECT 1200\n"; fi
        if [[ $result == 6 ]]; then sendtty "NO DIALTONE\n"; fi
        if [[ $result == 7 ]]; then sendtty "BUSY\n"; fi
        if [[ $result == 8 ]]; then sendtty "NO ANSWER\n"; fi
      fi
    fi

    if [[ $cmd = "HELP" ]] || [[ $cmd = "?" ]]; then
      sendtty "Command Reference for Virtual Modem Bootstrap v$vmodver\n"
      sendtty "\n"
      sendtty "General commands:\n"
      sendtty "HELP.......Display this help\n"
      sendtty "LOGIN......Drop to shell\n"
      sendtty "SETUP......Change settings\n"
      sendtty "EXIT.......End this script\n"
      sendtty "\n"
      sendtty "Common Hayes commands:\n"
      sendtty "AT.........Tests serial connection, prints OK if successful\n"
      sendtty "ATE0/ATE1..Switch terminal echo 0-off or 1-on\n"
      sendtty "ATD#.......Run #.sh, or ppp.sh if no matching script exists\n"
      sendtty "ATI........Display system information\n"
      sendtty "ATM0-3.....Control virtual modem speaker\n"
      sendtty "ATZ........Reset modem settings\n"
      sendtty "\n"
      sendtty "READY.\n"
    fi

    if [[ $cmd = "SETUP" ]]; then
      while true; do
        # Display menu
        sendtty "\n"
        sendtty "System Setup\n"
        sendtty "============\n"
        sendtty "\nCurrent Modem Configuration\n"
        sendtty "Baud Rate : $baud\n"
        sendtty "Emulation : $profile_name ($profile_downstream/$profile_upstream bps)\n\n"
        sendtty "1. Modem Configuration\n"
        sendtty "2. PPP Configuration\n"
        sendtty "3. Wi-Fi Settings\n"
        sendtty "4. Exit\n\n"
        sendtty "Enter your selection: "
        # Read user input
        readtty selection

        if [[ "$selection" == "1" ]]; then
          modem_configuration
        elif [[ "$selection" == "2" ]]; then
          ppp_configuration
        # Wireless network settings
        elif [[ "$selection" == "3" ]]; then
          while true; do
            sendtty "\n"
            sendtty "Wi-Fi Settings\n"
            sendtty "==============\n"
            sendtty "1. Connect to new Wi-Fi network\n"
            sendtty "2. Modify password for current Wi-Fi network\n"
            sendtty "3. Disconnect from current Wi-Fi network\n"
            sendtty "4. Display current Wi-Fi connection status\n"
            sendtty "5. Exit\n"
            sendtty "Enter your selection: "
            # Read user input
            readtty selection
            # Connect to new Wi-Fi network
            if [[ "$selection" == "1" ]]; then
              sendtty "Enter SSID: "
              readtty ssid
              sendtty "Enter password: "
              readtty password
              sudo wpa_cli -i wlan0 remove_network 0
              sudo wpa_cli -i wlan0 add_network
              sudo wpa_cli -i wlan0 set_network 0 ssid "\"$ssid\""
              sudo wpa_cli -i wlan0 set_network 0 psk "\"$password\""
              sudo wpa_cli -i wlan0 select_network 0
              sudo wpa_cli -i wlan0 enable_network 0
            # Modify password for current Wi-Fi network
            elif [[ "$selection" == "2" ]]; then
              sendtty "Enter new password: "
              readtty password
              sudo wpa_cli -i wlan0 set_network 0 psk "\"$password\""
            # Disconnect from current Wi-Fi network
            elif [[ "$selection" == "3" ]]; then
              sendtty "Disconnecting from current Wi-Fi network\n"
              sudo wpa_cli -i wlan0 disable_network 0
            # Display current Wi-Fi connection status
            elif [[ "$selection" == "4" ]]; then
              status=$(sudo wpa_cli -i wlan0 status)
              sendtty "\n"
              sendtty "Wi-fi connection status\n"
              sendtty "=======================\n"
              sendtty "$status"
              sendtty "\n"
            # Exit
            elif [[ "$selection" == "5" ]]; then
              break
            # Invalid selection
            else
              sendtty "Invalid selection. Please try again.\n"
            fi
          done
        # Exit
        elif [[ "$selection" == "4" ]]; then
          sendtty "Exited setup\n"
          sendtty "READY.\n"
          break
        # Invalid selection
        else
          sendtty "Invalid selection. Please try again.\n"
        fi
      done
    fi


    # LOGIN  -  FORK LOGIN SESSION
    if [[ $cmd == LOGIN ]]; then
      exec 99>&-
      /sbin/getty -8 -L $serport $baud $TERM
      ttyinit
      exec 99<>/dev/$serport
      sendtty "\n"; sendtty "READY.\n"
    fi

    # EXIT  -  EXIT SCRIPT
    if [ "$cmd" = "EXIT" ]; then sendtty "OK\n"; continue="1"; fi
  fi
  buffer=$buffer$char
done

# Close serial port
exec 99>&-
