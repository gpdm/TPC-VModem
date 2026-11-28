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

check_os() {
    # Only Debian 12 (Bookworm) is supported: pigpiod is no longer
    # available as a package on Debian 13 (Trixie).
    # see also Issue #1 on https://github.com/gpdm/TPC-VModem/issues
    [[ -r /etc/os-release ]] || fail 'Cannot detect the operating system (/etc/os-release is missing).'
    . /etc/os-release
    [[ ":${ID:-}:${ID_LIKE:-}:" == *debian* ]] || \
        fail "Unsupported operating system '${ID:-unknown}': a Debian-based system is required."
    [[ "${VERSION_ID:-}" == 12 ]] || \
        fail "Unsupported Debian version '${VERSION_ID:-unknown}': only Debian 12 (Bookworm) is supported at this time."
}

check_dependencies() {
    echo '[1/6] Checking system dependencies'
    local needed=() entry program package

    # Required to run the setup itself, not packages to install.
    command -v apt-get   >/dev/null 2>&1 || fail 'apt-get is required.'
    command -v systemctl >/dev/null 2>&1 || fail 'systemd is required.'
    command -v nmcli     >/dev/null 2>&1 || fail 'NetworkManager with nmcli is required.'

    # Check everything once, then install all missing packages together.
    # format is: program:package
    #
    # NOTE: 3proxy is intentionally not install here via the bootstrap routine.
    # 3proxy depends on cloned repo files, which only become available
    # after the project is cloned.
    # Therefore, 3proxy setup is handled separately after the project is cloned
    # in the config_visp() function.
    for entry in python3:python3 pigpiod:pigpio pppd:ppp git:git \
                 nft:nftables xxd:xxd stty:coreutils sysctl:procps \
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
        printf 'Installing dependencies: %s\n' "${needed[*]}"
        apt-get update --error-on=any
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${needed[@]}" || \
            fail 'Package installation failed.'
    else
        echo 'System dependencies: OK'
    fi

    # Functional check after installation: catch Python environment mismatches.
    python3 -c 'import pigpio' || fail 'Python cannot import pigpio.'
}

fetch_project() {
    echo '[2/6] Fetching project files'

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
            cp -a -- "$APP_DIR/config/." "$clone_tmp/vmodem/etc/portconfig/"
        fi
        rm -rf "$APP_DIR"
    fi
    mv -- "$clone_tmp/vmodem" "$APP_DIR"
    rm -rf "$clone_tmp"
    echo "Installation directory: $APP_DIR"
}

check_project() {
    echo '[3/6] Checking project files'
    local script systemd_dir=/etc/systemd/system

    echo updating permissions ...
    for script in "$APP_DIR"/bin/* "$APP_DIR"/libexec/*; do
        [[ -f "$script" ]] && chmod 755 -- "$script"
    done

    # disable historic startup entries via /etc/rc.local, if present
    if [[ -f /etc/rc.local ]] && grep -Eq '^[[:space:]]*[^#]*vmodem' /etc/rc.local; then
        sed -i.pre-vmodem-setup -E '/^[[:space:]]*[^#]*vmodem/s/^/#/' /etc/rc.local
        echo 'NOTE: Legacy vmodem start entry found in /etc/rc.local'
        echo '      Command was commented out.'
        echo '      (backup saved as /etc/rc.local.pre-vmodem-setup)'
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

    echo 'Project scripts updated'
}

configure_pigpiod() {
    echo '[4/6] Configuring pigpiod'
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

configure_vmodem() {
    echo '[5/6] Installing dynamic VModem systemd services'
    local systemd_dir=/etc/systemd/system
    local udev_rules_dir=/etc/udev/rules.d
    local nm_dir=$APP_DIR/etc/NetworkManager/system-connections
    local nm_profile=$nm_dir/visp-infrastructure.nmconnection

    # Secure the symlink target and its project-owned parent directories.
    chown root:root "$APP_DIR" "$APP_DIR/etc" "$APP_DIR/etc/NetworkManager" "$nm_dir" "$nm_profile"
    chmod go-w "$APP_DIR" "$APP_DIR/etc" "$APP_DIR/etc/NetworkManager" "$nm_dir"
    chmod 600 "$nm_profile"
    ln -sfn "$nm_profile" /etc/NetworkManager/system-connections/visp-infrastructure.nmconnection
    nmcli connection reload || fail 'Could not reload NetworkManager profiles.'

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

    # Register independent PPP hooks before triggering any existing adapters.
    ln -sfn "$APP_DIR/libexec/vmodem-proxy.sh" /etc/ppp/ip-up.d/zz-vmodem-proxy
    ln -sfn "$APP_DIR/libexec/vmodem-proxy.sh" /etc/ppp/ip-down.d/00-vmodem-proxy
    ln -sfn "$APP_DIR/libexec/vmodem-shaper.sh" /etc/ppp/ip-up.d/zz-vmodem-shaper
    ln -sfn "$APP_DIR/libexec/vmodem-shaper.sh" /etc/ppp/ip-down.d/00-vmodem-shaper
    echo 'PPP proxy and traffic shaper hooks installed'

    systemctl daemon-reload
    udevadm control --reload-rules || fail 'Could not reload udev rules.'
    udevadm trigger --action=add --subsystem-match=tty --sysname-match='ttyUSB*' ||
        fail 'Could not trigger existing ttyUSB devices.'
    udevadm trigger --action=add --subsystem-match=tty --sysname-match='ttyACM*' ||
        fail 'Could not trigger existing ttyACM devices.'
    echo 'Dynamic VModem service template and udev rules installed'
}

configure_visp() {
    echo '[6/6] Configuring virtual ISP'
    local architecture machine

    architecture=$(dpkg --print-architecture)
    machine=$(uname -m)
    case "$architecture:$machine" in
        arm64:aarch64|amd64:x86_64|armhf:armv7l|armhf:armv8l|armhf:aarch64)
            ;;
        *)
            printf 'WARNING: 3proxy packages are unsupported on %s (%s); skipping 3proxy installation.\n' \
                "$architecture" "$machine" >&2
            return ;;
    esac

    # Package maintainer scripts start 3proxy:
    # Set permissions for 3proxy configuration and web interface files
    # as otherwise 3proxy may refuse to start due to permission errors.
    chown root:root "$APP_DIR/etc/3proxy/3proxy.cfg"
    chmod 644 "$APP_DIR/etc/3proxy/3proxy.cfg"
    chmod a+rx "$APP_DIR" "$APP_DIR/etc" "$APP_DIR/etc/3proxy" \
        "$APP_DIR/www" "$APP_DIR/www/images"
    chmod 644 "$APP_DIR/www/index.html"
    mkdir -p /etc/systemd/system/3proxy.service.d
    ln -sfn "$APP_DIR/etc/systemd/3proxy.service.d/visp.conf" \
        /etc/systemd/system/3proxy.service.d/visp.conf

    # add the 3rd-party package repository
    ln -sfn "$APP_DIR/etc/apt/sources.list.d/3proxy.sources" \
        /etc/apt/sources.list.d/3proxy.sources

    # installing 3proxy depends on cloned files from the project repository.
    # As these became only available after the initial check_dependencies()
    # and fetch_project() calls, the actual installation of 3proxy
    # is deferred until this point.
    echo 'Installing 3proxy'
    apt-get update --error-on=any
    DEBIAN_FRONTEND=noninteractive apt-get install -y 3proxy || \
        fail '3proxy installation failed.'

    systemctl daemon-reload
    echo 'Virtual ISP (3proxy) configured'
}

(($# == 0)) || fail 'Usage: sudo bash setup.sh'
((EUID == 0)) || fail 'Run as root: sudo bash setup.sh'
check_os

# The working directory may be removed during a legacy migration.
cd /

check_dependencies
fetch_project
check_project
configure_pigpiod
configure_vmodem
configure_visp

echo 'Setup complete.'
