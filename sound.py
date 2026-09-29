#!/usr/bin/env python3
#
# TPC-VModem - GPIO sound generator
#
# Dial tone, DTMF, ringback, and precomputed V.34 audio via GPIO18.
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
import gzip
import struct
import sys
import time
import math
import signal
from pathlib import Path

import pigpio


def get_pi_model():
    path = Path("/proc/device-tree/model")
    return path.read_bytes().decode().rstrip("\x00")

model = get_pi_model()

GPIO_PIN = 18                 # BCM 18, physical pin 12
GPIO_MASK = 1 << GPIO_PIN

DIALTONE_FREQ = 425
RINGBACK_TONE_SECONDS = 1.0
RINGBACK_PAUSE_SECONDS = 3.0
RINGBACK_CYCLES = 2
DTMF_TIME = 0.12

# adjust timings depending on Raspberry Pi model
if model.startswith("Raspberry Pi Model "):
    DTMF_GAP = 0.01
else:
    DTMF_GAP = 0.03

WAVE_SAMPLE_RATE = 20000
V34_CACHE = Path(__file__).resolve().with_name("v34_sound_v2.bin.gz")
V34_MAGIC = b"TPCV34\x02\x00"
V34_CHUNK_MS = 500


DTMF = {
    "1": (697, 1209),
    "2": (697, 1336),
    "3": (697, 1477),

    "4": (770, 1209),
    "5": (770, 1336),
    "6": (770, 1477),

    "7": (852, 1209),
    "8": (852, 1336),
    "9": (852, 1477),

    "*": (941, 1209),
    "0": (941, 1336),
    "#": (941, 1477),
}


running = True


def signal_stop(signum, frame):
    global running
    running = False


def open_gpio():
    pi = pigpio.pi()
    if not pi.connected:
        raise RuntimeError("Cannot connect to pigpiod (try: sudo pigpiod)")
    return pi


def tone(freq, duration=None):
    pi = open_gpio()

    try:
        # Hardware PWM keeps the single-frequency dial tone stable.
        pi.hardware_PWM(GPIO_PIN, int(round(freq)), 500000)

        if duration is not None:
            end = time.monotonic() + duration
            while running and time.monotonic() < end:
                time.sleep(0.05)
        else:
            while running:
                time.sleep(0.1)

    finally:
        try:
            pi.hardware_PWM(GPIO_PIN, 0, 0)
            pi.write(GPIO_PIN, 0)
        finally:
            pi.stop()


def make_dual_tone(freq1, freq2, duration):
    # Same dual-tone synthesis as the original; only the output pulse
    # representation changes to pigpio's DMA waveform format.
    sample_time = 1.0 / WAVE_SAMPLE_RATE
    sample_us = int(1000000 / WAVE_SAMPLE_RATE)

    samples = int(duration * WAVE_SAMPLE_RATE)
    pulses = []
    last_level = None
    pulse_time = 0

    for sample in range(samples):
        t = sample * sample_time
        value = (
            math.sin(2.0 * math.pi * freq1 * t) +
            math.sin(2.0 * math.pi * freq2 * t)
        )
        level = 1 if value >= 0 else 0

        if last_level is None:
            last_level = level
            pulse_time = sample_us
            continue

        if level == last_level:
            pulse_time += sample_us
            continue

        pulses.append(pigpio.pulse(
            GPIO_MASK if last_level else 0,
            0 if last_level else GPIO_MASK,
            pulse_time
        ))
        last_level = level
        pulse_time = sample_us

    if pulse_time:
        pulses.append(pigpio.pulse(
            GPIO_MASK if last_level else 0,
            0 if last_level else GPIO_MASK,
            pulse_time
        ))

    pulses.append(pigpio.pulse(0, GPIO_MASK, 100))
    return pulses


def play_pulses(pi, pulses):
    """Play one short DMA waveform; stop it promptly on SIGTERM/SIGINT."""
    pi.wave_add_new()
    pi.wave_add_generic(pulses)
    wave_id = pi.wave_create()
    if wave_id < 0:
        raise RuntimeError(f"pigpio wave_create failed: {wave_id}")

    try:
        pi.wave_send_once(wave_id)
        while running and pi.wave_tx_busy():
            time.sleep(0.005)
    finally:
        if pi.wave_tx_busy():
            pi.wave_tx_stop()
        pi.wave_delete(wave_id)
        pi.write(GPIO_PIN, 0)


def wait(seconds):
    """Interruptible wait, used for the pause between ringback tones."""
    end = time.monotonic() + seconds
    while running:
        remaining = end - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(0.05, remaining))


def play_ringback(cycles, pause_seconds):
    """425 Hz ringback with configurable pauses between rings."""
    pi = open_gpio()
    try:
        for cycle in range(cycles):
            if not running:
                break
            pi.hardware_PWM(GPIO_PIN, DIALTONE_FREQ, 500000)
            try:
                wait(RINGBACK_TONE_SECONDS)
            finally:
                pi.hardware_PWM(GPIO_PIN, 0, 0)
                pi.write(GPIO_PIN, 0)

            # No extra pause after the final ring.
            if cycle < cycles - 1:
                wait(pause_seconds)

    finally:
        try:
            pi.hardware_PWM(GPIO_PIN, 0, 0)
            pi.wave_tx_stop()
            pi.write(GPIO_PIN, 0)
        finally:
            pi.stop()


def play_dtmf(number):
    pi = open_gpio()

    try:
        pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
        pi.write(GPIO_PIN, 0)

        for digit in number:
            if not running:
                break
            if digit not in DTMF:
                continue

            freq1, freq2 = DTMF[digit]
            pulses = make_dual_tone(freq1, freq2, DTMF_TIME)

            # pigpiod outputs this short waveform via DMA.
            play_pulses(pi, pulses)

            if running:
                time.sleep(DTMF_GAP)

    finally:
        try:
            pi.wave_tx_stop()
            pi.write(GPIO_PIN, 0)
        finally:
            pi.stop()



def load_v34_cache():
    """Load the compact, low-transition V.34 audio (no NumPy needed)."""
    try:
        with gzip.open(V34_CACHE, "rb") as file:
            header = file.read(16)
            if len(header) != 16:
                raise ValueError("truncated header")
            magic, sample_rate, count = struct.unpack("<8sII", header)
            if magic != V34_MAGIC or sample_rate != 40000 or not (0 < count < 40000 * 120):
                raise ValueError("unsupported V.34 cache format")
            data = file.read()
    except OSError as exc:
        raise RuntimeError(f"Cannot load V.34 audio cache {V34_CACHE}: {exc}") from exc
    if len(data) != (count + 7) // 8:
        raise RuntimeError("V.34 cache is truncated or invalid")
    return sample_rate, count, data


def v34_pulses(data, start, end, sample_us):
    """Convert just one short section of packed 1-bit audio to pigpio pulses."""
    level = bool(data[start >> 3] & (1 << (7 - (start & 7))))
    run = 0
    pulses = []
    for sample in range(start, end):
        next_level = bool(data[sample >> 3] & (1 << (7 - (sample & 7))))
        if next_level != level:
            pulses.append(pigpio.pulse(
                GPIO_MASK if level else 0,
                0 if level else GPIO_MASK,
                run * sample_us,
            ))
            level = next_level
            run = 0
        run += 1
    if run:
        pulses.append(pigpio.pulse(
            GPIO_MASK if level else 0,
            0 if level else GPIO_MASK,
            run * sample_us,
        ))
    return pulses


def play_v34():
    """Stream the prepared V.8/V.34 handshake using pigpio DMA waves."""
    sample_rate, count, data = load_v34_cache()
    # 40 kHz GPIO sample rate = 25 us, exact integer pigpio timing.
    sample_us = 1000000 // sample_rate
    chunk_samples = sample_rate * V34_CHUNK_MS // 1000
    pi = open_gpio()
    previous_id = None
    try:
        pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
        pi.write(GPIO_PIN, 0)
        pi.wave_clear()
        for start in range(0, count, chunk_samples):
            if not running:
                break
            pulses = v34_pulses(data, start, min(start + chunk_samples, count), sample_us)
            pi.wave_add_new()
            pi.wave_add_generic(pulses)
            wave_id = pi.wave_create_and_pad(50)
            if wave_id < 0:
                raise RuntimeError(f"pigpio V.34 wave_create failed: {wave_id}")

            if previous_id is None:
                pi.wave_send_once(wave_id)
            elif pi.wave_tx_busy():
                # Let pigpio switch on the precise previous-wave boundary.
                pi.wave_send_using_mode(wave_id, pigpio.WAVE_MODE_ONE_SHOT_SYNC)
                while running:
                    active = pi.wave_tx_at()
                    if active == wave_id:
                        break
                    if active == pigpio.NO_TX_WAVE:
                        # A slow Pi may underrun while preparing the next wave.
                        print("sound.py: V.34 playback underrun", file=sys.stderr)
                        pi.wave_send_once(wave_id)
                        break
                    time.sleep(0.004)
                if not running:
                    break
                pi.wave_delete(previous_id)
            else:
                print("sound.py: V.34 playback underrun", file=sys.stderr)
                pi.wave_delete(previous_id)
                pi.wave_send_once(wave_id)
            previous_id = wave_id

        while running and pi.wave_tx_busy():
            time.sleep(0.01)
    finally:
        try:
            pi.wave_tx_stop()
            pi.wave_clear()
            pi.write(GPIO_PIN, 0)
        finally:
            pi.stop()

def usage():
    print("Usage:")
    print()
    print("  sound.py tone FREQUENCY SECONDS")
    print("  sound.py dialtone")
    print("  sound.py dialtone SECONDS")
    print("  sound.py dtmf NUMBER")
    print("  sound.py ringback [CYCLES [PAUSE_SECONDS]]")
    print("  sound.py v34")
    print("    Defaults: 2 cycles, 1s tone, 3s pause between tones")


def main():
    if len(sys.argv) < 2:
        usage()
        return 1

    command = sys.argv[1].lower()

    if command == "tone":
        if len(sys.argv) != 4:
            usage()
            return 1
        freq = float(sys.argv[2])
        duration = float(sys.argv[3])
        tone(freq, duration)
        return 0

    if command == "dialtone":
        if len(sys.argv) == 3:
            duration = float(sys.argv[2])
        else:
            duration = None
        tone(DIALTONE_FREQ, duration)
        return 0

    if command == "ringback":
        if not 2 <= len(sys.argv) <= 4:
            usage()
            return 1
        try:
            cycles = int(sys.argv[2]) if len(sys.argv) >= 3 else RINGBACK_CYCLES
            pause = float(sys.argv[3]) if len(sys.argv) >= 4 else RINGBACK_PAUSE_SECONDS
        except ValueError:
            usage()
            return 1
        if cycles < 1 or not (math.isfinite(pause) and pause >= 0):
            usage()
            return 1
        play_ringback(cycles, pause)
        return 0

    if command == "v34":
        if len(sys.argv) != 2:
            usage()
            return 1
        play_v34()
        return 0

    if command == "dtmf":
        if len(sys.argv) != 3:
            usage()
            return 1
        play_dtmf(sys.argv[2])
        return 0

    usage()
    return 1


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_stop)
    signal.signal(signal.SIGTERM, signal_stop)
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"sound.py: {exc}", file=sys.stderr)
        sys.exit(1)
