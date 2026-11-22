#!/usr/bin/env python3
#
# TPC-VModem - shared GPIO sound server
#
# Emits Dial tone, DTMF, ringback, V.34 handshake and line noise via GPIO18.
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
import argparse
import gzip
import json
import queue
import subprocess
import stat
import struct
import sys
import time
import math
import signal
import socket
import select
import threading
import os
from pathlib import Path

import pigpio


def get_pi_model():
    path = Path("/proc/device-tree/model")
    return path.read_bytes().decode().rstrip("\x00")

try:
    model = get_pi_model()
except OSError:
    model = "Unknown"

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
V34_CACHE = Path(__file__).resolve().parents[1] / "share" / "v34_sound_v2.bin.gz"
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
_reload_requested = threading.Event()
_client_context = threading.local()


class ClientDisconnected(Exception):
    pass


def signal_reload(signum, frame):
    _reload_requested.set()


def signal_stop(signum, frame):
    global running
    running = False


def active():
    """Check shutdown and detect a client disappearing during playback."""
    if not running:
        return False
    conn = getattr(_client_context, "connection", None)
    if conn is None:
        return True
    readable, _, _ = select.select([conn], [], [], 0)
    if not readable:
        return True
    try:
        return bool(conn.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT))
    except BlockingIOError:
        return True
    except OSError:
        return False


def open_gpio():
    pi = pigpio.pi()
    if not pi.connected:
        raise RuntimeError("Cannot connect to pigpiod (try: sudo pigpiod)")
    return pi


def create_square_wave(pi, freq):
    """Create one repeating square-wave cycle for a single frequency."""
    period_us = int(round(1000000.0 / freq))
    high_us = period_us // 2
    low_us = period_us - high_us

    pi.wave_add_new()
    pi.wave_add_generic([
        pigpio.pulse(GPIO_MASK, 0, high_us),
        pigpio.pulse(0, GPIO_MASK, low_us),
    ])
    wave_id = pi.wave_create()
    if wave_id < 0:
        raise RuntimeError(f"pigpio wave_create failed: {wave_id}")
    return wave_id


def tone(pi, freq, duration=None):
    wave_id = None

    try:
        pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
        pi.write(GPIO_PIN, 0)

        wave_id = create_square_wave(pi, freq)
        pi.wave_send_repeat(wave_id)

        if duration is not None:
            end = time.monotonic() + duration
            while active() and time.monotonic() < end:
                time.sleep(0.05)
        else:
            while active():
                time.sleep(0.1)

    finally:
        pi.wave_tx_stop()
        if wave_id is not None:
            pi.wave_delete(wave_id)
        pi.write(GPIO_PIN, 0)


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
        while active() and pi.wave_tx_busy():
            time.sleep(0.005)
    finally:
        if pi.wave_tx_busy():
            pi.wave_tx_stop()
        pi.wave_delete(wave_id)
        pi.write(GPIO_PIN, 0)


def wait(seconds):
    """Interruptible wait, used for the pause between ringback tones."""
    end = time.monotonic() + seconds
    while active():
        remaining = end - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(0.05, remaining))


def play_ringback(pi, cycles, pause_seconds):
    """425 Hz ringback with configurable pauses between rings."""
    wave_id = None

    try:
        pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
        pi.write(GPIO_PIN, 0)

        wave_id = create_square_wave(pi, DIALTONE_FREQ)

        for cycle in range(cycles):
            if not active():
                break

            pi.wave_send_repeat(wave_id)
            wait(RINGBACK_TONE_SECONDS)
            pi.wave_tx_stop()
            pi.write(GPIO_PIN, 0)

            # No extra pause after the final ring.
            if cycle < cycles - 1:
                wait(pause_seconds)

    finally:
        pi.wave_tx_stop()
        if wave_id is not None:
            pi.wave_delete(wave_id)
        pi.write(GPIO_PIN, 0)


def play_dtmf(pi, number):

    try:
        pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
        pi.write(GPIO_PIN, 0)

        for digit in number:
            if not active():
                break
            if digit not in DTMF:
                continue

            freq1, freq2 = DTMF[digit]
            pulses = make_dual_tone(freq1, freq2, DTMF_TIME)

            # pigpiod outputs this short waveform via DMA.
            play_pulses(pi, pulses)

            if active():
                wait(DTMF_GAP)

    finally:
        pi.wave_tx_stop()
        pi.write(GPIO_PIN, 0)



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


def play_v34(pi):
    """Stream the prepared V.8/V.34 handshake using pigpio DMA waves."""
    sample_rate, count, data = load_v34_cache()
    # 40 kHz GPIO sample rate = 25 us, exact integer pigpio timing.
    sample_us = 1000000 // sample_rate
    chunk_samples = sample_rate * V34_CHUNK_MS // 1000
    previous_id = None
    try:
        pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
        pi.write(GPIO_PIN, 0)
        pi.wave_clear()
        for start in range(0, count, chunk_samples):
            if not active():
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
                while active():
                    active_wave = pi.wave_tx_at()
                    if active_wave == wave_id:
                        break
                    if active_wave == pigpio.NO_TX_WAVE:
                        # A slow Pi may underrun while preparing the next wave.
                        print("vmodem-soundd: V.34 playback underrun", file=sys.stderr)
                        pi.wave_send_once(wave_id)
                        break
                    time.sleep(0.004)
                if not active():
                    break
                pi.wave_delete(previous_id)
            else:
                print("vmodem-soundd: V.34 playback underrun", file=sys.stderr)
                pi.wave_delete(previous_id)
                pi.wave_send_once(wave_id)
            previous_id = wave_id

        while active() and pi.wave_tx_busy():
            time.sleep(0.01)
    finally:
        pi.wave_tx_stop()
        pi.wave_clear()
        pi.write(GPIO_PIN, 0)

# The daemon owns the GPIO output, and clients lease it only while dialing.
SOCKET_PATH = "/run/vmodem/sound.sock"
MAX_COMMAND_BYTES = 256
_owner_lock = threading.Lock()
_owner = None
_sessions_lock = threading.Lock()
_sessions = {}


def cleanup_gpio(pi):
    """Complete hardware cleanup before the lease becomes available."""
    try:
        pi.wave_tx_stop()
        pi.wave_clear()
        pi.write(GPIO_PIN, 0)
    finally:
        pi.stop()


def reply(conn, message):
    conn.sendall((message + "\n").encode("ascii"))




# PPP data audio. Synthesis and record format derive from ppp_noise.py.
def needs_cache():
    return model.startswith('Raspberry Pi Model ')

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

    def render(self, count, influence=0, fade_out=False, fade_duration=NOISE_SECONDS):
        # Only the pseudo-random symbol sequence reacts to the PPP bytes.
        register = (self.register ^ (influence & 0x7fffff)) or 1
        clock = self.symbol_clock
        target_i, target_q = self.target_i, self.target_q
        shaped_i, shaped_q = self.shaped_i, self.shaped_q
        carrier_cos, carrier_sin = self.carrier_cos, self.carrier_sin
        step_cos = math.cos(TWO_PI * CARRIER_HZ / SAMPLE_RATE)
        step_sin = math.sin(TWO_PI * CARRIER_HZ / SAMPLE_RATE)
        start_sample = self.samples
        fade_start = int(max(0.0, fade_duration - FADE_SECONDS) * SAMPLE_RATE)
        fade_end = int(fade_duration * SAMPLE_RATE)
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
        # Keep the oscillator numerically stable for continuous sessions.
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
            print(f'vmodem-soundd: sound cache missing or invalid ({exc}).\n'
                  'Run once: python3 vmodem-soundd.py --prepare-noise-cache\n'
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
    """FIFO events are consumed independently from exclusive GPIO playback."""

    def __init__(self, session, requested_duration):
        self.session = session
        self.cached = needs_cache()
        modem_count = active_modem_count()
        self.continuous = (requested_duration == 'CONTINUOUS'
                           and not self.cached and modem_count == 1)
        if modem_count > 1:
            # Multiple serial modems must never produce permanent GPIO noise.
            self.duration = (2.0 if requested_duration == 'CONTINUOUS'
                             else min(2.0, float(requested_duration)))
        elif requested_duration == 'CONTINUOUS':
            # Pi 1 only supports its precomputed six-second cache.
            self.duration = NOISE_SECONDS
        else:
            self.duration = float(requested_duration)

        if self.cached and self.duration > NOISE_SECONDS:
            print('vmodem-soundd: limiting cached PPP audio to 6 seconds',
                  file=sys.stderr)
            self.duration = NOISE_SECONDS

        self.events = queue.Queue(maxsize=EVENT_QUEUE_SIZE)
        self.started = None
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.play, daemon=True)
        self.thread.start()

    def feed(self, direction, data):
        if not data or self.stop.is_set():
            return
        if self.started is None:
            self.started = time.monotonic()
        if not self.continuous and time.monotonic() - self.started >= self.duration:
            return
        step = max(1, len(data) // 16)
        sampled = data[::step][:16]
        value = (sum(sampled) + (len(data) & 255)) & 255
        try:
            self.events.put_nowait((direction, value))
        except queue.Full:
            pass

    def recent_traffic(self, tx, rx):
        activity = False
        while True:
            try:
                direction, value = self.events.get_nowait()
            except queue.Empty:
                break
            activity = True
            if direction == 'TX':
                tx = value
            else:
                rx = value
        return tx, rx, activity

    def play(self):
        global _owner
        while not self.stop.is_set() and self.started is None and running:
            self.stop.wait(0.01)
        if self.stop.is_set() or not running:
            return

        # An active dial wins. PPP recording still drains if audio is busy.
        with _owner_lock:
            if _owner is not None:
                print('vmodem-soundd: PPP audio skipped, GPIO busy', file=sys.stderr)
                return
            _owner = self.session

        pi = None
        try:
            bank = load_cache() if self.cached else None
            if self.cached and bank is None:
                return
            if self.stop.is_set():
                return
            pi = open_gpio()
            pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
            pi.write(GPIO_PIN, 0)
            pi.wave_clear()
            previous_id = None
            tx, rx = 61, 113
            synth = QamSynth() if not self.cached else None
            count = SAMPLE_RATE * (CHUNK_MS if self.cached else LIVE_CHUNK_MS) // 1000
            frame_count = (int(SAMPLE_RATE * self.duration) + count - 1) // count
            sample_number = 0
            frame = 0
            while running and not self.stop.is_set() and (self.continuous or frame < frame_count):
                tx, rx, activity = self.recent_traffic(tx, rx)
                if self.cached:
                    piece = bank[f'{"traffic" if activity else "idle"}_{frame}']
                else:
                    chunk = count if self.continuous else min(
                        count, int(SAMPLE_RATE * self.duration) - sample_number)
                    fingerprint = ((tx << 9) ^ (rx << 1) ^ (tx * 257)) if activity else 0
                    piece = synth.render(chunk, influence=fingerprint,
                                         fade_out=not self.continuous,
                                         fade_duration=self.duration)
                    sample_number += chunk
                pi.wave_add_new()
                pi.wave_add_generic(build_gpio_pulses(piece))
                wave_id = pi.wave_create_and_pad(50)
                if wave_id < 0:
                    raise RuntimeError(f'pigpio cannot allocate wave: {wave_id}')
                if previous_id is None or not pi.wave_tx_busy():
                    if previous_id is not None:
                        print('vmodem-soundd: PPP audio underrun', file=sys.stderr)
                    pi.wave_send_once(wave_id)
                else:
                    pi.wave_send_using_mode(wave_id, pigpio.WAVE_MODE_ONE_SHOT_SYNC)
                    while running and not self.stop.is_set():
                        wave_at = pi.wave_tx_at()
                        if wave_at in (wave_id, pigpio.NO_TX_WAVE):
                            break
                        self.stop.wait(0.004)
                    if self.stop.is_set() or not running:
                        break
                if previous_id is not None:
                    pi.wave_delete(previous_id)
                previous_id = wave_id
                frame += 1
            while running and not self.stop.is_set() and pi.wave_tx_busy():
                self.stop.wait(0.01)
        except Exception as exc:
            print(f'vmodem-soundd: PPP audio disabled: {exc}', file=sys.stderr)
        finally:
            # Never make the lease available until GPIO cleanup completes.
            cleaned = False
            try:
                if pi is not None:
                    cleanup_gpio(pi)
                cleaned = True
            except Exception as exc:
                print(f'vmodem-soundd: PPP GPIO cleanup failed: {exc}', file=sys.stderr)
            if cleaned:
                with _owner_lock:
                    if _owner is self.session:
                        _owner = None
            # Preserve original behavior: the FIFO reader continues after sound ends.

    def close(self):
        self.stop.set()
        if self.thread is not None:
            self.thread.join(timeout=3)


class InterruptibleFIFO:
    """Read from an O_RDWR FIFO without EOF races before pppd connects."""

    def __init__(self, path, stop):
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)
        self.stop = stop

    def read(self, size):
        while running and not self.stop.is_set():
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            if ready:
                try:
                    data = os.read(self.fd, size)
                    if data:
                        return data
                except BlockingIOError:
                    continue
        return b''

    def close(self):
        os.close(self.fd)


class PPPNoiseSession:
    def __init__(self, path, duration):
        self.path = path
        self.duration = duration
        self.stop = threading.Event()
        self.player = None
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def run(self):
        try:
            with_fifo = InterruptibleFIFO(self.path, self.stop)
            try:
                # Reader is ready before any player startup or cache loading.
                self.player = NoisePlayer(self, self.duration)
                parse_ppp_record(with_fifo, self.player)
            finally:
                with_fifo.close()
        except Exception as exc:
            print(f'vmodem-soundd: PPP record reader failed: {exc}', file=sys.stderr)
        finally:
            if self.player is not None:
                self.player.close()
            with _sessions_lock:
                if _sessions.get(self.path) is self:
                    del _sessions[self.path]

    def close(self):
        self.stop.set()
        if self.player is not None:
            self.player.stop.set()
        self.thread.join(timeout=3)


def read_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        chunk = stream.read(count - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


def parse_ppp_record(stream, player):
    while running and not player.session.stop.is_set():
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
            player.feed('TX' if tag == TAG_SENT else 'RX', data)
        elif tag == TAG_TIME_SHORT:
            if read_exact(stream, 1) is None:
                break
        elif tag == TAG_TIME_LONG or tag == TAG_START:
            if read_exact(stream, 4) is None:
                break
        elif tag in (TAG_SEND_EOF, TAG_RECV_EOF):
            pass
        else:
            print(f'vmodem-soundd: unknown PPP record tag {tag}', file=sys.stderr)
            # Don't stop consuming the FIFO if a record is not understood.
            while stream.read(4096):
                pass
            break


def active_modem_count():
    try:
        result = subprocess.run(
            ['systemctl', 'list-units', '--type=service', '--state=active',
             '--plain', '--no-legend', 'vmodem@*.service'],
            capture_output=True, text=True, timeout=3, check=True)
        return sum(1 for line in result.stdout.splitlines()
                   if line.split() and line.split()[0].startswith('vmodem@')
                   and line.split()[0].endswith('.service'))
    except (OSError, subprocess.SubprocessError) as exc:
        print(f'vmodem-soundd: cannot count active modems: {exc}', file=sys.stderr)
        return 2  # Fail safe: no unlimited PPP audio.


def process_reload():
    count = active_modem_count()
    print(f'vmodem-soundd: SIGHUP, active modems={count}', file=sys.stderr)
    if count > 1:
        with _sessions_lock:
            sessions = list(_sessions.values())
        for session in sessions:
            player = session.player
            if player is not None and player.continuous:
                player.continuous = False
                player.stop.set()  # Stops ONLY the audio worker, not the FIFO reader.


def is_safe_fifo(path):
    return (path.startswith('/run/tpc-vmodem-ppp-') and path.endswith('.fifo')
            and len(path) <= 200 and os.path.isabs(path)
            and stat.S_ISFIFO(os.stat(path).st_mode))


def handle_ppp_control(conn, command):
    fields = command.split()
    if len(fields) == 3 and fields[0] == 'PPP_START':
        path, duration = fields[1:]
        if not is_safe_fifo(path):
            reply(conn, 'ERROR INVALID_ARGUMENT')
            return
        if duration != 'CONTINUOUS':
            try:
                seconds = float(duration)
            except ValueError:
                reply(conn, 'ERROR INVALID_ARGUMENT')
                return
            if not math.isfinite(seconds) or not 0 < seconds <= 3600:
                reply(conn, 'ERROR INVALID_ARGUMENT')
                return
        with _sessions_lock:
            if path in _sessions:
                reply(conn, 'ERROR ALREADY_RUNNING')
                return
            session = PPPNoiseSession(path, duration)
            _sessions[path] = session
        session.start()
        reply(conn, 'OK')
    elif len(fields) == 2 and fields[0] == 'PPP_STOP':
        path = fields[1]
        with _sessions_lock:
            session = _sessions.get(path)
        if session is not None:
            session.close()
        reply(conn, 'DONE')
    else:
        reply(conn, 'ERROR UNKNOWN_COMMAND')


def perform(conn, pi, request):
    """Execute one audio command. Returns True when it releases the lease."""
    fields = request.split()
    if not fields:
        reply(conn, "ERROR EMPTY_COMMAND")
        return False

    # The output mode is optional for compatibility with existing clients.
    # SILENT preserves the duration without generating waves or touching GPIO.
    mode = "AUDIBLE"
    if fields[-1].upper() in ("AUDIBLE", "SILENT"):
        mode = fields.pop().upper()
    audible = mode == "AUDIBLE"
    command = fields[0].upper()

    try:
        if command == "TONE" and len(fields) == 3:
            frequency = float(fields[1])
            duration = float(fields[2])
            if not (math.isfinite(frequency) and 20 <= frequency <= 20000):
                raise ValueError("frequency must be between 20 and 20000 Hz")
            if not (math.isfinite(duration) and 0 <= duration <= 60):
                raise ValueError("duration must be between 0 and 60 seconds")
            if audible:
                tone(pi, frequency, duration)
            else:
                wait(duration)
        elif command == "DIALTONE" and len(fields) == 2:
            duration = float(fields[1])
            if not math.isfinite(duration) or not 0 <= duration <= 60:
                raise ValueError("duration must be between 0 and 60 seconds")
            if audible:
                tone(pi, DIALTONE_FREQ, duration)
            else:
                wait(duration)
        elif command == "DTMF" and len(fields) == 2:
            digits = fields[1]
            if len(digits) > 64 or any(d not in DTMF for d in digits):
                raise ValueError("invalid DTMF digits")
            if audible:
                play_dtmf(pi, digits)
            else:
                # play_dtmf also waits one DTMF_GAP after the final digit.
                wait(len(digits) * (DTMF_TIME + DTMF_GAP))
        elif command == "RINGBACK" and len(fields) == 3:
            cycles = int(fields[1])
            pause = float(fields[2])
            if not 1 <= cycles <= 20 or not math.isfinite(pause) or not 0 <= pause <= 30:
                raise ValueError("invalid ringback parameters")
            if audible:
                play_ringback(pi, cycles, pause)
            else:
                # No pause after the final ring.
                wait(cycles * RINGBACK_TONE_SECONDS + (cycles - 1) * pause)
        elif command == "HANDSHAKE" and len(fields) == 2:
            if fields[1].upper() != "V34":
                raise ValueError("unsupported handshake profile")
            if audible:
                play_v34(pi)
            else:
                # The cached sample count defines the exact intended duration.
                sample_rate, count, _ = load_v34_cache()
                wait(count / sample_rate)
            if not active():
                raise ClientDisconnected()
            # The handshake is the last audio step. Release immediately.
            return True
        else:
            reply(conn, "ERROR UNKNOWN_COMMAND")
            return False
    except (ValueError, OverflowError) as exc:
        reply(conn, "ERROR INVALID_ARGUMENT")
        print(f"vmodem-soundd: invalid command: {exc}", file=sys.stderr)
        return False
    if not active():
        raise ClientDisconnected()
    reply(conn, "DONE")
    return False


def handle_client(conn):
    global _owner
    _client_context.connection = conn
    acquired = False
    pi = None
    release_reply = None
    with conn:
        try:
            buffer = b""
            while running:
                # New clients can receive BUSY while the owner is playing.
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buffer += chunk
                if len(buffer) > MAX_COMMAND_BYTES and b"\n" not in buffer:
                    reply(conn, "ERROR COMMAND_TOO_LONG")
                    break
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1)
                    if len(raw) > MAX_COMMAND_BYTES:
                        reply(conn, "ERROR COMMAND_TOO_LONG")
                        return
                    try:
                        command = raw.decode("ascii").strip()
                    except UnicodeDecodeError:
                        reply(conn, "ERROR INVALID_ENCODING")
                        continue
                    if command.startswith('PPP_'):
                        if acquired:
                            reply(conn, 'ERROR ALREADY_OWNED')
                        else:
                            try:
                                handle_ppp_control(conn, command)
                            except (OSError, ValueError) as exc:
                                print(f'vmodem-soundd: PPP control error: {exc}', file=sys.stderr)
                                reply(conn, 'ERROR AUDIO_FAILURE')
                        return
                    if command == "ACQUIRE":
                        if acquired:
                            reply(conn, "ERROR ALREADY_OWNED")
                            continue
                        with _owner_lock:
                            busy = _owner is not None
                            if not busy:
                                _owner = conn
                                acquired = True
                        if busy:
                            reply(conn, "BUSY")
                            continue
                        try:
                            pi = open_gpio()
                            pi.set_mode(GPIO_PIN, pigpio.OUTPUT)
                            pi.write(GPIO_PIN, 0)
                        except Exception:
                            # Finally will release this lease after cleanup.
                            raise
                        reply(conn, "OK")
                    elif command in ("RELEASE", "ABORT"):
                        if not acquired:
                            reply(conn, "ERROR NOT_OWNER")
                            continue
                        release_reply = "RELEASED"
                        return  # The finally block cleans GPIO first.
                    else:
                        if not acquired:
                            reply(conn, "ERROR NOT_OWNER")
                            continue
                        done = perform(conn, pi, command)
                        if done:
                            release_reply = "RELEASED"
                            return  # Auto release when handshake finishes.
                if len(buffer) > MAX_COMMAND_BYTES:
                    reply(conn, "ERROR COMMAND_TOO_LONG")
                    break
        except (BrokenPipeError, ConnectionResetError, ClientDisconnected):
            pass
        except (OSError, RuntimeError, ValueError) as exc:
            print(f"vmodem-soundd: client error: {exc}", file=sys.stderr)
            try:
                reply(conn, "ERROR AUDIO_FAILURE")
            except OSError:
                pass
        finally:
            if acquired:
                cleanup_ok = False
                try:
                    if pi is not None:
                        cleanup_gpio(pi)
                    cleanup_ok = True
                except Exception as exc:
                    print(f"vmodem-soundd: GPIO cleanup failed: {exc}", file=sys.stderr)
                    # Keep the lease occupied until the daemon is restarted.
                if cleanup_ok:
                    with _owner_lock:
                        if _owner is conn:
                            _owner = None
                    if release_reply is not None:
                        try:
                            reply(conn, release_reply)
                        except OSError:
                            pass
            _client_context.connection = None


def main():
    path = Path(SOCKET_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        # Never unlink another running daemon's socket.
        with socket.socket(socket.AF_UNIX) as probe:
            try:
                probe.connect(SOCKET_PATH)
            except ConnectionRefusedError:
                path.unlink()
            else:
                raise RuntimeError(f"Socket already in use: {SOCKET_PATH}")

    with socket.socket(socket.AF_UNIX) as server:
        server.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o660)
        server.listen(16)
        server.settimeout(0.25)
        print(f"vmodem-soundd: listening on {SOCKET_PATH}", flush=True)
        threads = []
        try:
            while running:
                if _reload_requested.is_set():
                    _reload_requested.clear()
                    process_reload()
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                worker = threading.Thread(target=handle_client, args=(conn,), daemon=True)
                worker.start()
                threads.append(worker)
                threads = [t for t in threads if t.is_alive()]
        finally:
            with _sessions_lock:
                sessions = list(_sessions.values())
            for session in sessions:
                session.close()
            for worker in threads:
                worker.join(timeout=2)
            path.unlink(missing_ok=True)
    return 0


def cli_main(argv=None):
    parser = argparse.ArgumentParser(
        description="TPC-VModem shared GPIO sound server",
        epilog="Examples:\n"
               "  %(prog)s --daemon\n"
               "  %(prog)s --prepare-noise-cache",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "-d", "--daemon", action="store_true",
        help="run the audio daemon (foreground, suitable for systemd)",
    )
    mode.add_argument(
        "--prepare-noise-cache", action="store_true",
        help="generate the PPP noise cache for Raspberry Pi 1",
    )
    args = parser.parse_args(argv)

    if not args.daemon and not args.prepare_noise_cache:
        parser.print_help()
        return 0

    if args.prepare_noise_cache:
        prepare_cache()
        return 0

    signal.signal(signal.SIGHUP, signal_reload)
    signal.signal(signal.SIGINT, signal_stop)
    signal.signal(signal.SIGTERM, signal_stop)
    try:
        return main()
    except (RuntimeError, OSError) as exc:
        print(f"vmodem-soundd: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(cli_main())
