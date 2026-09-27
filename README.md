# TPC VModem

TPC VModem is a virtual Hayes compatible modem implementation intended to run on a Raspberry Pi and provide dial up style connectivity to retro computers over a serial connection.

This project was inspired by the excellent Virtual Modem guide by [Steptail](https://www.steptail.com/guides:virtual_modem).

The original implementation provides a simple and clever way to accept Hayes commands, map dialed numbers to scripts, and hand a connection over to `pppd`.

TPC VModem takes that idea further.

The goal is not only to make the connection work, but to make it feel a little more like using a real modem ... with sound!


## Sound Architecture

The sound effects are generated directly through Raspberry Pi GPIO. No sound card and no prerecorded audio files are required.

```text
                         +==================+
                         |     vmodem.sh    |
                         |                  |
                         |  Hayes Emulator  |
                         +==========+=======+
                                  |
                    +=============+=============+
                    |                           |
                    v                           v
          +==================+        +==================+
          |  GPIO sound      |        | Service routing  |
          |  helper          |        |                  |
          |                  |        | NUMBER.sh exists |
          |  Dial tone       |        |        yes       |
          |  DTMF digits     |        |         |        |
          +========+=========+        |         v        |
                   |                  |     NUMBER.sh    |
                   |                  |                  |
                   |                  | otherwise        |
                   |                  |         |        |
                   |                  |         v        |
                   |                  |       ppp.sh     |
                   |                  +=========+========+
                   |                            |
                   |                            v
                   |                  +==================+
                   |                  |      ppp.sh      |
                   |                  |                  |
                   |                  | create FIFO      |
                   |                  | start noise      |
                   |                  | reader in bg     |
                   |                  | start pppd       |
                   |                  +=========+========+
                   |                            |
                   |                            v
                   |                  +==================+
                   |                  |       pppd       |
                   |                  |                  |
                   |                  | record output    |
                   |                  +=========+========+
                   |                            |
                   |                            v
                   |                  +==================+
                   |                  |   Record FIFO    |
                   |                  +=========+========+
                   |                            |
                   |                            v
                   |                  +==================+
                   |                  | PPP noise reader |
                   |                  |                  |
                   |                  | Parse live data  |
                   |                  | Drain FIFO       |
                   |                  | Generate sound   |
                   |                  | events for a     |
                   |                  | few seconds      |
                   |                  +=========+========+
                   |                            |
                   +=============+==============+
                                 |
                                 v
                       +======================+
                       | GPIO sound generator |
                       |                      |
                       | Timed GPIO waveform  |
                       +==========+===========+
                                  |
                                  v
                       +======================+
                       |       Speaker        |
                       +======================+
```

Dial tone and DTMF are controlled directly by `vmodem.sh`.

Once a call is handed over to PPP, `vmodem.sh` waits for `ppp.sh` to return. The PPP connection noise is therefore generated asynchronously from inside `ppp.sh`.

`pppd` writes its live record stream into a FIFO. A background reader continuously drains that FIFO and uses the first few seconds of PPP traffic as input for dynamically generated GPIO sound. After the sound period ends, the reader continues draining the FIFO without generating audio, so `pppd` can never be blocked by the sound subsystem.



## Acknowledgements

TPC VModem builds upon the original VMODEM work by Oliver Molini, created between 2020 and 2022.

Thanks also go to Billy Stoughton II for bug fixes and contributions to the original project, and to Hamish for helping test Windows 2000 compatibility.

## License

The original VMODEM implementation is licensed under the Creative Commons Attribution NonCommercial ShareAlike 4.0 International license.

TPC-VModem is distributed under the same license.

## References

* Original [Virtual Modem guide](https://www.steptail.com/guides:virtual_modem)

* Original [Virtual Modem scripts](https://www.steptail.com/guides:virtual_modem:script)