#!/usr/bin/env python3
#
# TPC-VModem - Offline V.34 GPIO sound preparation
#
# Uses the original V.34 Modem Handshake Audio Generator by serg123e
# (MIT license: https://github.com/serg123e/v34handshake).
# This adapter removes dialtone, DTMF and ringback from the generated
# sound sequence; those sounds are already produced by TPC-VModem.
#
# The resulting 1-bit cache needs no NumPy or SciPy for playback.
#
# Redistributed under the terms of the MIT License.
#
import gzip
from pathlib import Path
import struct
import wave

import numpy as np
from scipy.ndimage import uniform_filter1d
from scipy.signal import resample_poly
from v34_modem_handshake import V34Generator

DEST = Path(__file__).resolve().parent
SAMPLE_RATE = 40000            # 25us per 1-bit GPIO sample
MAGIC = b'TPCV34\x02\x00'       # 8-byte header
CACHE_FILE = DEST / 'v34_sound_v2.bin.gz'
WAV_FILE = DEST / 'v34_reference.wav'


def prepare():
    generator = V34Generator()
    print('Generating V.8 and V.34 phases (without dialtone, DTMF or ringback)...', flush=True)
    segments = [
        *generator._v8_phase(),
        generator._v34_probing_ranging_phase(),
        generator._v34_training_phase(),
    ]
    stereo = np.concatenate(segments)
    # GPIO18 is a single output. Mix both modem ends instead of selecting
    # just one channel. Preserve relative levels and timing.
    mono = stereo.mean(axis=1)
    mono = resample_poly(mono, 400, 441)  # 44.1 kHz to 40 kHz
    maximum = np.max(np.abs(mono))
    if not np.isfinite(maximum) or maximum <= 0:
        raise RuntimeError('Generated audio is silent or invalid')
    mono = np.clip(mono / maximum * 0.85, -0.85, 0.85)

    # WAV lets us audition the mixed reference without Pi hardware.
    pcm = np.rint(mono * 32767).astype('<i2')
    with wave.open(str(WAV_FILE), 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(pcm.tobytes())

    # A thresholded, 1-bit waveform retains the signal's zero crossings
    # without sigma-delta's high-frequency switching overhead. The GPIO
    # pulse count drops several-fold, important for the original Pi 1.
    # Filter the envelope only to ensure silence is electrically silent.
    envelope = uniform_filter1d(np.abs(mono), size=200)
    bits = np.where(envelope < 0.0005, 0, mono >= 0).astype(np.uint8)

    payload = np.packbits(bits, bitorder='big').tobytes()
    with gzip.open(CACHE_FILE, 'wb', compresslevel=6) as out:
        out.write(struct.pack('<8sII', MAGIC, SAMPLE_RATE, len(bits)))
        out.write(payload)
    print(f'Audio duration: {len(mono)/SAMPLE_RATE:.2f} s', flush=True)
    print(f'Prepared GPIO cache: {CACHE_FILE} ({CACHE_FILE.stat().st_size} bytes)', flush=True)
    print(f'Reference audio: {WAV_FILE}', flush=True)


if __name__ == '__main__':
    prepare()
