#!/usr/bin/env python3

# Synthetic modem noise, driven by the live pppd record stream.
# No WAV files or sound card. The GPIO outputs a one bit waveform.

import math
import os
import queue
import sys
import threading
import time
from collections import namedtuple

try:
    import lgpio
except ImportError:
    lgpio = None


GPIO_CHIP = 0
GPIO_PIN = 12                 # BCM 12, physical pin 32

NOISE_SECONDS = 6.0
SAMPLE_RATE = 20000
CHUNK_MS = 30
EVENT_QUEUE_SIZE = 32

# Main frequencies of the noisy data phase. Change these to taste.
#LOW_HZ = 650
#MID_HZ = 1050
#HIGH_HZ = 1550
LOW_HZ = 380
MID_HZ = 680
HIGH_HZ = 1100

TAG_SENT = 1
TAG_RECEIVED = 2
TAG_SEND_EOF = 3
TAG_RECV_EOF = 4
TAG_TIME_LONG = 5
TAG_TIME_SHORT = 6
TAG_START = 7

Pulse = namedtuple('Pulse', 'group_bits group_mask pulse_delay')
TWO_PI = 2 * math.pi


class NoisePlayer:
    def __init__(self):
        self.events = queue.Queue(maxsize=EVENT_QUEUE_SIZE)
        self.started = None
        self.stop = threading.Event()
        self.thread = None

        if lgpio is None:
            print('ppp_noise.py: lgpio unavailable, draining without sound', file=sys.stderr)
            return

        self.thread = threading.Thread(target=self.play, daemon=True)
        self.thread.start()

    def feed(self, direction, data):
        if not data or self.stop.is_set() or lgpio is None:
            return

        now = time.monotonic()
        if self.started is None:
            self.started = now

        if now - self.started >= NOISE_SECONDS:
            return

        # Only send a tiny summary of each block to the sound thread.
        # A full queue is fine: PPP reading always takes priority.
        step = max(1, len(data) // 16)
        sampled = data[::step][:16]
        value = (sum(sampled) + (len(data) & 255)) & 255
        try:
            self.events.put_nowait((direction, value))
        except queue.Full:
            pass

    def make_wave(self, count, sample_number, tx, rx):
        pulses = []
        last = None
        run_us = 0
        sample_us = 1000000 // SAMPLE_RATE

        for n in range(count):
            t = (sample_number + n) / SAMPLE_RATE

            # A very compressed, stylized handshake. Not a V.34 emulator.
            if t < 0.18:
                f1, f2, f3 = 2100, 0, 0
                a, b, c, hiss = 0.9, 0, 0, 0
            elif t < 0.65:
                f1 = 950 + int(700 * (t - 0.18) / 0.47)
                f2, f3 = 1250, 0
                a, b, c, hiss = 0.65, 0.3, 0, 0.05
            else:
                # Actual PPP traffic alters the mixture and its roughness.
                # The second half moves towards a darker, lower sound.
                dark = min(1.0, max(0.0, (t - 1.6) / 1.1))
                f1 = LOW_HZ + (tx % 11) * 6
                f2 = MID_HZ + (rx % 9) * 8
                f3 = HIGH_HZ + ((tx ^ rx) % 7) * 10
                a = 0.15 + dark * 0.05
                b = 0.12
                c = 0.08 - dark * 0.04
                hiss = 0.65 + dark * 0.15

                #dark = min(1.0, max(0.0, (t - 1.6) / 1.1))
                #f1 = LOW_HZ + (tx % 15) * 9
                #f2 = MID_HZ + (rx % 13) * 11
                #f3 = HIGH_HZ + ((tx ^ rx) % 11) * 18
                #a = 0.32 + dark * 0.13
                #b = 0.31
                #c = 0.24 - dark * 0.11
                #hiss = 0.22 + dark * 0.08

            # Combine several tones and some filtered, data seeded noise.
            # A single GPIO cannot output analog audio, so the sum is
            # converted into a one bit waveform below.
            wave = (a * math.sin(TWO_PI * f1 * t) +
                    b * math.sin(TWO_PI * f2 * t) +
                    c * math.sin(TWO_PI * f3 * t))

            # Cheap deterministic noise, with most of the harsh high end
            # filtered out. The latest PPP bytes affect its starting state.
            #self.seed = (1103515245 * self.seed + 12345) & 0x7fffffff
            #raw = ((self.seed >> 16) / 16384.0) - 1.0
            #self.filtered = 0.87 * self.filtered + 0.13 * raw
            #wave += hiss * self.filtered
            self.seed = (1103515245 * self.seed + 12345) & 0x7fffffff
            raw = ((self.seed >> 16) / 16384.0) - 1.0
            self.filtered = 0.91 * self.filtered + 0.09 * raw
            wave += hiss * self.filtered

            # A small fade avoids a hard click at the end.
            if t > NOISE_SECONDS - 0.2:
                wave *= max(0.0, (NOISE_SECONDS - t) / 0.2)

            level = 1 if wave > 0.02 else 0
            if last is None:
                last = level
                run_us = sample_us
            elif level == last:
                run_us += sample_us
            else:
                pulses.append(Pulse(last, 1, run_us))
                last = level
                run_us = sample_us

        if run_us:
            pulses.append(Pulse(last, 1, run_us))

        # Always finish the waveform with GPIO low.
        pulses.append(Pulse(0, 1, sample_us))
        return pulses

    def play(self):
        handle = None
        claimed = False
        self.seed = 12345
        self.filtered = 0.0
        tx, rx = 61, 113
        sample_number = 0
        count = SAMPLE_RATE * CHUNK_MS // 1000

        try:
            handle = lgpio.gpiochip_open(GPIO_CHIP)
            lgpio.group_claim_output(handle, [GPIO_PIN])
            claimed = True

            # Keep no more than two wave chunks queued. All the GPIO timing
            # is handled by lgpio, not Python sleeps.
            full_room = lgpio.tx_room(handle, GPIO_PIN, lgpio.TX_WAVE)
            if full_room < 1:
                raise RuntimeError('no GPIO wave queue available')
            minimum_room = max(0, full_room - 2)

            while not self.stop.is_set():
                if self.started is None:
                    try:
                        event = self.events.get(timeout=0.05)
                    except queue.Empty:
                        continue
                    if event[0] == 'TX':
                        tx = event[1]
                    else:
                        rx = event[1]
                    self.seed ^= event[1] << 8
                    continue

                if time.monotonic() - self.started >= NOISE_SECONDS:
                    break

                # Keep only the freshest PPP activity for this chunk.
                while True:
                    try:
                        direction, value = self.events.get_nowait()
                    except queue.Empty:
                        break
                    if direction == 'TX':
                        tx = value
                    else:
                        rx = value
                    self.seed ^= (value << (1 if direction == 'TX' else 9))

                if sample_number >= SAMPLE_RATE * NOISE_SECONDS:
                    break

                while not self.stop.is_set():
                    room = lgpio.tx_room(handle, GPIO_PIN, lgpio.TX_WAVE)
                    if room > minimum_room:
                        break
                    time.sleep(0.003)

                if self.stop.is_set():
                    break

                remaining = int(SAMPLE_RATE * NOISE_SECONDS) - sample_number
                chunk = min(count, remaining)
                pulses = self.make_wave(chunk, sample_number, tx, rx)
                lgpio.tx_wave(handle, GPIO_PIN, pulses)
                sample_number += chunk

            # Let the last queued sound finish unless PPP has already ended.
            if not self.stop.is_set():
                while lgpio.tx_busy(handle, GPIO_PIN, lgpio.TX_WAVE):
                    time.sleep(0.005)

        except Exception as exc:
            print(f'ppp_noise.py: sound disabled: {exc}', file=sys.stderr)

        finally:
            if handle is not None:
                if claimed:
                    try:
                        lgpio.group_write(handle, GPIO_PIN, 0, 1)
                        lgpio.group_free(handle, GPIO_PIN)
                    except Exception:
                        pass
                lgpio.gpiochip_close(handle)

    def close(self):
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=0.5)


def read_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        block = stream.read(count - len(data))
        if not block:
            return None
        data.extend(block)
    return bytes(data)


def parse_record(stream, debug=False):
    player = NoisePlayer()
    elapsed = 0.0
    sent_bytes = received_bytes = 0

    try:
        while True:
            tag = stream.read(1)
            if not tag:
                break
            tag = tag[0]

            if tag == TAG_SENT or tag == TAG_RECEIVED:
                size = read_exact(stream, 2)
                if size is None:
                    break
                data = read_exact(stream, int.from_bytes(size, 'big'))
                if data is None:
                    break
                direction = 'TX' if tag == TAG_SENT else 'RX'
                player.feed(direction, data)
                if tag == TAG_SENT:
                    sent_bytes += len(data)
                else:
                    received_bytes += len(data)
                if debug and elapsed < 5:
                    print(f'{elapsed:4.1f}s {direction} {len(data)} bytes')

            elif tag == TAG_TIME_SHORT:
                value = read_exact(stream, 1)
                if value is None:
                    break
                elapsed += value[0] / 10.0

            elif tag == TAG_TIME_LONG:
                value = read_exact(stream, 4)
                if value is None:
                    break
                elapsed += int.from_bytes(value, 'big') / 10.0

            elif tag == TAG_START:
                if read_exact(stream, 4) is None:
                    break
                elapsed = 0.0

            elif tag in (TAG_SEND_EOF, TAG_RECV_EOF):
                pass

            else:
                print(f'ppp_noise.py: unknown record tag {tag}, draining', file=sys.stderr)
                while stream.read(4096):
                    pass
                return 1

    finally:
        # Audio ends after four seconds. This reader stays alive and
        # continues draining the FIFO until pppd closes its write side.
        player.close()

    if debug:
        print(f'PPP record ended: TX {sent_bytes}, RX {received_bytes} bytes')
    return 0


def main():
    if len(sys.argv) < 2:
        print('Usage: ppp_noise.py FIFO [debug]', file=sys.stderr)
        return 1

    fifo = sys.argv[1]
    debug = len(sys.argv) > 2 and sys.argv[2].lower() == 'debug'
    if not os.path.exists(fifo):
        print(f'ppp_noise.py: FIFO not found: {fifo}', file=sys.stderr)
        return 1

    try:
        with open(fifo, 'rb', buffering=0) as stream:
            return parse_record(stream, debug)
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        print(f'ppp_noise.py: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
