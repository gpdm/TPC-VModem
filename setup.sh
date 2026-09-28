#!/usr/bin/env bash
# TPC VModem setup, Raspberry Pi OS with systemd.
# Installs in /opt/vmodem, downloads missing files, and configures dependencies.

set -euo pipefail

PROJECT_DIR=/opt/vmodem
SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
GITHUB_RAW=https://raw.githubusercontent.com/gpdm/TPC-VModem/main
PIGPIOD_OVERRIDE_FILE=/etc/systemd/system/pigpiod.service.d/zz-tpc-vmodem.conf

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

move_setup() {
    mkdir -p "$PROJECT_DIR"
    if [[ "$SOURCE_SCRIPT" != "$PROJECT_DIR/setup.sh" ]]; then
        mv -f -- "$SOURCE_SCRIPT" "$PROJECT_DIR/setup.sh" || fail 'Could not move setup.sh.'
        echo "Moved setup.sh to $PROJECT_DIR"
    fi
    cd -- "$PROJECT_DIR"
}

download_scripts() {
    local script tmp

    # Only needed for a fresh or incomplete installation.
    if ! command -v curl >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || fail 'apt-get is required to install curl.'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl || fail 'Could not install curl.'
    fi

    for script in "$@"; do
        echo "Downloading $script"
        tmp="$(mktemp "$PROJECT_DIR/.${script}.XXXXXX")"
        if ! curl -fLsS --retry 2 "$GITHUB_RAW/$script" -o "$tmp" || [[ ! -s "$tmp" ]]; then
            rm -f -- "$tmp"
            fail "Could not download $script from $GITHUB_RAW"
        fi
        mv -- "$tmp" "$PROJECT_DIR/$script"
    done
}

check_scripts() {
    local missing=() script
    for script in vmodem.sh ppp.sh sound.py ppp_noise.py vmodem.service; do
        [[ -f "$PROJECT_DIR/$script" ]] || missing+=("$script")
    done
    if ((${#missing[@]})); then
        download_scripts "${missing[@]}"
    fi
    # Apply permissions to both existing and newly downloaded scripts.
    for script in "$PROJECT_DIR"/*.sh "$PROJECT_DIR"/*.py; do
        [[ -f "$script" ]] && chmod 755 -- "$script"
    done
    echo 'Project scripts: OK (mode 755)'
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
    local temp
    temp="$(mktemp)"

    # Accept either the old /boot unit or a newer /opt unit from GitHub.
    sed 's|/boot/vmodem|/opt/vmodem|g' "$PROJECT_DIR/vmodem.service" > "$temp"
    if ! grep -Fqx "WorkingDirectory=$PROJECT_DIR" "$temp" || \
       ! grep -Fqx "ExecStart=/bin/bash $PROJECT_DIR/vmodem.sh" "$temp"; then
        rm -f -- "$temp"
        fail 'vmodem.service has unexpected paths. Expected /opt/vmodem.'
    fi

    if [[ ! -f "$unit" ]] || ! cmp -s "$temp" "$unit"; then
        install -m 0644 "$temp" "$unit"
        systemctl daemon-reload
        # Restart only if an older systemd instance is already running.
        systemctl try-restart vmodem.service
        echo 'vmodem.service: installed'
    else
        echo 'vmodem.service: unchanged'
    fi
    rm -f -- "$temp"

    if [[ -f /etc/rc.local ]] && grep -Eq '^[[:space:]]*[^#]*vmodem' /etc/rc.local; then
        echo 'WARNING: /etc/rc.local still references vmodem. Remove the old startup entry.' >&2
    fi

    systemctl enable --now vmodem.service >/dev/null
    echo 'vmodem.service: enabled and started'
}

(($# == 0)) || fail 'Usage: sudo bash setup.sh'
((EUID == 0)) || fail 'Run as root: sudo bash setup.sh'
move_setup

check_scripts
check_dependencies
configure_pigpiod
install_vmodem_service

echo 'Setup complete.'
