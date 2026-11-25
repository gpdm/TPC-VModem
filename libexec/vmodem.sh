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

# Script version
vmodver=2.0

# Shared configuration and SETUP menus.
config_appdir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
source "$config_appdir/lib/vmodem/common.inc" || exit 1
serport=${1:-ttyUSB0}
config_select_port "/dev/$serport" || exit 1
config_validate config_port || exit 1
config_apply_runtime

# EXPORT SHELL VARS
# -----------------
export serport
export baud
export modem_profile
export TERM
export audio_socket
export linenoise_time


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
  local tty_char tty_buffer=
  while IFS= read -r -n 1 tty_char; do
    case "$tty_char" in
      ''|$'\r')
        printf -v "$1" '%s' "$tty_buffer"
        sendtty "\n"
        return 0
        ;;
      $'\177'|$'\b') tty_buffer=${tty_buffer%?} ;;
      *) tty_buffer+=$tty_char; printf '%s' "$tty_char" > "/dev/$serport" ;;
    esac
  done < "/dev/$serport"
  return 1
}

setup_saved() {
  local scope=$1 key
  shift
  if [[ "$scope" == global ]]; then
    sendtty "Global changes apply when modem instances next restart.\n"
    return 0
  fi
  for key in "$@"; do
    if [[ "$key" == baud || "$key" == modem_profile ]]; then
      sendtty "The modem will restart shortly. Update your terminal speed if necessary.\n"
      sleep 5
      return 75
    fi
  done
  # PPP options can be used by the next dial without resetting AT state.
  for key in "$@"; do
    case "$key" in
      baud|modem_profile) ;;
      *) printf -v "$key" '%s' "${config_port[$key]}" ;;
    esac
  done
  sendtty "Per-port PPP settings apply on the next dial.\n"
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
    [[ "$modem_profile" == ISDN* ]] && speaker_mode=$speaker_mode_reset_default
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
  if [[ $hcmd == 'Z' ]]; then echoser=$echoser_reset_default; resultverbose=$resultverbose_reset_default; carrierdetect=0; speaker_mode=${speaker_mode_reset_default}; result=0; fi

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
  if [[ $hcmd == '&F' ]]; then echoser=$echoser_reset_default; resultverbose=$resultverbose_reset_default; carrierdetect=0; speaker_mode=${speaker_mode_reset_default}; result=0; fi

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

# Function: emit_fx_linenoise
# Register or stop asynchronous PPP audio using the shared socket functions.
# The daemon handles its own GPIO lease; PPP_START does not acquire a dialing lease.
emit_fx_linenoise () {
  local operation=$1 fifo=$2 duration=${3:-} command status=0

  case "$operation" in
    START)
      [[ -n "$fifo" && -n "$duration" ]] || return 1
      command="PPP_START $fifo $duration"
      ;;
    STOP)
      [[ -n "$fifo" ]] || return 1
      command="PPP_STOP $fifo"
      ;;
    *)
      echo "ERROR: Invalid line noise operation: $operation" >&2
      return 1
      ;;
  esac

  soundd_connect || return 1
  soundd_command "$command" || status=$?
  soundd_disconnect
  return "$status"
}

# Function: emit_fx_dialup
# Acquire atomically, play the complete dial sequence, then release before PPP.
# Return 3 for BUSY, 1 for an audio failure, 0 on success.
emit_fx_dialup () {
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
            # NOTE: this is already prepared for GH Issue #7
            # to support additional handshake types in the future.
            # Once those are implemented, we can simply pass
            # the handshake type through $profile_name
            #
            # #### soundd_command "HANDSHAKE $profile_name $handshake_mode" || status=$?
            #
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
  # note: lo0 and ppp interfaces are filtered
  interfaces=$(printf '%s\n' "$interfaces" | awk '$1 != "lo" && $1 != "lo0" && $1 !~ /^ppp/ { print "* " $0 }')
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
  for entry in "${config_modem_profiles[@]}"; do
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


# -----------------------
# Main
# -----------------------

# export the tty functions
export -f sendtty
export -f readtty
export -f ttyinit
# Reuse the same socket client implementation in PPP child processes.
export -f soundd_connect
export -f soundd_command
export -f soundd_disconnect
export -f emit_fx_linenoise

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
        emit_fx_dialup "$number" || audio_status=$?
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
      setup_status=0
      vmodem_setup serial || setup_status=$?
      if (( setup_status == 75 )); then exit 75; fi
      if (( setup_status != 0 )); then sendtty "Setup ended with an error.\n"; fi
      sendtty "READY.\n"
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
