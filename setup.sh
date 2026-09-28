#!/usr/bin/env bash
# TPC VModem setup, Raspberry Pi OS with systemd.
# Run alongside vmodem.sh, ppp.sh, sound.py and ppp_noise.py.

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PIGPIOD_OVERRIDE_FILE=/etc/systemd/system/pigpiod.service.d/zz-tpc-vmodem.conf

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

check_scripts() {
    local missing=() script
    for script in vmodem.sh ppp.sh sound.py ppp_noise.py vmodem.service; do
        [[ -f "$PROJECT_DIR/$script" ]] || missing+=("$script")
    done
    ((${#missing[@]} == 0)) || fail "Missing project scripts: ${missing[*]}"
    echo 'Project scripts: OK'
}

check_dependencies() {
    local needed=() entry program package

    # Required to run the setup itself, not packages to install.
    command -v apt-get   >/dev/null 2>&1 || fail 'apt-get is required.'
    command -v systemctl >/dev/null 2>&1 || fail 'systemd is required.'

    # Check everything once, then install all missing packages together.
    for entry in python3:python3 pigpiod:pigpio pppd:ppp \
                 iptables:iptables xxd:xxd stty:coreutils sysctl:procps; do
        program=${entry%%:*}
        package=${entry#*:}
        command -v "$program" >/dev/null 2>&1 || needed+=("$package")
    done

    if ! command -v python3 >/dev/null 2>&1 || \
       ! python3 -c 'import pigpio' >/dev/null 2>&1; then
        needed+=(python3-pigpio)
    fi

    # Wi-Fi tools are needed only when vmodem.sh is configured for wlan0.
    if grep -Eq '^[[:space:]]*etherp=wlan0([[:space:]]|$)' "$PROJECT_DIR/vmodem.sh" && \
       ! command -v wpa_cli >/dev/null 2>&1; then
        needed+=(wpasupplicant)
    fi

    if ((${#needed[@]})); then
        printf 'Installing missing packages: %s\n' "${needed[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${needed[@]}" || \
            fail 'Package installation failed.'
    else
        echo 'System dependencies: OK'
    fi

    # Functional check after installation: catch Python environment mismatches.
    python3 -c 'import pigpio' || fail 'Python cannot import pigpio.'
}

configure_pigpiod() {
    local pigpiod_bin config changed=false
    pigpiod_bin="$(command -v pigpiod)" || fail 'pigpiod is unavailable.'

    config=$(printf '[Service]\nExecStart=\nExecStart=%s -l -m\n' "$pigpiod_bin")

    if systemctl cat pigpiod.service >/dev/null 2>&1; then
        # Preserve the packaged service, modify only our own drop-in.
        if [[ ! -f "$PIGPIOD_OVERRIDE_FILE" ]]; then
            mkdir -p "$(dirname "$PIGPIOD_OVERRIDE_FILE")"
            printf '%s\n' "$config" > "$PIGPIOD_OVERRIDE_FILE"
        fi
    else
        # Source installations may provide pigpiod without a systemd unit.
        cat > /etc/systemd/system/pigpiod.service <<UNIT
[Unit]
Description=pigpio daemon for TPC VModem

[Service]
Type=forking
ExecStart=$pigpiod_bin -l -m
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    fi

    systemctl daemon-reload
    systemctl enable pigpiod.service >/dev/null
    systemctl restart pigpiod.service || fail 'Could not restart pigpiod. Stop any manually started pigpiod first.'

    # One functional check, rather than repeating systemctl status checks.
    python3 - <<'PY'
import pigpio
pi = pigpio.pi('127.0.0.1')
try:
    if not pi.connected:
        raise SystemExit('ERROR: pigpiod is not accepting local connections.')
finally:
    pi.stop()
PY
    echo 'pigpiod: OK (automatic startup, -l -m)'
}

install_vmodem_service() {
    local unit=/etc/systemd/system/vmodem.service

    if [[ ! -f "$unit" ]] || ! cmp -s "$PROJECT_DIR/vmodem.service" "$unit"; then
        install -m 0644 "$PROJECT_DIR/vmodem.service" "$unit"
        systemctl daemon-reload
        echo 'vmodem.service: installed'
    else
        echo 'vmodem.service: unchanged'
    fi

    if [[ -f /etc/rc.local ]] && grep -Eq '^[[:space:]]*[^#]*vmodem' /etc/rc.local; then
        echo 'WARNING: /etc/rc.local still references vmodem. Remove the old startup entry.' >&2
    fi

    systemctl enable --now vmodem.service >/dev/null
    echo 'vmodem.service: enabled and started'
}

(($# == 0)) || fail 'Usage: sudo bash setup.sh'
((EUID == 0)) || fail 'Run as root: sudo bash setup.sh'
[[ "$PROJECT_DIR" == /boot/vmodem ]] || \
    fail 'Install this project in /boot/vmodem (path used by vmodem.service).'

check_scripts
check_dependencies
configure_pigpiod
install_vmodem_service

echo 'Setup complete.'
