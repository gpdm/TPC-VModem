# TPC-VModem

TPC-VModem is a virtual Hayes compatible modem implementation intended to run on a Raspberry Pi and provide dial up style connectivity to retro computers over a serial connection.

This project was inspired by the excellent [Virtual Modem guide by Steptail](https://www.steptail.com/guides:virtual_modem) and builds on the original scripts, extending their functionality a bit.

The original implementation provides a simple and clever way to accept Hayes commands, map dialed numbers to scripts, and hand a connection over to `pppd`.

TPC-VModem takes that idea further.

The goal is not only to make the connection work, but to make it feel a little more like using a real modem, that is *with sound*!

And what's more fun than a Raspberry Pi emulating one modem?
Right, *a Raspberry Pi emulating many modems*!

## Architecture

TPC-VModem 2.0 supports multiple USB serial adapters.
Each adapter gets its own modem instance, while networking and audio are shared between them.

```text
  USB serial adapter (ttyUSB* / ttyACM*)
                   |
              udev / systemd
                   |
             vmodem@.service
                   |
                vmodem.sh
              (Hayes / ATD)
                   |
          +--------+---------+
          |                  |
          v                  v
    Dialing audio       NUMBER.sh or ppp.sh
          |                  |
          |                 pppd
          |                  |
          |              Record FIFO
          |                  |
          +--------+---------+
                   |
             Unix socket
          /run/vmodem/sound.sock
                   |
            vmodem-soundd.py
          (audio + FIFO reader)
                   |
                pigpiod
                   |
                 GPIO18
                   |
                Speaker

  vmodem-network.service: IP forwarding / NAT
  CNI host-local:           PPP address allocation
  vmodem-shaper.sh:         PPP traffic shaping
```

The `99-vmodem.rules` udev rules start `vmodem@ttyUSB0.service`, `vmodem@ttyUSB1.service` and so on when adapters appear. The modem instances depend on `pigpiod`, `vmodem-network.service` and `vmodem-soundd.service`. systemd starts those shared services when needed. Removing a USB serial adapter stops its vmodem instance.

`vmodem.sh` handles Hayes commands, modem settings and dialing. A number specific `NUMBER.sh` takes precedence, otherwise the call is handed over to `ppp.sh`. Modem configuration and PPP settings can be saved per physical USB port.

`vmodem-network.service` sets up the shared IP forwarding and NAT rules. `ppp.sh` uses CNI host-local to allocate a separate IP address for each connection, then starts `pppd`. The PPP hooks in `vmodem-shaper.sh` apply the selected modem profile's upstream and downstream rates to each PPP interface.

### Sound

All audio is generated directly through Raspberry Pi GPIO18, using `pigpiod`. No sound card is needed. The V.34 handshake uses a prepared audio cache, while PPP line noise is either synthesized live or played from a precomputed cache on the original Raspberry Pi 1.

`vmodem-soundd.py` is the central audio daemon. It generates dial tone, DTMF, ringback and the V.34 handshake, and also contains the PPP noise reader. Clients communicate through `/run/vmodem/sound.sock`. The daemon owns GPIO18 and makes sure only one sound sequence uses it at a time. If the audio output is busy, PPP recording can continue without sound.

During PPP, `pppd` writes its record stream into a FIFO. The daemon reads that stream and uses the traffic to influence the simulated modem noise. After the sound has stopped, the reader keeps draining the FIFO until the PPP session ends. Otherwise `pppd` could get stuck writing to it.

And yes, *ATM* commands are fully honored.

| Hayes Command | Dial Tone | DTMF | Ringback | Handshake | PPP Line Noise |
|---------------|-----------|------|----------|-----------|----------------|
| `ATM0` | No | No | No | No | No |
| `ATM1` (default) | Yes | Yes | Yes | Yes | 4 seconds (configurable)* |
| `ATM2` | Yes | Yes | Yes | Yes | Continuous* |
| `ATM3` | No | No | Yes | Yes | No |

*Continuous PPP line noise is only available with one active modem on Raspberry Pi 2 or newer. With multiple modems, PPP line noise audio is limited to 2 seconds, even in ATM2 mode.
Raspberry Pi 1 uses a precomputed cache for performance reasons.

ISDN profiles do not generate analog modem audio, regardless of the ATM setting (ATM0 is enforced).

For testing there is also `vmodem-soundctl.sh`, a small shell client for the audio socket. It can play individual effects and test the exclusive audio lease, without establishing a modem connection:

```bash
cd /opt/vmodem/bin
./vmodem-soundctl.sh dialtone 2
./vmodem-soundctl.sh dtmf 12345
./vmodem-soundctl.sh v34
./vmodem-soundctl.sh acquire
```

The sound daemon has two explicit modes:

```bash
python3 /opt/vmodem/libexec/vmodem-soundd.py --daemon
python3 /opt/vmodem/libexec/vmodem-soundd.py --prepare-noise-cache
```

The first runs the server in the foreground (normally started by systemd).
The second prepares the PPP noise cache for Raspberry Pi 1.

## Changes From Original VModem

* Added dial tone, DTMF, ringback and a V.34 handshake.
* Added a central audio daemon, including PPP line noise based on the recorded data stream.
* Added dynamic USB serial adapter handling and multiple modem instances via udev and systemd.
* Added per port modem configuration, CNI address allocation and PPP traffic shaping.
* Added `setup.sh` to install the dependencies and system services.
* Kept the original number based script routing, with `ppp.sh` as the default.

## Required Hardware

Besides a Raspberry Pi and a retro computer with a serial port, you'll need:

* A USB to RS232 serial adapter, preferably FTDI based.
* A **fully wired null modem cable**, including the handshake signals (RTS/CTS, DTR/DSR and DCD). A simple three wire cable is not sufficient.
* For audio output: 1 x 8ohm 1/4W speaker, 1 x 1N4148 diode, 1 x 47ohm resistor, 1 x 1kohm resistor, 1 x 2N5551 transistor connected to GPIO18 using the circuit shown below.

### USB Serial Adapters

Not all USB serial adapters behave equally well, especially on the older Raspberry Pis.

| Chipset | Recommendation | Notes |
|---------|----------------|-------|
| FTDI FT232R / FT232RL | **Preferred** | Reliable Linux driver (`ftdi_sio`). My first choice. |
| Silicon Labs CP2102 / CP2104 | Good alternative | Well supported by the `cp210x` driver. |
| WCH CH340 / CH341 | Usable | Supported by Linux, but compatibility should be tested. |
| Prolific PL2303 | Not recommended | Some older revisions and clones can cause problems with serial communication. |

I'd recommend using a genuine FTDI adapter, particularly when running TPC-VModem on a Raspberry Pi 1 or 2.

### Prolific Adapters and Older Raspberry Pis

The Raspberry Pi 1, 2, 3 and Zero families use an older USB controller which can be sensitive to certain USB serial devices.

If you experience dropped characters, stalled serial communication or unreliable PPP connections with a Prolific adapter, the following kernel parameters may help:

```text
dwc_otg.fiq_fsm_enable=0 dwc_otg.nak_holdoff=1
```

Add them to `/boot/firmware/cmdline.txt` on Raspberry Pi OS Bookworm, keeping everything on a **single line**, then reboot.

These settings affect the USB controller and are a workaround, not a universal fix. They are not needed for the normal USB ports on Raspberry Pi 4.

If possible, try a different USB serial adapter first.

**One more thing:** Make sure your null modem cable actually carries the handshake signals. Many cheap cables only connect TX, RX and GND. They may work with a terminal but cause problems when modem control signals are involved.

### Wiring Diagram for Speaker via GPIO

All audio is emitted through a simple speaker connected to GPIO.
No extra hardware like an audio hat is required.

But you must do some soldering. Schematics below.
I'm lazy, so it's just some cheap ASCII art, sorry!

```text
Raspberry Pi GPIO Pins:

Pin  2: +5V
Pin  6: GND
Pin 12: GPIO 18


                   +5V (Pin 2)
                        |
                   [ R 47ohm ]
                        |
               +--------+--------+
               |                 |
               |              Cathode
               |               (Ring)
               |                 |
            Speaker           1N4148
            8R / 0.5W            |
               |               Anode
               |                 |
               +--------+--------+
                        |
                        C
                     +-----+
                     |     |
GPIO 18 --[ R 1K ]---| B   | 2N5551
(Pin 12)             |     |
                     +-----+
                        E
                        |
                   GND (Pin 6)
```


An optional 47 kOhm pull-down resistor between the transistor's
`base` (*B*) and `emitter` (*E*) helps keep the speaker silent while GPIO18
is not yet configured, particularly during system startup.

It's not strictly required, but if you hear some unexpected clicking noise,
this may help.

```text
 GPIO18 (Pin 12)
       |
      [1k]
       |
       +------------ B
       |             |
     [47k]         2N5551
       |             |
       +------------ E
       |
      GND
```


## Installation

**Current platform:** Raspberry Pi OS based on Debian 12 (Bookworm). The implementation has not yet been adapted for Raspberry Pi OS based on Debian 13 (Trixie).

TPC-VModem provides a setup script which does the heavy lifting for you:

```bash
cd /tmp
wget https://raw.githubusercontent.com/gpdm/TPC-VModem/refs/heads/v2/setup.sh
sudo bash setup.sh
```

The script clones the project into `/opt/vmodem`, checks dependencies, configures `pigpiod`, and symlinks the systemd services and udev rules from `/opt/vmodem/etc/` into the system directories. Modem instances are started when a supported USB serial adapter is detected.

Updating an existing installation works the same way: re-running `setup.sh` performs a `git pull` in `/opt/vmodem` and refreshes the system integration. Since the systemd units and udev rules are symlinks into `/opt/vmodem/etc/`, a plain `git pull` already updates them in place; run `systemctl daemon-reload` (and `udevadm control --reload-rules`) afterwards for changed units to take effect.


## Configuration

Most settings can be changed from the serial terminal. 

Use `ATI` to display system uptime, network interfaces and the current modem settings.
`HELP` lists the supported commands.
Type `SETUP` at the modem prompt to enter config mode.

There is normally no need to edit the hardcoded defaults in `vmodem.sh` or `ppp.sh`.
All relevant options are available through the `SETUP` menu.


```text
System Setup
============

Current Modem Configuration
Baud Rate : 57600
Emulation : V.34bis (33600/33600 bps)

1. Modem Configuration
2. PPP Configuration
3. Wi-Fi Settings
4. Exit

Enter your selection:
```

Configurations are stored in `/opt/vmodem/portconfig/` and tied to the **physical USB port** (the udev `ID_PATH`), not the serial adapter itself. You can replace an adapter in the same port and keep its settings. Moving it to another port gives it that port's configuration instead. The `ttyUSB0` / `ttyUSB1` numbering is not used to identify the saved configuration.

### Modem Configuration

The default serial baud rate is **57600**, and the default modem profile is **V.34bis** (33600/33600 bps). The baud rate controls the serial link between the retro computer and the Raspberry Pi.

Choose the serial baud rate first, then select a modem profile. Only profiles supported by the selected baud rate are shown.

The modem profile determines the emulated connection speed as per the table below:

| Profile | Modem Standard | Downstream (bps) | Upstream (bps) | Minimum DTE Baud Rate |
|---------|----------------|-----------------:|---------------:|----------------------:|
| V21 | V.21 | 300 | 300 | 9600 |
| V22 | V.22 | 1200 | 1200 | 9600 |
| V22BIS | V.22bis | 2400 | 2400 | 9600 |
| V32 | V.32 | 9600 | 9600 | 19200 |
| V32BIS | V.32bis | 14400 | 14400 | 19200 |
| V34 | V.34 | 28800 | 28800 | 38400 |
| V34BIS | V.34bis | 33600 | 33600 | 57600 |
| V90 | V.90 | 56000 | 33600 | 115200 |
| X2 | X2 | 56000 | 33600 | 115200 |
| K56flex | K56flex | 56000 | 33600 | 115200 |
| V92 | V.92 | 56000 | 48000 | 115200 |
| ISDN64 | ISDN 64k | 64000 | 64000 | 115200 |
| ISDN128 | ISDN 128k | 128000 | 128000 | 230400 |

Please note that TPC-Vmodem does net yet emulate handshakes audio other than V.34.
For now, you'll always hear a V.34 handshake for every profile.

If either setting changes, the modem saves the configuration and restarts after **10 seconds**.
If you changed the baud rate, remember to change it on your terminal and modem settings as well.

### PPP Configuration

The second menu contains the PPP options. These are the defaults:

```text
PPP Configuration
=================

1. Proxy ARP           : Disabled
2. PPP Debug           : Disabled
3. Traffic Statistics  : Enabled
4. Statistics Interval : 60 seconds
5. LCP Echo Interval   : 10 seconds
6. LCP Echo Failures   : 3
7. Primary DNS         : 9.9.9.9
8. Secondary DNS       : 149.112.112.112
9. Modem Control (DCD) : Enabled
0. Save and return

Enter your selection:
```

| Setting | What it does |
|---------|--------------|
| Proxy ARP | Enables `pppd` proxy ARP. Usually not needed with NAT. |
| PPP Debug | Enables additional `pppd` debugging output. |
| Traffic Statistics | Prints traffic shaping statistics to the journal. |
| Statistics Interval | How often the statistics are printed, in seconds. |
| LCP Echo Interval | Time between PPP LCP echo requests. `0` disables them. |
| LCP Echo Failures | Number of unanswered LCP echoes before the connection is considered lost. |
| Primary / Secondary DNS | DNS server addresses offered to the connected computer. |
| Modem Control (DCD) | Uses modem control signals with `pppd`, or local mode when disabled. |

## Debugging

All TPC-VModem services use a separate journald namespace called `vmodem`.
It's by default limited to 100 MB, to not take up too much disk space on the RPi's SD card.

```bash
# All TPC-VModem logs
journalctl --namespace=vmodem -f

# One modem instance
journalctl --namespace=vmodem -u 'vmodem@ttyUSB0.service' -f

# Shared network service
journalctl --namespace=vmodem -u vmodem-network.service

# Audio daemon
journalctl --namespace=vmodem -u vmodem-soundd.service -f

# Journal disk usage
journalctl --namespace=vmodem --disk-usage
```

To check which services are running:

```bash
systemctl status 'vmodem@ttyUSB0.service'
systemctl status vmodem-soundd.service
```

## Acknowledgements

TPC-VModem builds upon the original VMODEM work by Oliver Molini, created between 2020 and 2022.

Thanks also go to Billy Stoughton II for bug fixes and contributions to the original project, and to Hamish for helping test Windows 2000 compatibility.

## License

The original VMODEM implementation is licensed under the Creative Commons Attribution NonCommercial ShareAlike 4.0 International license.

TPC-VModem is distributed under the same license.

## References

* Original [Virtual Modem guide](https://www.steptail.com/guides:virtual_modem)
* Original [Virtual Modem scripts](https://www.steptail.com/guides:virtual_modem:script)
* Original [V.34 handshake generator by serg123e](https://github.com/serg123e/v34handshake)
