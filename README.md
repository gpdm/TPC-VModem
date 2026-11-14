# TPC-VModem

TPC-VModem is a virtual Hayes compatible modem implementation intended to run on a Raspberry Pi and provide dial up style connectivity to retro computers over a serial connection.

This project was inspired by the excellent [Virtual Modem guide by Steptail](https://www.steptail.com/guides:virtual_modem) and builds on the original scripts, extending their functionality a bit.

The original implementation provides a simple and clever way to accept Hayes commands, map dialed numbers to scripts, and hand a connection over to `pppd`.

TPC-VModem takes that idea further.

The goal is not only to make the connection work, but to make it feel a little more like using a real modem, that is *with sound*!

And what's more fun than a Raspberry Pi emulating one modem?
Right, a Raspberry Pi emulating many modems!

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

*Continuous PPP line noise is only available with one active modem on Raspberry Pi 2 or newer. With multiple modems, PPP line noise audio is limited to 2 seconds. Raspberry Pi 1 uses a precomputed cache for performance reasons.

ISDN profiles do not generate analog modem audio, regardless of the ATM setting (ATM0 is enforced).

For testing there is also `vmodem-soundctl.sh`, a small shell client for the audio socket. It can play individual effects and test the exclusive audio lease, without establishing a modem connection:

```bash
cd /opt/vmodem
./vmodem-soundctl.sh dialtone 2
./vmodem-soundctl.sh dtmf 12345
./vmodem-soundctl.sh v34
./vmodem-soundctl.sh acquire
```

The sound daemon has two explicit modes:

```bash
python3 /opt/vmodem/vmodem-soundd.py --daemon
python3 /opt/vmodem/vmodem-soundd.py --prepare-noise-cache
```

The first runs the server in the foreground (normally started by systemd). The second prepares the PPP noise cache for Raspberry Pi 1. Running without arguments displays the command help.

Use `ATI` to display system uptime, network interfaces and the current modem settings. `HELP` lists the supported commands.

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

The script installs the project into `/opt/vmodem`, downloads the required files, checks dependencies, configures `pigpiod`, and installs the systemd services and udev rules. Modem instances are started when a supported USB serial adapter is detected.

## Debugging

All TPC-VModem services use a separate journald namespace called `vmodem`.

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
