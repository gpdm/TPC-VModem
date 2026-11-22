#!/usr/bin/env bash
#
# TPC-VModem - Installation and system configuration
#
# Installs project files, system dependencies and systemd services.
#
# Developed for TPC-VModem:
#   Gianpaolo Del Matto (THE PHINTAGE COLLECTOR), 2026
#
# Part of TPC-VModem, an extension of Oliver Molini's original
# VMODEM project (2020-2022).
#
# License: Creative Commons Attribution-NonCommercial-ShareAlike 4.0
# https://creativecommons.org/licenses/by-nc-sa/4.0/
#
set -euo pipefail

APP_DIR=/opt/vmodem
GIT_REPO=https://github.com/gpdm/TPC-VModem.git
GIT_BRANCH=v2
PIGPIOD_OVERRIDE_FILE=/etc/systemd/system/pigpiod.service.d/zz-tpc-vmodem.conf

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

fetch_project() {
    echo '[1/5] Fetching project files'

    # git is required before the regular dependency check runs.
    if ! command -v git >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || fail 'apt-get is required to install git.'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y git || fail 'Could not install git.'
    fi

    if [[ -d "$APP_DIR/.git" ]]; then
        echo "Updating existing installation in $APP_DIR"
        git -C "$APP_DIR" fetch origin || fail 'Could not fetch updates.'
        git -C "$APP_DIR" checkout "$GIT_BRANCH" || fail "Could not switch to branch $GIT_BRANCH."
        git -C "$APP_DIR" pull --ff-only origin "$GIT_BRANCH" || fail 'Could not update the working tree.'
        echo "Installation directory: $APP_DIR"
        return
    fi

    # Fresh installation, or migration of a legacy flat installation.
    local clone_tmp
    clone_tmp="$(mktemp -d /opt/.vmodem-clone.XXXXXX)" || fail 'Could not create a temporary directory.'
    if ! git clone --branch "$GIT_BRANCH" "$GIT_REPO" "$clone_tmp/vmodem"; then
        rm -rf "$clone_tmp"
        fail "Could not clone $GIT_REPO"
    fi

    if [[ -d "$APP_DIR" ]]; then
        echo 'Migrating legacy flat installation'
        # Keep existing per-port configurations.
        if [[ -d "$APP_DIR/config" ]]; then
            mv -- "$APP_DIR/config" "$clone_tmp/vmodem/portconfig"
        fi
        rm -rf "$APP_DIR"
    fi
    mv -- "$clone_tmp/vmodem" "$APP_DIR"
    rm -rf "$clone_tmp"
    echo "Installation directory: $APP_DIR"
}

check_project() {
    echo '[2/5] Checking project files'
    local script

    mkdir -p "$APP_DIR/portconfig"

    echo updating permissions ...
    for script in "$APP_DIR"/bin/* "$APP_DIR"/libexec/*; do
        [[ -f "$script" ]] && chmod 755 -- "$script"
    done

    echo 'Project scripts updated'
}

check_dependencies() {
    echo '[3/5] Checking system dependencies'
    local needed=() entry program package

    # Required to run the setup itself, not packages to install.
    command -v apt-get   >/dev/null 2>&1 || fail 'apt-get is required.'
    command -v systemctl >/dev/null 2>&1 || fail 'systemd is required.'

    # Check everything once, then install all missing packages together.
    # format is: program:package
    for entry in python3:python3 pigpiod:pigpio pppd:ppp git:git \
                 iptables:iptables xxd:xxd stty:coreutils sysctl:procps \
                 /usr/lib/cni/host-local:containernetworking-plugins \
                 tc:iproute2 jq:jq wpa_cli:wpasupplicant; do
        program=${entry%%:*}
        package=${entry#*:}
        command -v "$program" >/dev/null 2>&1 || needed+=("$package")
    done

    if ! command -v python3 >/dev/null 2>&1 || \
       ! python3 -c 'import pigpio' >/dev/null 2>&1; then
        needed+=(python3-pigpio)
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
Description=pigpio daemon for TPC-VModem

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

install_vmodem_services() {
    echo '[5/5] Installing dynamic VModem systemd services'
    local systemd_dir=/etc/systemd/system
    local udev_rules_dir=/etc/udev/rules.d

    # check if historic startup via /etc/rc.local exists
    if [[ -f /etc/rc.local ]] && grep -Eq '^[[:space:]]*[^#]*vmodem' /etc/rc.local; then
        echo 'WARNING: /etc/rc.local still references vmodem.' >&2
        echo 'Please remove the old startup entry manually!' >&2
    fi

    # check if legacy vmodem service exists
    echo 'Migrating legacy vmodem.service, if present'
    if systemctl is-active --quiet vmodem.service > /dev/null 2>&1; then
        systemctl stop vmodem.service || fail 'Could not stop legacy vmodem.service.'
    fi
    if systemctl is-enabled --quiet vmodem.service > /dev/null 2>&1; then
        systemctl disable vmodem.service || fail 'Could not disable legacy vmodem.service.'
    fi
    [ -f "${systemd_dir}/vmodem.service" ] && rm -f "${systemd_dir}/vmodem.service"

    # configure common logspace for vmodem
    ln -sfn "$APP_DIR/etc/systemd/journald@vmodem.conf" "/etc/systemd/journald@vmodem.conf"
    if systemctl is-active --quiet systemd-journald@vmodem.service; then
        systemctl restart systemd-journald@vmodem.service
    fi

    # install systemd and udev rules for dynamic VModem
    ln -sfn "$APP_DIR/etc/systemd/vmodem@.service" "${systemd_dir}/vmodem@.service"
    ln -sfn "$APP_DIR/etc/systemd/vmodem-network.service" "${systemd_dir}/vmodem-network.service"
    ln -sfn "$APP_DIR/etc/systemd/vmodem-soundd.service" "${systemd_dir}/vmodem-soundd.service"
    ln -sfn "$APP_DIR/etc/udev/99-vmodem.rules" "${udev_rules_dir}/99-vmodem.rules"
    systemctl daemon-reload
    udevadm control --reload-rules || fail 'Could not reload udev rules.'
    udevadm trigger --action=add --subsystem-match=tty --sysname-match='ttyUSB*' ||
        fail 'Could not trigger existing ttyUSB devices.'
    udevadm trigger --action=add --subsystem-match=tty --sysname-match='ttyACM*' ||
        fail 'Could not trigger existing ttyACM devices.'
    echo 'Dynamic VModem service template and udev rules installed'

    # install ppp if-up/if-down hooks for VModem traffic shaping
    ln -sfn "$APP_DIR/libexec/vmodem-shaper.sh" /etc/ppp/ip-up.d/zz-vmodem-shaper
    ln -sfn "$APP_DIR/libexec/vmodem-shaper.sh" /etc/ppp/ip-down.d/00-vmodem-shaper
    echo 'PPP traffic shaper installed'
}

(($# == 0)) || fail 'Usage: sudo bash setup.sh'
((EUID == 0)) || fail 'Run as root: sudo bash setup.sh'

# The working directory may be removed during a legacy migration.
cd /

fetch_project
check_project
check_dependencies
configure_pigpiod
install_vmodem_services

echo 'Setup complete.'
