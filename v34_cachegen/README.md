# V.34 Handshake Cache Generator

TPC-VModem uses V.34-inspired handshake audio generated with [serg123e's V.34 Handshake Audio Generator](https://github.com/serg123e/v34handshake).

Rather than playing a WAV file through a sound card, I wanted to reproduce the handshake directly through a Raspberry Pi GPIO pin and a simple speaker. The offline converter reduces the generated audio to a **40 kHz, 1-bit GPIO signal**. It preserves the waveform's zero crossings but sacrifices amplitude detail. Consecutive identical bits become timed pigpio pulses, greatly reducing the DMA workload, particularly on the original Raspberry Pi.

The ready-to-use **`v34_sound_v2.bin.gz`** cache is included in the project's root directory. You do **not** need to run the generator to install or use TPC-VModem; this utility is only needed if the handshake or conversion settings change.

## Regenerating the cache

On a development machine:

1. Download `v34_modem_handshake.py` from [serg123e/v34handshake](https://github.com/serg123e/v34handshake) and place it alongside this directory's `v34_prepare.py`. Keep the upstream MIT license and attribution when redistributing the generator.
2. Install the generator's dependencies: `python3 -m pip install numpy scipy`.
3. From this directory, run `python3 v34_cachegen.py`.
4. Copy the newly generated `v34_sound_v2.bin.gz` into the TPC-VModem project root.

`v34_cachegen.py` excludes dial tone, DTMF and ringback, which TPC-VModem generates separately. Besides the cache file, it also writes a `v34_reference.wav` for listening and comparison; **the Raspberry Pi plays the compressed GPIO cache, not the WAV**.

## License

TPC-VModem is released under CC BY-NC-SA 4.0.

The `v34_cachegen.py` utility is however licensed separately from the main TPC-VModem project, as it builds directly on [V.34 handshake generator by serg123e](https://github.com/serg123e/v34handshake), originally published under the MIT License.

Therefore `v34_cachegen.py` is distributed under the terms of the [MIT License](LICENSE).