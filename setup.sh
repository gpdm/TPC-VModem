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
    echo '[1/5] Preparing installation directory'
    mkdir -p "$PROJECT_DIR"
    if [[ "$SOURCE_SCRIPT" != "$PROJECT_DIR/setup.sh" ]]; then
        mv -f -- "$SOURCE_SCRIPT" "$PROJECT_DIR/setup.sh" || fail 'Could not move setup.sh.'
        echo "Moved setup.sh to $PROJECT_DIR"
    fi
    cd -- "$PROJECT_DIR"
    echo "Installation directory: $PROJECT_DIR"
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
    echo '[2/5] Checking project files'
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
    echo '[3/5] Checking system dependencies'
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
    echo '[4/5] Configuring pigpiod'
    local pigpiod_bin config attempt
    pigpiod_bin="$(command -v pigpiod)" || fail 'pigpiod is unavailable.'
    config=$(printf '[Service]\nExecStart=\nExecStart=%s -l -m\n' "$pigpiod_bin")

    if systemctl cat pigpiod.service >/dev/null 2>&1; then
        # Keep the packaged unit; maintain only our drop-in.
        mkdir -p "$(dirname "$PIGPIOD_OVERRIDE_FILE")"
        printf '%s\n' "$config" > "$PIGPIOD_OVERRIDE_FILE"
        echo 'pigpiod: installed systemd override (-l -m)'
    else
        # Source installations may have no packaged systemd unit.
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
        echo 'pigpiod: created systemd service (-l -m)'
    fi

    echo 'pigpiod: enabling and restarting service'
    systemctl daemon-reload
    systemctl enable pigpiod.service
    systemctl restart pigpiod.service || fail 'Could not restart pigpiod. Stop any manually started pigpiod first.'

    echo 'pigpiod: waiting for the daemon to accept connections (up to 10 seconds)'
    for attempt in {1..10}; do
        if python3 -c 'import pigpio, sys; pi = pigpio.pi(); ok = pi.connected; pi.stop(); sys.exit(0 if ok else 1)' >/dev/null 2>&1; then
            echo 'pigpiod: OK'
            return
        fi
        sleep 1
    done
    echo 'WARN: pigpiod did not become reachable. Check: journalctl -u pigpiod -n 30'
}

install_vmodem_service() {
    echo '[5/5] Installing VModem systemd service'
    local unit=/etc/systemd/system/vmodem.service

    if [[ ! -f "$unit" ]] || ! cmp -s "$PROJECT_DIR/vmodem.service" "$unit"; then
        install -m 0644 "$PROJECT_DIR/vmodem.service" "$unit"
        echo 'vmodem.service: installed'
    else
        echo 'vmodem.service: unchanged'
    fi

    if [[ -f /etc/rc.local ]] && grep -Eq '^[[:space:]]*[^#]*vmodem' /etc/rc.local; then
        echo 'WARNING: /etc/rc.local still references vmodem. Remove the old startup entry.' >&2
    fi

    systemctl daemon-reload
    echo 'vmodem.service: enabling and restarting service'
    systemctl enable vmodem.service
    systemctl restart vmodem.service || fail 'Could not start vmodem.service. Check: journalctl -u vmodem -n 30'
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
