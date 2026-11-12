#!/usr/bin/env python3
#
# TPC-VModem - V.34-inspired PPP data-phase audio
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
"""V.34-inspired PPP data-phase sound from pppd's live record FIFO.

A continuously scrambled 16-QAM-like signal replaces the earlier switching
pitches and handshake noises. This is an acoustic approximation, not a
standards-compliant V.34 modem or an analog telephone-line emulator.

Raspberry Pi 1: use precomputed idle/traffic sound blocks from a disk cache.
Other models: synthesize live audio; actual PPP data affects the scrambler.
ATM1 plays six seconds. ATM2 stays audible during PPP on Pi 2+, but is
limited to six seconds on Pi 1. The FIFO is drained for the entire session.

    python3 ppp_noise.py --prepare    # Optional: precompute a cache on any host
    python3 ppp_noise.py --check      # Cache required only on Raspberry Pi 1
    python3 ppp_noise.py FIFO [debug]
"""

import gzip
import json
import math
import os
import queue
import signal
import sys
import threading
import time
from pathlib import Path

try:
    import pigpio
except ImportError:
    pigpio = None

GPIO_PIN = 18                   # BCM 18, physical pin 12


def get_pi_model():
    try:
        return Path('/proc/device-tree/model').read_bytes().decode().rstrip('\x00')
    except OSError:
        return ''


def needs_cache():
    # Same Raspberry Pi 1 identification as in sound.py.
    return get_pi_model().startswith('Raspberry Pi Model ')


NOISE_SECONDS = 6.0
SAMPLE_RATE = 20000
CHUNK_MS = 250                  # Cached blocks: 24 per connection
LIVE_CHUNK_MS = 250             # Same timing for live synthesis
CARRIER_HZ = 1920              # V.34-inspired answer-side carrier
SYMBOL_RATE = 2400             # Plausible V.34 symbol rate
SHAPING = 0.22                 # Simple I/Q pulse smoothing (not a true RRC)
FADE_SECONDS = 0.10

CACHE_VERSION = 2
CACHE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          'ppp_noise_cache_v2.json.gz')
EVENT_QUEUE_SIZE = 32
GPIO_MASK = 1 << GPIO_PIN
TWO_PI = 2.0 * math.pi
FRAME_COUNT = int(round(NOISE_SECONDS * 1000 / CHUNK_MS))
SAMPLES_PER_CHUNK = SAMPLE_RATE * CHUNK_MS // 1000
SAMPLE_US = 1000000 // SAMPLE_RATE

TAG_SENT = 1
TAG_RECEIVED = 2
TAG_SEND_EOF = 3
TAG_RECV_EOF = 4
TAG_TIME_LONG = 5
TAG_TIME_SHORT = 6
TAG_START = 7


def cache_signature():
    return [CACHE_VERSION, SAMPLE_RATE, CHUNK_MS, CARRIER_HZ,
            SYMBOL_RATE, SHAPING, NOISE_SECONDS]


class QamSynth:
    """Continuous pseudo-scrambled, pulse-shaped passband data signal.

    The symbol stream runs even when PPP is idle, as a real modem's data
    carrier would. Actual PPP traffic perturbs future symbols, NOT the carrier
    frequency or loudness. A one-bit sign output suits the GPIO speaker;
    no NumPy or SciPy is required at runtime.
    """

    def __init__(self, seed=0x5A3217):
        self.register = seed & 0x7fffff or 1
        self.symbol_clock = SAMPLE_RATE  # Generate the first symbol immediately.
        self.target_i = self.target_q = 0.0
        self.shaped_i = self.shaped_q = 0.0
        self.carrier_cos = 1.0
        self.carrier_sin = 0.0
        self.samples = 0

    def render(self, count, influence=0, fade_out=False):
        # Only the pseudo-random symbol sequence reacts to the PPP bytes.
        register = (self.register ^ (influence & 0x7fffff)) or 1
        clock = self.symbol_clock
        target_i, target_q = self.target_i, self.target_q
        shaped_i, shaped_q = self.shaped_i, self.shaped_q
        carrier_cos, carrier_sin = self.carrier_cos, self.carrier_sin
        step_cos = math.cos(TWO_PI * CARRIER_HZ / SAMPLE_RATE)
        step_sin = math.sin(TWO_PI * CARRIER_HZ / SAMPLE_RATE)
        start_sample = self.samples
        fade_start = int((NOISE_SECONDS - FADE_SECONDS) * SAMPLE_RATE)
        fade_end = int(NOISE_SECONDS * SAMPLE_RATE)
        first_level = last_level = None
        durations = []
        run_us = 0

        for n in range(count):
            if clock >= SAMPLE_RATE:
                clock -= SAMPLE_RATE
                # 23-bit pseudo-random shift register, inspired by a modem
                # scrambler. It is deliberately NOT a full V.34 encoder.
                bits = 0
                for bit in range(4):
                    feedback = ((register >> 22) ^ (register >> 17)) & 1
                    register = ((register << 1) | feedback) & 0x7fffff
                    bits |= feedback << bit
                # 16-QAM-like constellation. No tones are changed by traffic.
                target_i = (-3.0, -1.0, 3.0, 1.0)[bits & 3]
                target_q = (-3.0, -1.0, 3.0, 1.0)[bits >> 2]
            clock += SYMBOL_RATE
            shaped_i += SHAPING * (target_i - shaped_i)
            shaped_q += SHAPING * (target_q - shaped_q)
            wave = shaped_i * carrier_cos - shaped_q * carrier_sin

            # In one-bit output, an increasing threshold gives a short fade
            # rather than incorrectly multiplying a waveform before sign().
            threshold = 0.0
            if fade_out and start_sample + n >= fade_start:
                threshold = 5.0 * min(1.0,
                    (start_sample + n - fade_start) / (fade_end - fade_start))
            level = int(wave > threshold)

            if last_level is None:
                first_level = last_level = level
                run_us = SAMPLE_US
            elif level == last_level:
                run_us += SAMPLE_US
            else:
                durations.append(run_us)
                last_level = level
                run_us = SAMPLE_US

            # Recursive oscillator avoids costly sine calls per audio sample.
            carrier_cos, carrier_sin = (
                carrier_cos * step_cos - carrier_sin * step_sin,
                carrier_sin * step_cos + carrier_cos * step_sin)

        if run_us:
            durations.append(run_us)
        self.register = register
        self.symbol_clock = clock
        self.target_i, self.target_q = target_i, target_q
        self.shaped_i, self.shaped_q = shaped_i, shaped_q
        # Keep the oscillator numerically stable for long ATM2 sessions.
        norm = math.hypot(carrier_cos, carrier_sin)
        self.carrier_cos, self.carrier_sin = carrier_cos / norm, carrier_sin / norm
        self.samples += count
        return [first_level, durations]


def prepare_cache():
    """Prepare two six-second Pi 1 tracks: idle and traffic-active."""
    bank = {}
    print(f'Preparing {FRAME_COUNT * 2} V.34-inspired sound blocks...', flush=True)
    for mode, seed in (('idle', 0x5A3217), ('traffic', 0x3E19AB)):
        synth = QamSynth(seed)
        for frame in range(FRAME_COUNT):
            # Each bank is a coherent six-second stream: no 250ms sound loop.
            bank[f'{mode}_{frame}'] = synth.render(
                SAMPLES_PER_CHUNK, fade_out=(frame == FRAME_COUNT - 1))
            print(f'  [{len(bank):02d}/{FRAME_COUNT * 2}] {mode}_{frame}', flush=True)

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
        if len(bank) != FRAME_COUNT * 2 or any(
                f'{mode}_{frame}' not in bank
                for mode in ('idle', 'traffic') for frame in range(FRAME_COUNT)):
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
        self.cached = needs_cache()
        self.continuous = not self.cached and os.environ.get('speaker_mode') == '2'
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
        if not self.continuous and now - self.started >= NOISE_SECONDS:
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
        active = False
        while True:
            try:
                direction, value = self.events.get_nowait()
            except queue.Empty:
                break
            active = True
            if direction == 'TX':
                tx = value
            else:
                rx = value
        return tx, rx, active

    def play(self):
        # Disk loading, live synthesis and pigpio operate only in this worker.
        # The main thread must continue reading the record FIFO regardless.
        bank = load_cache() if self.cached else None
        if self.cached and bank is None:
            return
        if self.debug:
            mode = 'cached (Pi 1)' if self.cached else (
                'live (continuous)' if self.continuous else 'live (6 seconds)')
            print(f'ppp_noise.py: {mode} audio', file=sys.stderr)

        pi = None
        previous_id = None
        tx, rx = 61, 113
        synth = QamSynth() if not self.cached else None
        sample_number = 0
        frame_ms = CHUNK_MS if self.cached else LIVE_CHUNK_MS
        count = SAMPLE_RATE * frame_ms // 1000
        frame_count = (int(SAMPLE_RATE * NOISE_SECONDS) + count - 1) // count
        try:
            pi = pigpio.pi()  # Same address selection as sound.py.
            if not pi.connected:
                raise RuntimeError('cannot connect to pigpiod (try: sudo pigpiod)')
            pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
            pi.write(GPIO_PIN, 0)
            pi.wave_clear()

            while not self.stop.is_set() and self.started is None:
                time.sleep(0.01)

            frame = 0
            while not self.stop.is_set() and (self.continuous or frame < frame_count):
                tx, rx, active = self.recent_traffic(tx, rx)
                if self.cached:
                    # Pi 1's cached alternatives have the same broad texture.
                    # Traffic affects block selection, never pitch or volume.
                    piece = bank[f'{"traffic" if active else "idle"}_{frame}']
                else:
                    chunk = (count if self.continuous else
                             min(count, int(SAMPLE_RATE * NOISE_SECONDS) - sample_number))
                    started = time.monotonic()
                    fingerprint = ((tx << 9) ^ (rx << 1) ^ (tx * 257)) if active else 0
                    piece = synth.render(chunk, influence=fingerprint,
                                         fade_out=not self.continuous)
                    if self.debug:
                        print(f'ppp_noise.py: synthesized {chunk * 1000 // SAMPLE_RATE} ms in '
                              f'{(time.monotonic() - started)*1000:.0f} ms',
                              file=sys.stderr)
                    sample_number += chunk

                pi.wave_add_new()
                pi.wave_add_generic(build_gpio_pulses(piece))
                wave_id = pi.wave_create_and_pad(50)
                if wave_id < 0:
                    raise RuntimeError(f'pigpio cannot allocate wave: {wave_id}')

                if previous_id is None or not pi.wave_tx_busy():
                    if previous_id is not None and self.debug:
                        print('ppp_noise.py: audio underrun', file=sys.stderr)
                    pi.wave_send_once(wave_id)
                else:
                    pi.wave_send_using_mode(wave_id,
                                            pigpio.WAVE_MODE_ONE_SHOT_SYNC)
                    # Do not delete a wave while DMA is still using it.
                    while not self.stop.is_set():
                        active = pi.wave_tx_at()
                        if active in (wave_id, pigpio.NO_TX_WAVE):
                            break
                        time.sleep(0.004)
                    if self.stop.is_set():
                        break
                if previous_id is not None:
                    pi.wave_delete(previous_id)
                previous_id = wave_id
                frame += 1

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
        # Live synthesis does not need a disk cache.
        return 0 if not needs_cache() or load_cache(report_errors=False) is not None else 1
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


def handle_sigterm(signum, frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    # ppp.sh terminates the reader when pppd exits. Run normal cleanup.
    signal.signal(signal.SIGTERM, handle_sigterm)
    sys.exit(main())
