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
                    ATD command received
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
                  |                 PPP connection
                  |                       |
                  |                       v
                  |               +----------------+
                  |               |     ppp.sh     |
                  |               |                |
                  |               | Start reader   |
                  |               | Start pppd     |
                  |               +-------+--------+
                  |                       |
                  |                       v
                  |                 pppd record
                  |                       |
                  |                       v
                  |                 +-----------+
                  |                 | Record    |
                  |                 | FIFO      |
                  |                 +-----+-----+
                  |                       |
                  |                       v
                  |               +----------------+
                  |               | ppp_noise.py   |
                  |               |                |
                  |               | Read PPP data  |
                  |               | Select cached  |
                  |               | sound blocks   |
                  |               +-------+--------+
                  |                       |
                  |                       v
                  |               +----------------+
                  |               | Precomputed    |
                  |               | sound cache    |
                  |               +-------+--------+
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

Dial tone and DTMF are controlled directly by `vmodem.sh`.

Once a call is handed over to PPP, `vmodem.sh` waits for `ppp.sh` to return. The PPP connection noise is therefore generated asynchronously from inside `ppp.sh`.

`pppd` writes its live record stream into a FIFO. A background reader continuously drains that FIFO and uses the first few seconds of PPP traffic as input for dynamically generated GPIO sound. After the sound period ends, the reader continues draining the FIFO without generating audio, so `pppd` can never be blocked by the sound subsystem.


## Installation

TPC-VModem provides a setup script, which does the heavy lifting for you:

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


## Wiring Diagram for Speaker via GPIO

<TBD>


## Acknowledgements

TPC VModem builds upon the original VMODEM work by Oliver Molini, created between 2020 and 2022.

Thanks also go to Billy Stoughton II for bug fixes and contributions to the original project, and to Hamish for helping test Windows 2000 compatibility.

## License

The original VMODEM implementation is licensed under the Creative Commons Attribution NonCommercial ShareAlike 4.0 International license.

TPC-VModem is distributed under the same license.

## References

* Original [Virtual Modem guide](https://www.steptail.com/guides:virtual_modem)

* Original [Virtual Modem scripts](https://www.steptail.com/guides:virtual_modem:script)
