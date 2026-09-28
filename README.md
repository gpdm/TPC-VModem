# TPC-VModem

TPC-VModem is a virtual Hayes compatible modem implementation intended to run on a Raspberry Pi and provide dial up style connectivity to retro computers over a serial connection.

This project was inspired by the excellent Virtual Modem guide by [Steptail](https://www.steptail.com/guides:virtual_modem).

The original implementation provides a simple and clever way to accept Hayes commands, map dialed numbers to scripts, and hand a connection over to `pppd`.

TPC-VModem takes that idea further.

The goal is not only to make the connection work, but to make it feel a little more like using a real modem ... with sound!


## Sound Architecture

The sound effects are generated directly through Raspberry Pi GPIO. No sound card and no prerecorded audio files are required.

```text
                    +------------------+
                    |     systemd      |
                    +---------+--------+
                              |
                              v
                    +------------------+
                    |    vmodem.sh     |
                    |  Hayes emulator  |
                    +---------+--------+
                              |
                         ATD command
                              |
                 +------------+-----------+
                 |                        |
                 v                        v
           +------------+         +----------------+
           |  sound.py  |         | Service routing|
           |            |         |                |
           | Dial tone  |         | NUMBER.sh      |
           | DTMF       |         | or ppp.sh      |
           +------+-----+         +-------+--------+
                  |                       |
                  |                       v
                  |               +----------------+
                  |               |     ppp.sh     |
                  |               |                |
                  |               | Create FIFO    |
                  |               | Start reader   |
                  |               | Run pppd       |
                  |               +-------+--------+
                  |                       |
                  |                       v
                  |                 pppd record
                  |                       |
                  |                       v
                  |               +----------------+
                  |               |  Record FIFO   |
                  |               +-------+--------+
                  |                       |
                  |                       v
                  |               +----------------+
                  |               |  ppp_noise.py  |
                  |               |                |
                  |               | Read PPP data  |
                  |               | Detect Pi model|
                  |               +-------+--------+
                  |                       |
                  |             +---------+---------+
                  |             |                   |
                  |             v                   v
                  |       +------------+     +------------+
                  |       | Pi 1       |     | Other Pis  |
                  |       |            |     |            |
                  |       | Precomputed|     | Live audio |
                  |       | sound cache|     | synthesis  |
                  |       +------+-----+     +-----+------+
                  |              |                 |
                  |              +--------+--------+
                  |                       |
                  +-----------+-----------+
                              |
                              v
                    +------------------+
                    |     pigpiod      |
                    |                  |
                    | Hardware PWM     |
                    | DMA waveforms    |
                    +---------+--------+
                              |
                              v
                           GPIO18
                              |
                              v
                           Speaker
```


Dial tone and DTMF are controlled directly by `vmodem.sh` and generated through `sound.py, using hardware PWM and DMA.

Once a call is handed over to PPP, `vmodem.sh` waits for `ppp.sh` to return. The PPP connection noise is generated asynchronously by `ppp_noise.py`, which is launched by `ppp.sh.

pppd writes its live record stream into a FIFO, which is continuously read by `ppp_noise.py`.
Depending on the Raspberry Pi model, sound is either generated from precomputed audio blocks (Raspberry Pi 1) or synthesized live (other models).
In both cases, actual PPP traffic influences the generated sound, which is played through pigpio using DMA.

After the six second sound period ends, the reader continues draining the FIFO for the remainder of the PPP session, preventing the audio processing from unnecessarily interfering with the connection.

## Changes From Original VModem

* `vmodem.sh` extended to emit dial tone and DTMF sequences
* `ppp.sh` extended to emit some "noise" (no, it's not a modem-accurate noise reproduction, but at least on Raspberry Pi 2 or better it's sampled from live serial transmission data)
* `setup.sh` script
* systemd service integration

## Wiring Diagram for Speaker via GPIO

TPC-VModem does not require sound hardware.
All audio is emitted through a simple speaker connected to GPIO.

Some soldering is required. Schematics below.

<TBD>


## Installation

As noted, TPC-VModem provides a setup script which does the heavy lifting for you:

```
cd /tmp
wget https://raw.githubusercontent.com/gpdm/TPC-VModem/refs/heads/main/setup.sh
bash setup.sh
```

* creates /opt/vmodem
* downloads all scripts
* checks and install required dependencies
* reconfigures pigpiod to disable polling (reduces load on original Raspberry Pi 1)
* registers vmodem with systemd

## Acknowledgements

TPC VModem builds upon the original VMODEM work by Oliver Molini, created between 2020 and 2022.

Thanks also go to Billy Stoughton II for bug fixes and contributions to the original project, and to Hamish for helping test Windows 2000 compatibility.

## License

The original VMODEM implementation is licensed under the Creative Commons Attribution NonCommercial ShareAlike 4.0 International license.

TPC-VModem is distributed under the same license.

## References

* Original [Virtual Modem guide](https://www.steptail.com/guides:virtual_modem)

* Original [Virtual Modem scripts](https://www.steptail.com/guides:virtual_modem:script)
