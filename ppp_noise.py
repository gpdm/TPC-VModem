#!/usr/bin/env python3
"""Synthetic modem noise from pppd's live record FIFO.

Audio is synthesized ONCE into a small on-disk sound bank. During PPP,
only cached GPIO pulse lists are passed to pigpio for DMA playback.

Prepare once (no pigpio daemon or GPIO needed):
    python3 ppp_noise.py --prepare

Normal ppp.sh invocation is unchanged:
    python3 ppp_noise.py /run/tpc-vmodem-ppp-123.fifo

The FIFO is always drained, including after the six-second sound finishes.
"""

import gzip
import json
import math
import os
import queue
import sys
import threading
import time

try:
    import pigpio
except ImportError:
    pigpio = None

GPIO_PIN = 18                   # BCM 18, physical pin 12
NOISE_SECONDS = 6.0
SAMPLE_RATE = 20000
CHUNK_MS = 250                  # 24 short, precomputed chunks per connection
LOW_HZ = 380
MID_HZ = 680
HIGH_HZ = 1100

CACHE_VERSION = 1
CACHE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          'ppp_noise_cache_v1.json.gz')
EVENT_QUEUE_SIZE = 32
GPIO_MASK = 1 << GPIO_PIN
TWO_PI = 2.0 * math.pi
FRAME_COUNT = int(round(NOISE_SECONDS * 1000 / CHUNK_MS))
SAMPLES_PER_CHUNK = SAMPLE_RATE * CHUNK_MS // 1000
SAMPLE_US = 1000000 // SAMPLE_RATE
TX_LEVELS = (32, 96, 160, 224)
RX_LEVELS = (40, 128, 216)

TAG_SENT = 1
TAG_RECEIVED = 2
TAG_SEND_EOF = 3
TAG_RECV_EOF = 4
TAG_TIME_LONG = 5
TAG_TIME_SHORT = 6
TAG_START = 7


def cache_signature():
    return [CACHE_VERSION, SAMPLE_RATE, CHUNK_MS,
            LOW_HZ, MID_HZ, HIGH_HZ, NOISE_SECONDS]


def generate_chunk(start_t, tx, rx, seed):
    """Original synthesizer, evaluated OFFLINE. Store level + run lengths."""
    last_level = None
    run_us = 0
    durations = []
    filtered = 0.0

    for n in range(SAMPLES_PER_CHUNK):
        t = start_t + n / SAMPLE_RATE

        if t < 0.18:
            f1, f2, f3 = 2100, 0, 0
            a, b, c, hiss = 0.9, 0.0, 0.0, 0.0
        elif t < 0.65:
            f1 = 950 + int(700 * (t - 0.18) / 0.47)
            f2, f3 = 1250, 0
            a, b, c, hiss = 0.65, 0.3, 0.0, 0.05
        else:
            dark = min(1.0, max(0.0, (t - 1.6) / 1.1))
            f1 = LOW_HZ + (tx % 11) * 6
            f2 = MID_HZ + (rx % 9) * 8
            f3 = HIGH_HZ + ((tx ^ rx) % 7) * 10
            a = 0.15 + dark * 0.05
            b = 0.12
            c = 0.08 - dark * 0.04
            hiss = 0.65 + dark * 0.15

        wave = (a * math.sin(TWO_PI * f1 * t) +
                b * math.sin(TWO_PI * f2 * t) +
                c * math.sin(TWO_PI * f3 * t))
        seed = (1103515245 * seed + 12345) & 0x7fffffff
        raw = ((seed >> 16) / 16384.0) - 1.0
        filtered = 0.91 * filtered + 0.09 * raw
        wave += hiss * filtered
        level = int(wave > 0.02)

        if last_level is None:
            first_level = last_level = level
            run_us = SAMPLE_US
        elif level == last_level:
            run_us += SAMPLE_US
        else:
            durations.append(run_us)
            last_level = level
            run_us = SAMPLE_US

    durations.append(run_us)
    # At playback, levels alternate between these durations.
    return [first_level, durations]


def prepare_cache():
    """One-time generation, showing progress even on a slow Pi 1."""
    total = 3 + 2 * len(TX_LEVELS) * len(RX_LEVELS)
    bank = {}
    print(f'Preparing {total} PPP noise sound blocks...', flush=True)

    def add_block(key, start_t, tx, rx, seed):
        bank[key] = generate_chunk(start_t, tx, rx, seed)
        print(f'  [{len(bank):02d}/{total}] {key}', flush=True)

    for frame in range(3):
        add_block(f'intro{frame}', frame * CHUNK_MS / 1000.0,
                  61, 113, 12345 + frame * 7919)

    # 12 data-driven variants, each with early and late tonal balance.
    for phase, start_t in (('early', 1.0), ('late', 3.5)):
        for tx_index, tx in enumerate(TX_LEVELS):
            for rx_index, rx in enumerate(RX_LEVELS):
                key = f'{phase}_{tx_index}_{rx_index}'
                seed = 12345 + tx * 101 + rx * 137
                add_block(key, start_t, tx, rx, seed)

    print('Compressing and saving sound cache...', flush=True)
    output = {'signature': cache_signature(), 'bank': bank}
    temporary = CACHE_FILE + '.tmp'
    try:
        with gzip.open(temporary, 'wt', encoding='utf-8', compresslevel=6) as file:
            json.dump(output, file, separators=(',', ':'))
        os.replace(temporary, CACHE_FILE)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'Prepared {len(bank)} sound blocks: {CACHE_FILE}', flush=True)


def load_cache(report_errors=True):
    try:
        with gzip.open(CACHE_FILE, 'rt', encoding='utf-8') as file:
            payload = json.load(file)
        if payload.get('signature') != cache_signature():
            raise ValueError('cache settings changed')
        bank = payload['bank']
        if len(bank) != 27:
            raise ValueError('sound bank incomplete')
        return bank
    except (OSError, ValueError, KeyError, TypeError) as exc:
        if report_errors:
            print(f'ppp_noise.py: sound cache missing or invalid ({exc}).\n'
                  'Run once: python3 ppp_noise.py --prepare\n'
                  'PPP recording will still be drained safely.', file=sys.stderr)
        return None


def build_gpio_pulses(piece):
    """Convert cached bit durations into pigpio pulses, no DSP needed."""
    level, durations = piece
    pulses = []
    for duration_us in durations:
        pulses.append(pigpio.pulse(GPIO_MASK if level else 0,
                                   0 if level else GPIO_MASK,
                                   duration_us))
        level ^= 1
    return pulses


class NoisePlayer:
    def __init__(self, debug=False):
        self.debug = debug
        self.events = queue.Queue(maxsize=EVENT_QUEUE_SIZE)
        self.started = None
        self.stop = threading.Event()
        self.thread = None

        if pigpio is None:
            print('ppp_noise.py: pigpio not installed; draining without sound',
                  file=sys.stderr)
            return

        self.thread = threading.Thread(target=self.play, daemon=True)
        self.thread.start()

    def feed(self, direction, data):
        if not data or self.stop.is_set():
            return
        now = time.monotonic()
        if self.started is None:
            self.started = now
        if now - self.started >= NOISE_SECONDS:
            return
        # Summarize live PPP data. Never block FIFO input on audio output.
        step = max(1, len(data) // 16)
        sampled = data[::step][:16]
        value = (sum(sampled) + (len(data) & 255)) & 255
        try:
            self.events.put_nowait((direction, value))
        except queue.Full:
            pass

    def recent_traffic(self, tx, rx):
        while True:
            try:
                direction, value = self.events.get_nowait()
            except queue.Empty:
                break
            if direction == 'TX':
                tx = value
            else:
                rx = value
        return tx, rx

    def play(self):
        # IMPORTANT: cache loading and pigpio run in THIS worker thread.
        # The parent continues draining pppd's FIFO even if these are slow.
        bank = load_cache()
        if bank is None:
            return

        pi = None
        previous_id = None
        tx, rx = 61, 113
        try:
            pi = pigpio.pi()
            if not pi.connected:
                raise RuntimeError('cannot connect to pigpiod (try: sudo pigpiod)')
            pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
            pi.write(GPIO_PIN, 0)
            pi.wave_clear()

            while not self.stop.is_set() and self.started is None:
                time.sleep(0.01)

            # Wave chunks have already been synthesized. Only one queued
            # waveform is kept in addition to the currently playing one.
            for frame in range(FRAME_COUNT):
                if self.stop.is_set():
                    break
                tx, rx = self.recent_traffic(tx, rx)
                if frame < 3:
                    key = f'intro{frame}'
                else:
                    phase = 'early' if frame * CHUNK_MS < 2700 else 'late'
                    key = f'{phase}_{min(tx // 64, 3)}_{min(rx // 86, 2)}'

                # Disk and synthesis do NOT occur inside this loop.
                pulses = build_gpio_pulses(bank[key])
                pi.wave_add_new()
                pi.wave_add_generic(pulses)
                wave_id = pi.wave_create_and_pad(50)
                if wave_id < 0:
                    raise RuntimeError(f'pigpio cannot allocate wave: {wave_id}')

                if previous_id is None:
                    pi.wave_send_once(wave_id)
                else:
                    if self.debug and not pi.wave_tx_busy():
                        print('ppp_noise.py: audio underrun', file=sys.stderr)
                    # pigpio synchronizes the new wave with the previous one.
                    pi.wave_send_using_mode(wave_id,
                                           pigpio.WAVE_MODE_ONE_SHOT_SYNC)
                    # Deleting the preceding wave before switchover corrupts
                    # DMA playback. Wait for the new wave to become active.
                    while not self.stop.is_set():
                        active = pi.wave_tx_at()
                        if active == wave_id:
                            break
                        if active == pigpio.NO_TX_WAVE:
                            # This can occur after a genuine underrun.
                            break
                        time.sleep(0.004)
                    if self.stop.is_set():
                        break
                    pi.wave_delete(previous_id)

                previous_id = wave_id

            if not self.stop.is_set():
                while pi.wave_tx_busy() and not self.stop.is_set():
                    time.sleep(0.01)
        except Exception as exc:
            print(f'ppp_noise.py: sound disabled: {exc}', file=sys.stderr)
        finally:
            if pi is not None:
                try:
                    pi.wave_tx_stop()
                    pi.wave_clear()
                    pi.write(GPIO_PIN, 0)
                except Exception:
                    pass
                pi.stop()
            self.stop.set()

    def close(self):
        self.stop.set()
        if self.thread is not None:
            self.thread.join(timeout=2.0)


def read_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        chunk = stream.read(count - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


def parse_record(stream, debug=False):
    player = NoisePlayer(debug)
    sent_bytes = received_bytes = 0
    elapsed = 0.0
    try:
        while True:
            tag_raw = stream.read(1)
            if not tag_raw:
                break
            tag = tag_raw[0]
            if tag in (TAG_SENT, TAG_RECEIVED):
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
                print(f'ppp_noise.py: unknown record tag {tag}, draining',
                      file=sys.stderr)
                while stream.read(4096):
                    pass
                return 1
    finally:
        player.close()

    if debug:
        print(f'PPP record ended: TX {sent_bytes}, RX {received_bytes} bytes')
    return 0


def main():
    if len(sys.argv) == 2 and sys.argv[1] == '--prepare':
        try:
            prepare_cache()
        except OSError as exc:
            print(f'ppp_noise.py: cannot prepare cache: {exc}', file=sys.stderr)
            return 1
        return 0
    if len(sys.argv) == 2 and sys.argv[1] == '--check':
        return 0 if load_cache(report_errors=False) is not None else 1
    if len(sys.argv) not in (2, 3):
        print('Usage: ppp_noise.py --prepare | --check | FIFO [debug]', file=sys.stderr)
        return 1
    fifo = sys.argv[1]
    debug = len(sys.argv) == 3 and sys.argv[2].lower() == 'debug'
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
