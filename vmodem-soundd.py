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
_client_context = threading.local()


class ClientDisconnected(Exception):
    pass


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


def perform(conn, pi, request):
    """Execute one audio command. Returns True when it releases the lease."""
    fields = request.split()
    if not fields:
        reply(conn, "ERROR EMPTY_COMMAND")
        return False
    command = fields[0].upper()
    try:
        if command == "TONE" and len(fields) == 3:
            frequency = float(fields[1])
            duration = float(fields[2])
            if not (math.isfinite(frequency) and 20 <= frequency <= 20000):
                raise ValueError("frequency must be between 20 and 20000 Hz")
            if not (math.isfinite(duration) and 0 <= duration <= 60):
                raise ValueError("duration must be between 0 and 60 seconds")
            tone(pi, frequency, duration)
        elif command == "DIALTONE" and len(fields) == 2:
            duration = float(fields[1])
            if not math.isfinite(duration) or not 0 <= duration <= 60:
                raise ValueError("duration must be between 0 and 60 seconds")
            tone(pi, DIALTONE_FREQ, duration)
        elif command == "DTMF" and len(fields) == 2:
            digits = fields[1]
            if len(digits) > 64 or any(d not in DTMF for d in digits):
                raise ValueError("invalid DTMF digits")
            play_dtmf(pi, digits)
        elif command == "RINGBACK" and len(fields) == 3:
            cycles = int(fields[1])
            pause = float(fields[2])
            if not 1 <= cycles <= 20 or not math.isfinite(pause) or not 0 <= pause <= 30:
                raise ValueError("invalid ringback parameters")
            play_ringback(pi, cycles, pause)
        elif command == "HANDSHAKE" and len(fields) == 2:
            if fields[1].upper() != "V34":
                raise ValueError("unsupported handshake profile")
            play_v34(pi)
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
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                worker = threading.Thread(target=handle_client, args=(conn,), daemon=True)
                worker.start()
                threads.append(worker)
                threads = [t for t in threads if t.is_alive()]
        finally:
            for worker in threads:
                worker.join(timeout=2)
            path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_stop)
    signal.signal(signal.SIGTERM, signal_stop)
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as exc:
        print(f"vmodem-soundd: {exc}", file=sys.stderr)
        sys.exit(1)
