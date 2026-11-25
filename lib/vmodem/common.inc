#!/usr/bin/env bash
# Shared configuration storage and SETUP menus.

config_appdir=${config_appdir:-/opt/vmodem}
config_defaults=$config_appdir/etc/defaults.conf
config_local=$config_appdir/etc/defaults.conf.local
config_port_dir=$config_appdir/etc/portconfig
config_device=
config_port_file=

declare -A config_builtin=(
  [echoser_reset_default]=1 [resultverbose_reset_default]=1 [TERM]=vt100 [baud]=57600
  [modem_profile]=V34BIS [option_proxyarp]=0 [option_modem_control]=1
  [option_debug]=0 [option_tcstatus]=1 [tc_status_interval]=60
  [lcp_echo_interval]=10 [lcp_echo_failure]=3
  [dns_primary]=9.9.9.9 [dns_secondary]=149.112.112.112
  [dialtone_time]=2 [linenoise_time]=4 [ringback_cycles]=2 [ringback_pause]=3
  [audio_socket]=/run/vmodem/sound.sock [speaker_mode_reset_default]=1
)
config_port_keys=(baud modem_profile option_proxyarp option_modem_control
  option_debug option_tcstatus tc_status_interval lcp_echo_interval lcp_echo_failure)
config_keys=(echoser_reset_default resultverbose_reset_default TERM "${config_port_keys[@]}"
  dns_primary dns_secondary dialtone_time linenoise_time ringback_cycles
  ringback_pause audio_socket speaker_mode_reset_default)
config_modem_profiles=(
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
declare -A config_shipped=() config_global=() config_port=()

config_error() {
  if declare -F sendtty >/dev/null; then
    sendtty "ERROR: $*\n"
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
}

config_copy() {
  local -n _vc_source=$1 _vc_target=$2
  local _vc_key
  _vc_target=()
  for _vc_key in "${!_vc_source[@]}"; do
    _vc_target["$_vc_key"]=${_vc_source[$_vc_key]}
  done
}

# Files are trusted shell assignments, as in the original modem.
# Localize their settings so loading a menu never changes the active modem.
config_overlay() {
  local _vc_path=$1 _vc_map_name=$2 _vc_key
  local -n _vc_map=$_vc_map_name
  shift 2
  [[ -e "$_vc_path" ]] || return 0
  if [[ ! -f "$_vc_path" || ! -r "$_vc_path" ]] || ! bash -n "$_vc_path"; then
    config_error "Cannot read configuration: $_vc_path"
    return 1
  fi
  for _vc_key in "${config_keys[@]}"; do
    local "$_vc_key"
    printf -v "$_vc_key" '%s' "${_vc_map[$_vc_key]}"
  done
  if ! source "$_vc_path"; then
    config_error "Cannot load configuration: $_vc_path"
    return 1
  fi
  for _vc_key in "$@"; do _vc_map["$_vc_key"]=${!_vc_key}; done
}

validate_ipv4() {
  local address=$1 octet
  local -a parts
  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$address"
  for octet in "${parts[@]}"; do
    (( ${#octet} <= 3 && 10#$octet <= 255 )) || return 1
  done
}

validate_uint() {
  [[ "$1" =~ ^[0-9]+$ && ${#1} -le 7 ]] &&
    (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

config_validate() {
  local -n _vc_check=$1
  local key entry id name down up minimum found=0
  for key in option_proxyarp option_modem_control option_debug option_tcstatus echoser_reset_default; do
    [[ "${_vc_check[$key]}" == 0 || "${_vc_check[$key]}" == 1 ]] || {
      config_error "Invalid $key: ${_vc_check[$key]}"; return 1;
    }
  done
  validate_uint "${_vc_check[resultverbose_reset_default]}" 0 2 &&
    validate_uint "${_vc_check[speaker_mode_reset_default]}" 0 3 || {
      config_error 'Invalid result-code or speaker mode.'; return 1;
    }
  validate_uint "${_vc_check[tc_status_interval]}" 1 3600 &&
    validate_uint "${_vc_check[lcp_echo_interval]}" 0 3600 &&
    validate_uint "${_vc_check[lcp_echo_failure]}" 0 100 &&
    validate_uint "${_vc_check[dialtone_time]}" 0 60 &&
    validate_uint "${_vc_check[linenoise_time]}" 1 60 &&
    validate_uint "${_vc_check[ringback_cycles]}" 1 20 &&
    validate_uint "${_vc_check[ringback_pause]}" 0 30 || {
      config_error 'Invalid interval, duration or ringback setting.'; return 1;
    }
  validate_ipv4 "${_vc_check[dns_primary]}" &&
    validate_ipv4 "${_vc_check[dns_secondary]}" || {
      config_error 'Invalid DNS address.'; return 1;
    }
  [[ -n "${_vc_check[TERM]}" && "${_vc_check[audio_socket]}" == /* ]] || {
    config_error 'Terminal type must be nonempty and audio socket must be absolute.'; return 1;
  }
  for entry in "${config_modem_profiles[@]}"; do
    IFS='|' read -r id name down up minimum <<< "$entry"
    if [[ "$id" == "${_vc_check[modem_profile]}" ]]; then
      found=1
      break
    fi
  done
  (( found )) && validate_uint "${_vc_check[baud]}" "$minimum" 230400 || {
    config_error "Invalid baud/profile combination: ${_vc_check[baud]} / ${_vc_check[modem_profile]}"
    return 1
  }
}

config_resolve_port() {
  local properties identity
  properties=$(udevadm info --query=property --name="$1") || {
    config_error "Cannot inspect serial device: $1"; return 1;
  }
  identity=$(printf '%s\n' "$properties" | awk -F= '/^ID_PATH=/ {print substr($0,9); exit}')
  if [[ -z "$identity" || "$identity" == */* || "$identity" == . || "$identity" == .. ]]; then
    config_error "No valid physical USB path found for $1"
    return 1
  fi
  printf '%s/%s.conf\n' "$config_port_dir" "$identity"
}

config_devices() {
  local device
  for device in /dev/ttyUSB* /dev/ttyACM*; do
    [[ -c "$device" ]] && printf '%s\n' "$device"
  done
  return 0
}

config_load() {
  config_copy config_builtin config_shipped
  config_overlay "$config_defaults" config_shipped "${config_keys[@]}" || return 1
  config_validate config_shipped || return 1
  config_copy config_shipped config_global
  config_overlay "$config_local" config_global "${config_keys[@]}" || return 1
  config_validate config_global || return 1
  config_copy config_global config_port
  if [[ -n "$config_port_file" ]]; then
    config_overlay "$config_port_file" config_port "${config_port_keys[@]}" || return 1
  fi
}

config_select_port() {
  local path
  path=$(config_resolve_port "$1") || return 1
  config_device=$1
  config_port_file=$path
  config_load
}

config_apply_runtime() {
  local key
  for key in "${config_keys[@]}"; do printf -v "$key" '%s' "${config_port[$key]}"; done
  echoser=$echoser_reset_default
  resultverbose=$resultverbose_reset_default
  # ISDN enforces ATM0 even after runtime ATM commands; analog profiles default to ATM1.
  # Keep the reset/enforced default separate from the runtime speaker_mode.
  [[ "$modem_profile" == ISDN* ]] && speaker_mode_reset_default=0
  speaker_mode=$speaker_mode_reset_default
  return 0
}

# Reload inherited settings, merge changes, then replace atomically.
# Configuration saves assume one editing session at a time.
config_save() (
  local scope=$1 changes_name=$2 key path directory temporary
  local -n _vc_changes=$changes_name
  local -A inherited=() desired=()
  local -a allowed=()
  config_load || exit 1
  case "$scope" in
    global)
      path=$config_local
      allowed=("${config_keys[@]}")
      config_copy config_shipped inherited
      config_copy config_global desired
      ;;
    port)
      [[ -n "$config_port_file" ]] || { config_error 'No port selected.'; exit 1; }
      path=$config_port_file
      allowed=("${config_port_keys[@]}")
      config_copy config_global inherited
      config_copy config_port desired
      ;;
    *) config_error "Unknown configuration scope: $scope"; exit 1 ;;
  esac
  local candidate found
  for key in "${!_vc_changes[@]}"; do
    found=0
    for candidate in "${allowed[@]}"; do [[ "$candidate" == "$key" ]] && found=1; done
    (( found )) || { config_error "Setting $key is not allowed in $scope configuration."; exit 1; }
    desired["$key"]=${_vc_changes[$key]}
  done
  config_validate desired || exit 1
  directory=${path%/*}
  mkdir -p "$directory" || exit 1
  temporary=$(mktemp "$path.tmp.XXXXXX") || exit 1
  trap 'rm -f -- "$temporary"' EXIT
  if ! {
    for key in "${allowed[@]}"; do
      if [[ "${desired[$key]}" != "${inherited[$key]}" ]]; then
        printf '%s=%q\n' "$key" "${desired[$key]}" || exit 1
      fi
    done
  } > "$temporary"; then
    config_error "Cannot write configuration: $path"
    exit 1
  fi
  mv -f -- "$temporary" "$path" || {
    config_error "Cannot save configuration: $path"; exit 1;
  }
)

# Frontends (that is vmodem.sh and vmodem-config.sh) 
# provide their local implementations of sendtty, readtty and setup_saved.

setup_prompt() {
  sendtty "$2"
  if ! readtty "$1"; then
    sendtty "\nInput closed; leaving setup.\n"
    return 1
  fi
}

setup_commit() {
  local scope=$1 selected_name=$2 key
  shift 2
  local -n _setup_edited=$selected_name _setup_current="config_$scope"
  local -A changes=()
  for key in "$@"; do
    [[ "${_setup_edited[$key]}" == "${_setup_current[$key]}" ]] || changes["$key"]=${_setup_edited[$key]}
  done
  if (( ${#changes[@]} == 0 )); then
    sendtty "Configuration unchanged.\n"
    return 0
  fi
  if ! config_save "$scope" changes; then
    sendtty "ERROR: Configuration was not saved.\n"
    return 0
  fi
  config_load || return 1
  sendtty "Configuration saved.\n"
  setup_saved "$scope" "${!changes[@]}"
}

setup_modem_menu() {
  local scope=$1 selection new_baud entry id name down up minimum
  local -a baud_rates=() profiles=()
  local -A edited=()
  local -n current="config_$scope"
  mapfile -t baud_rates < <(printf '%s\n' "${config_modem_profiles[@]}" | cut -d'|' -f5 | sort -nu)
  sendtty "\n${scope^} Modem Configuration\n"
  [[ "$scope" == port ]] && sendtty "Selected port: $config_device\n"
  sendtty "Current: ${current[baud]} baud, ${current[modem_profile]}\n"
  for id in "${!baud_rates[@]}"; do sendtty "$((id + 1)). ${baud_rates[id]}\n"; done
  setup_prompt selection "0. Cancel\nSelect serial baud rate: " || return 1
  [[ "$selection" == 0 ]] && return 0
  if ! validate_uint "$selection" 1 "${#baud_rates[@]}"; then
    sendtty "Invalid selection.\n"; return 0
  fi
  new_baud=${baud_rates[10#$selection-1]}
  for entry in "${config_modem_profiles[@]}"; do
    IFS='|' read -r id name down up minimum <<< "$entry"
    if (( new_baud >= minimum )); then
      profiles+=("$id")
      sendtty "${#profiles[@]}. $name ($down/$up bps)\n"
    fi
  done
  setup_prompt selection "0. Cancel\nSelect modem profile: " || return 1
  [[ "$selection" == 0 ]] && return 0
  if ! validate_uint "$selection" 1 "${#profiles[@]}"; then
    sendtty "Invalid selection.\n"; return 0
  fi
  edited[baud]=$new_baud
  edited[modem_profile]=${profiles[10#$selection-1]}
  setup_commit "$scope" edited baud modem_profile
}

setup_ppp_menu() {
  local scope=$1 selection input key i
  local heading='Per-port LCP, PPP defaults'
  local -a keys=(option_proxyarp option_debug option_tcstatus tc_status_interval
    lcp_echo_interval lcp_echo_failure option_modem_control)
  local -a labels=('Proxy ARP' 'PPP Debug' 'Traffic Statistics' 'Statistics Interval'
    'LCP Echo Interval' 'LCP Echo Failures' 'Modem Control (DCD)')
  local -A edited=()
  local -n current="config_$scope"
  if [[ "$scope" == global ]]; then
    heading='Global LCP, PPP & IP defaults'
    keys+=(dns_primary dns_secondary)
    labels+=('Primary DNS' 'Secondary DNS')
  fi
  for key in "${keys[@]}"; do edited["$key"]=${current[$key]}; done
  while true; do
    sendtty "\n$heading\n"
    [[ "$scope" == port ]] && sendtty "Selected port: $config_device\n"
    for i in "${!keys[@]}"; do
      sendtty "$((i + 1)). ${labels[i]} : ${edited[${keys[i]}]}\n"
    done
    setup_prompt selection "0. Save and return\nEnter your selection: " || return 1
    [[ "$selection" == 0 ]] && break
    if ! validate_uint "$selection" 1 "${#keys[@]}"; then
      sendtty "Invalid selection.\n"; continue
    fi
    key=${keys[10#$selection-1]}
    case "$key" in
      option_*) edited["$key"]=$((1 - edited[$key])) ;;
      *)
        setup_prompt input "Enter new value: " || return 1
        case "$key" in
          dns_*)
            if validate_ipv4 "$input"; then edited["$key"]=$input
            else sendtty "Invalid IPv4 address.\n"; fi
            ;;
          *)
            local min=0 max=3600
            [[ "$key" == tc_status_interval ]] && min=1
            [[ "$key" == lcp_echo_failure ]] && max=100
            if validate_uint "$input" "$min" "$max"; then edited["$key"]=$((10#$input))
            else sendtty "Invalid value; expected $min..$max.\n"; fi
            ;;
        esac
        ;;
    esac
  done
  setup_commit "$scope" edited "${keys[@]}"
}

setup_wifi_command() {
  local output
  if ! output=$(wpa_cli -i wlan0 "$@" 2>&1); then
    sendtty "ERROR: Wi-Fi command failed: $output\n"
    return 1
  fi
  if printf '%s\n' "$output" | grep -q '^FAIL'; then
    sendtty "ERROR: Wi-Fi command rejected: $output\n"
    return 1
  fi
  setup_wifi_reply=$output
  sendtty "$output\n"
}

setup_wifi_menu() {
  local selection ssid password network_id
  if ! command -v wpa_cli >/dev/null 2>&1; then
    sendtty "ERROR: wpa_cli is not installed.\n"
    return 0
  fi
  while true; do
    setup_prompt selection "\nWi-Fi Settings (wlan0)\n1. Connect to new Wi-Fi network\n2. Modify current password\n3. Disconnect\n4. Display status\n5. Return\nEnter your selection: " || return 1
    case "$selection" in
      1)
        setup_prompt ssid "Enter SSID: " || return 1
        setup_prompt password "Enter password: " || return 1
        if setup_wifi_command add_network; then
          network_id=$setup_wifi_reply
          if ! validate_uint "$network_id" 0 9999999; then
            sendtty "ERROR: Invalid network ID returned by wpa_cli.\n"
            continue
          fi
          if setup_wifi_command set_network "$network_id" ssid "\"$ssid\"" &&
             setup_wifi_command set_network "$network_id" psk "\"$password\"" &&
             setup_wifi_command select_network "$network_id"; then
            setup_wifi_command enable_network "$network_id" || :
          fi
        fi
        ;;
      2)
        setup_prompt password "Enter new password: " || return 1
        if setup_wifi_command status; then
          network_id=$(printf '%s\n' "$setup_wifi_reply" | awk -F= '/^id=/ {print $2; exit}')
          if validate_uint "$network_id" 0 9999999; then
            setup_wifi_command set_network "$network_id" psk "\"$password\"" || :
          else
            sendtty "ERROR: No current Wi-Fi network.\n"
          fi
        fi
        ;;
      3) setup_wifi_command disconnect || : ;;
      4) setup_wifi_command status || : ;;
      5) return 0 ;;
      *) sendtty "Invalid selection.\n" ;;
    esac
  done
}

# Used by the console frontend only, as it's not tied to
# special USB serial dapter.
# The serial frontend on the other hand already knows the
# USB port from systemd startup.
setup_select_port() {
  local device selection path
  local -a connected=() devices=()
  config_device=
  config_port_file=
  mapfile -t connected < <(config_devices)
  for device in "${connected[@]}"; do
    if ! path=$(config_resolve_port "$device"); then
      sendtty "Cannot identify $device; skipping it.\n"
      continue
    fi
    devices+=("$device")
    sendtty "${#devices[@]}. $device (${path##*/})\n"
  done
  if (( ${#devices[@]} == 0 )); then
    sendtty "No identifiable USB serial adapters connected.\n"
    return 0
  fi
  setup_prompt selection "0. Cancel\nSelect physical port: " || return 1
  [[ "$selection" == 0 ]] && return 0
  if ! validate_uint "$selection" 1 "${#devices[@]}"; then
    sendtty "Invalid selection.\n"; return 0
  fi
  config_select_port "${devices[10#$selection-1]}" || return 1
}

vmodem_setup() {
  local frontend=$1 selection status
  config_load || return 1
  while true; do
    sendtty "\nSystem Setup\n============\n\n"
    sendtty "1. Global Wi-Fi settings\n"
    sendtty "2. Global modem defaults\n"
    sendtty "3. Global LCP, PPP & IP defaults\n"
    sendtty "4. Per-port modem settings\n"
    sendtty "5. Per-port LCP & PPP defaults\n"
    setup_prompt selection "0. Exit\nEnter your selection: " || return 1
    status=0
    case "$selection" in
      1) setup_wifi_menu || status=$? ;;
      2) setup_modem_menu global || status=$? ;;
      3) setup_ppp_menu global || status=$? ;;
      4|5)
        if [[ "$frontend" == console ]]; then setup_select_port || return 1; fi
        if [[ -z "$config_port_file" ]]; then
          sendtty "No port selected.\n"
        elif [[ "$selection" == 4 ]]; then setup_modem_menu port || status=$?
        else setup_ppp_menu port || status=$?; fi
        ;;
      0) sendtty "Exited setup.\n"; return 0 ;;
      *) sendtty "Invalid selection.\n" ;;
    esac
    (( status == 0 )) || return "$status"
  done
}
