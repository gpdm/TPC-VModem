#!/usr/bin/env python3

import sys
import time
import math
import signal
from collections import namedtuple

import lgpio


GPIO_CHIP = 0
GPIO_PIN = 18

DIALTONE_FREQ = 425

DTMF_TIME = 0.12
DTMF_GAP = 0.07

WAVE_SAMPLE_RATE = 20000


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


Pulse = namedtuple(
    "Pulse",
    ["group_bits", "group_mask", "pulse_delay"]
)


running = True


def signal_stop(signum, frame):
    global running
    running = False


def open_gpio():
    return lgpio.gpiochip_open(GPIO_CHIP)


def tone(freq, duration=None):
    handle = open_gpio()

    try:
        lgpio.gpio_claim_output(handle, GPIO_PIN, 0)

        lgpio.tx_pwm(
            handle,
            GPIO_PIN,
            freq,
            50
        )

        if duration is not None:
            end = time.monotonic() + duration

            while running and time.monotonic() < end:
                time.sleep(0.05)

        else:
            while running:
                time.sleep(0.1)

    finally:
        try:
            lgpio.tx_pwm(handle, GPIO_PIN, 0, 0)
            lgpio.gpio_write(handle, GPIO_PIN, 0)
            lgpio.gpio_free(handle, GPIO_PIN)
        except Exception:
            pass

        lgpio.gpiochip_close(handle)


def make_dual_tone(freq1, freq2, duration):
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

        if value >= 0:
            level = 1
        else:
            level = 0

        if last_level is None:
            last_level = level
            pulse_time = sample_us
            continue

        if level == last_level:
            pulse_time += sample_us
            continue

        pulses.append(
            Pulse(last_level, 1, pulse_time)
        )

        last_level = level
        pulse_time = sample_us

    if pulse_time:
        pulses.append(
            Pulse(last_level, 1, pulse_time)
        )

    pulses.append(
        Pulse(0, 1, 100)
    )

    return pulses


def play_dtmf(number):
    handle = open_gpio()

    try:
        lgpio.group_claim_output(
            handle,
            [GPIO_PIN]
        )

        for digit in number:

            if not running:
                break

            if digit not in DTMF:
                continue

            freq1, freq2 = DTMF[digit]

            pulses = make_dual_tone(
                freq1,
                freq2,
                DTMF_TIME
            )

            lgpio.tx_wave(
                handle,
                GPIO_PIN,
                pulses
            )

            while (
                running and
                lgpio.tx_busy(
                    handle,
                    GPIO_PIN,
                    lgpio.TX_WAVE
                )
            ):
                time.sleep(0.005)

            lgpio.gpio_write(
                handle,
                GPIO_PIN,
                0
            )

            if running:
                time.sleep(DTMF_GAP)

    finally:
        try:
            lgpio.gpio_write(
                handle,
                GPIO_PIN,
                0
            )

            lgpio.group_free(
                handle,
                GPIO_PIN
            )
        except Exception:
            pass

        lgpio.gpiochip_close(handle)


def usage():
    print("Usage:")
    print()
    print("  sound.py tone FREQUENCY SECONDS")
    print("  sound.py dialtone")
    print("  sound.py dialtone SECONDS")
    print("  sound.py dtmf NUMBER")


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

        tone(
            DIALTONE_FREQ,
            duration
        )

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

    signal.signal(
        signal.SIGINT,
        signal_stop
    )

    signal.signal(
        signal.SIGTERM,
        signal_stop
    )

    sys.exit(main())
