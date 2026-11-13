#!/usr/bin/env bash
# TPC VModem audio daemon test client.
# Requires socat. The lease is bound to the socket connection.

set -u
SOCKET=/run/vmodem/sound.sock

usage() {
  cat <<'USAGE'
Usage: vmodem-soundctl.sh [--socket PATH] COMMAND [ARGUMENTS]

Audio commands (automatically acquire and release the lease):
  tone FREQUENCY SECONDS
  dialtone [SECONDS]            default: 2
  dtmf NUMBER
  ringback [CYCLES [PAUSE]]     defaults: 2 cycles, 3 second pause
  v34                         plays handshake, automatically releases lease

Lease testing:
  session                     interactive commands, initial lease not held
  acquire                     enter interactive mode with a lease acquired

Interactive commands:
  acquire, release, abort, tone, dialtone, dtmf, ringback, v34, help, quit

Examples:
  vmodem-soundctl.sh dialtone 2
  vmodem-soundctl.sh dtmf 12345
  vmodem-soundctl.sh ringback 2 3
  vmodem-soundctl.sh v34
  vmodem-soundctl.sh acquire
  vmodem-soundctl.sh session

To test BUSY, keep a lease in one session and run an audio command
in another terminal. Each successful HANDSHAKE releases its lease.
USAGE
}

if [[ "${1:-}" == --socket ]]; then
  [[ $# -ge 3 ]] || { usage >&2; exit 2; }
  SOCKET=$2
  shift 2
fi

command -v socat >/dev/null 2>&1 || { echo 'ERROR: socat is required (sudo apt install socat).' >&2; exit 1; }

read_fd=
write_fd=
orig_read_fd=
orig_write_fd=
conn_pid=
owned=0

close_connection() {
  if [[ -n "$write_fd" ]]; then
    exec {write_fd}>&- 2>/dev/null || true
    write_fd=
  fi
  if [[ -n "$read_fd" ]]; then
    exec {read_fd}<&- 2>/dev/null || true
    read_fd=
  fi
  if [[ -n "$orig_write_fd" ]]; then
    exec {orig_write_fd}>&- 2>/dev/null || true
    orig_write_fd=
  fi
  if [[ -n "$orig_read_fd" ]]; then
    exec {orig_read_fd}<&- 2>/dev/null || true
    orig_read_fd=
  fi
  if [[ -n "$conn_pid" ]]; then
    wait "$conn_pid" 2>/dev/null || true
    conn_pid=
  fi
  owned=0
}
trap close_connection EXIT

connect_socket() {
  [[ -n "$conn_pid" ]] && return 0
  [[ -S "$SOCKET" ]] || { printf 'ERROR: daemon socket not found: %s\n' "$SOCKET" >&2; return 1; }
  coproc SOUND_CONN { socat - "UNIX-CONNECT:$SOCKET"; }
  conn_pid=$SOUND_CONN_PID
  orig_read_fd=${SOUND_CONN[0]}
  orig_write_fd=${SOUND_CONN[1]}
  # Duplicate descriptors so they survive repeated command execution.
  exec {read_fd}<&"$orig_read_fd"
  exec {write_fd}>&"$orig_write_fd"
  # Close the original coprocess descriptors. Otherwise socat never
  # sees EOF on BUSY, and close_connection hangs in wait.
  exec {orig_read_fd}<&-
  exec {orig_write_fd}>&-
  orig_read_fd=
  orig_write_fd=
  return 0
}

request() {
  local response
  [[ -n "$conn_pid" ]] || { echo 'ERROR: not connected' >&2; return 1; }
  if ! printf '%s\n' "$1" >&"$write_fd"; then
    echo 'ERROR: socket write failed' >&2
    close_connection
    return 1
  fi
  if ! IFS= read -r -t 180 response <&"$read_fd"; then
    echo 'ERROR: daemon closed the connection or response timed out' >&2
    close_connection
    return 1
  fi
  printf '%s\n' "$response"
  case "$response" in
    OK|DONE) return 0 ;;
    RELEASED) owned=0; close_connection; return 0 ;;
    BUSY) return 3 ;;
    ERROR*) return 1 ;;
    *) return 1 ;;
  esac
}

acquire_lease() {
  if (( owned )); then
    echo 'Already acquired.'
    return 0
  fi
  connect_socket || return 1
  local reply_status=0
  request 'ACQUIRE' || reply_status=$?
  if (( reply_status == 0 )); then
    owned=1
  else
    close_connection
  fi
  return "$reply_status"
}

release_lease() {
  local action=${1:-RELEASE}
  if (( ! owned )); then
    echo 'No lease held.'
    return 0
  fi
  request "$action"
}

audio_request() {
  local command=${1,,}
  shift
  local message
  case "$command" in
    tone)
      [[ $# == 2 ]] || { echo 'Usage: tone FREQUENCY SECONDS' >&2; return 2; }
      message="TONE $1 $2" ;;
    dialtone)
      [[ $# -le 1 ]] || { echo 'Usage: dialtone [SECONDS]' >&2; return 2; }
      message="DIALTONE ${1:-2}" ;;
    dtmf)
      [[ $# == 1 ]] || { echo 'Usage: dtmf NUMBER' >&2; return 2; }
      message="DTMF $1" ;;
    ringback)
      [[ $# -le 2 ]] || { echo 'Usage: ringback [CYCLES [PAUSE]]' >&2; return 2; }
      message="RINGBACK ${1:-2} ${2:-3}" ;;
    v34)
      [[ $# == 0 ]] || { echo 'Usage: v34' >&2; return 2; }
      message='HANDSHAKE V34' ;;
    *) echo "Unknown audio command: $command" >&2; return 2 ;;
  esac
  if (( ! owned )); then
    echo 'ERROR: acquire a lease first.' >&2
    return 1
  fi
  request "$message"
}

interactive() {
  local line action
  local -a args
  echo 'Audio daemon test session. Type help for commands.'
  while true; do
    if (( owned )); then
      printf 'soundctl [owned]> '
    else
      printf 'soundctl [free]> '
    fi
    IFS= read -r line || break
    read -r -a args <<< "$line"
    ((${#args[@]})) || continue
    action=${args[0],,}
    case "$action" in
      help|?) usage ;;
      quit|exit) break ;;
      acquire) acquire_lease || true ;;
      release) release_lease RELEASE || true ;;
      abort) release_lease ABORT || true ;;
      tone|dialtone|dtmf|ringback|v34) audio_request "$action" "${args[@]:1}" || true ;;
      *) echo 'Unknown command. Type help.' ;;
    esac
  done
}

main() {
  local action=${1:-help} rc=0
  shift || true
  case "$action" in
    help|-h|--help) usage ;;
    session) [[ $# == 0 ]] || { usage >&2; return 2; }; interactive ;;
    acquire)
      [[ $# == 0 ]] || { usage >&2; return 2; }
      acquire_lease || return $?
      interactive ;;
    tone|dialtone|dtmf|ringback|v34)
      # Validate arguments before taking a lease.
      local message
      case "$action" in
        tone) [[ $# == 2 ]] || { usage >&2; return 2; } ;;
        dialtone|dtmf) [[ $# -le 1 ]] || { usage >&2; return 2; } ;;
        ringback) [[ $# -le 2 ]] || { usage >&2; return 2; } ;;
        v34) [[ $# == 0 ]] || { usage >&2; return 2; } ;;
      esac
      acquire_lease || return $?
      audio_request "$action" "$@" || rc=$?
      (( owned )) && release_lease RELEASE || true
      return "$rc" ;;
    *) usage >&2; return 2 ;;
  esac
}
main "$@"
