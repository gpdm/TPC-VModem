#!/usr/bin/env bash
# TPC VModem setup, Raspberry Pi OS with systemd.
# Run alongside vmodem.sh, ppp.sh, sound.py and ppp_noise.py.

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDE_FILE=/etc/systemd/system/pigpiod.service.d/zz-tpc-vmodem.conf

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

check_scripts() {
    local missing=() script
    for script in vmodem.sh ppp.sh sound.py ppp_noise.py; do
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
        if [[ ! -f "$OVERRIDE_FILE" ]] || [[ "$(cat "$OVERRIDE_FILE")" != "$config" ]]; then
            mkdir -p "$(dirname "$OVERRIDE_FILE")"
            if [[ -f "$OVERRIDE_FILE" ]]; then
                cp -a "$OVERRIDE_FILE" "$OVERRIDE_FILE.bak.$(date +%Y%m%d%H%M%S)"
            fi
            printf '%s\n' "$config" > "$OVERRIDE_FILE"
            changed=true
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
        changed=true
    fi

    if [[ "$changed" == true ]]; then
        systemctl daemon-reload
    fi
    systemctl enable pigpiod.service >/dev/null

    if [[ "$changed" == true ]]; then
        systemctl restart pigpiod.service || fail 'Could not restart pigpiod. Stop any manually started pigpiod first.'
    else
        systemctl start pigpiod.service || fail 'Could not start pigpiod. Stop any manually started pigpiod first.'
    fi

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

(($# == 0)) || fail 'Usage: sudo bash setup.sh'
((EUID == 0)) || fail 'Run as root: sudo bash setup.sh'

check_scripts
check_dependencies
configure_pigpiod

echo 'Setup complete. The PPP sound cache is managed by vmodem.sh.'
