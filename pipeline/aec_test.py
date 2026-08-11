"""M1 AEC Test-Skript — Simuliert Echo und testet Echo-Unterdrückung.

Ohne echte Hardware simuliert dieses Skript:
1. Ein Mikrofon-Signal (Sprache)
2. Ein Playback-Signal (was der Lautsprecher ausgibt)
3. Das Echo-Signal (Playback, das ins Mikrofon zurückkoppelt)
4. AEC-Verarbeitung (simuliert via spektraler Subtraktion)

Test-Szenarien (E1-E5):
  E1: AEC off, Lautsprecher — Echo erwartet (Baseline)
  E2: AEC on (Android AudioFX simuliert), Lautsprecher
  E3: AEC on (iOS AVAudioSession simuliert), Lautsprecher
  E4: AEC + BT-Headset, Lautsprecher
  E5: AEC + BT-Headset (beide Geräte) — Feedback-Loop-Test

Nutzung:
  python -m pipeline.aec_test --scenario E2 --input audio_samples/S1.wav
"""

import argparse
import json
import time
import sys
from pathlib import Path
from dataclasses import dataclass, field

import numpy as np

# Add parent to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from pipeline.audio_io import load_wav, play_audio
from pipeline.config import SAMPLE_RATE

# ── Echo Simulation ────────────────────────────────────────────────────

@dataclass
class EchoParams:
    """Parameters for echo simulation."""
    delay_ms: float = 50.0       # Echo delay (acoustic path)
    attenuation_db: float = -20.0  # How much quieter the echo is
    room_reverb_ms: float = 200.0  # Room reverberation tail
    feedback_gain: float = 0.3    # How much output feeds back into input

    @property
    def delay_samples(self) -> int:
        return int(SAMPLE_RATE * self.delay_ms / 1000)

    @property
    def attenuation_linear(self) -> float:
        return 10 ** (self.attenuation_db / 20)

    @property
    def reverb_samples(self) -> int:
        return int(SAMPLE_RATE * self.room_reverb_ms / 1000)


def simulate_echo(
    mic_signal: np.ndarray,
    playback_signal: np.ndarray,
    params: EchoParams,
) -> np.ndarray:
    """Simulate acoustic echo: playback leaks into microphone.

    The microphone picks up:
    - The speaker's voice (mic_signal)
    - A delayed, attenuated copy of what the speaker hears (playback_signal)
    - Room reverberation

    Returns: contaminated microphone signal
    """
    delay = params.delay_samples
    atten = params.attenuation_linear

    # Create echo: delayed + attenuated playback
    echo = np.zeros_like(mic_signal)
    if len(playback_signal) > delay:
        echo[delay:] = playback_signal[:-delay] * atten

    # Add simple room reverb (exponential decay)
    reverb_len = params.reverb_samples
    if reverb_len > 0 and len(playback_signal) > delay + reverb_len:
        decay = np.exp(-np.arange(reverb_len) / (reverb_len / 3))
        for i in range(reverb_len):
            if delay + i < len(echo) and i < len(playback_signal):
                echo[delay + i] += playback_signal[i] * atten * decay[i] * 0.3

    # Mix: mic + echo
    contaminated = mic_signal + echo

    # Prevent clipping
    max_val = np.max(np.abs(contaminated))
    if max_val > 0.95:
        contaminated = contaminated / max_val * 0.95

    return contaminated


# ── AEC Simulation (Spektrale Subtraktion) ─────────────────────────────

def aec_spectral_subtraction(
    contaminated: np.ndarray,
    reference: np.ndarray,  # The playback signal (known to AEC)
    frame_size: int = 512,
    hop_size: int = 256,
    suppression_db: float = -12.0,
) -> np.ndarray:
    """Simulate AEC via spectral subtraction.

    Real AEC (Android AudioFX, iOS AVAudioSession) is more sophisticated,
    but this gives a reasonable approximation for testing.

    Algorithm:
    1. STFT of contaminated signal and reference signal
    2. For each frequency bin: subtract reference magnitude from contaminated
    3. Apply suppression floor
    4. ISTFT back to time domain

    Returns: echo-cancelled signal
    """
    from scipy import signal as scipy_signal

    # STFT
    f, t_cont, Zxx_cont = scipy_signal.stft(
        contaminated, fs=SAMPLE_RATE, nperseg=frame_size, noverlap=frame_size - hop_size
    )
    _, _, Zxx_ref = scipy_signal.stft(
        reference, fs=SAMPLE_RATE, nperseg=frame_size, noverlap=frame_size - hop_size
    )

    # Spectral subtraction
    mag_cont = np.abs(Zxx_cont)
    mag_ref = np.abs(Zxx_ref)
    phase_cont = np.angle(Zxx_cont)

    # Subtract reference magnitude with suppression floor
    suppression_linear = 10 ** (suppression_db / 20)
    mag_clean = mag_cont - mag_ref * 0.8  # 80% of reference removed
    mag_clean = np.maximum(mag_clean, mag_cont * suppression_linear)

    # Reconstruct
    Zxx_clean = mag_clean * np.exp(1j * phase_cont)

    # ISTFT
    _, cleaned = scipy_signal.istft(
        Zxx_clean, fs=SAMPLE_RATE, nperseg=frame_size, noverlap=frame_size - hop_size
    )

    # Match original length
    if len(cleaned) > len(contaminated):
        cleaned = cleaned[:len(contaminated)]
    elif len(cleaned) < len(contaminated):
        cleaned = np.pad(cleaned, (0, len(contaminated) - len(cleaned)))

    return cleaned


# ── Echo Metrics ────────────────────────────────────────────────────────

@dataclass
class EchoMetrics:
    """Echo measurement results."""
    scenario: str
    echo_present: bool
    echo_energy_db: float       # Energy of echo relative to signal
    signal_to_echo_db: float    # How much louder signal is than echo
    feedback_loop: bool         # Did feedback loop occur?
    aec_reduction_db: float     # How much AEC reduced echo
    latency_ms: float           # Processing latency
    passed: bool

    def to_dict(self) -> dict:
        return {
            "scenario": self.scenario,
            "echo_present": bool(self.echo_present),
            "echo_energy_db": round(self.echo_energy_db, 1),
            "signal_to_echo_db": round(self.signal_to_echo_db, 1),
            "feedback_loop": bool(self.feedback_loop),
            "aec_reduction_db": round(self.aec_reduction_db, 1),
            "latency_ms": round(self.latency_ms, 1),
            "passed": bool(self.passed),
        }


def measure_echo(
    original: np.ndarray,
    processed: np.ndarray,
    reference: np.ndarray,
    scenario: str,
    aec_enabled: bool,
) -> EchoMetrics:
    """Measure echo in processed signal compared to original."""
    # Ensure same length
    min_len = min(len(original), len(processed), len(reference))
    original = original[:min_len]
    processed = processed[:min_len]
    reference = reference[:min_len]

    # Signal energy
    signal_energy = np.mean(original ** 2) + 1e-10

    # Echo energy (difference between processed and original)
    echo_signal = processed - original
    echo_energy = np.mean(echo_signal ** 2)

    # Reference energy (playback)
    ref_energy = np.mean(reference ** 2) + 1e-10

    # Metrics
    echo_energy_db = 10 * np.log10(echo_energy / signal_energy + 1e-10)
    signal_to_echo_db = 10 * np.log10(signal_energy / echo_energy + 1e-10)

    # Echo present if echo energy > -40 dB relative to signal
    echo_present = echo_energy_db > -40

    # AEC reduction: compare echo energy with/without AEC
    # (simplified: if AEC enabled, echo should be lower)
    aec_reduction_db = 0.0
    if aec_enabled:
        # Estimate: how much quieter is echo compared to reference?
        aec_reduction_db = 10 * np.log10(ref_energy / echo_energy + 1e-10)

    # Feedback loop detection: if echo energy grows over time
    feedback_loop = False
    if len(echo_signal) > SAMPLE_RATE:
        # Split into 1-second chunks
        chunk_size = SAMPLE_RATE
        chunks = [
            echo_signal[i:i + chunk_size]
            for i in range(0, len(echo_signal) - chunk_size, chunk_size)
        ]
        if len(chunks) >= 3:
            energies = [np.mean(c ** 2) for c in chunks]
            # Feedback loop: energy increases over time
            if energies[-1] > energies[0] * 2.0:
                feedback_loop = True

    # Pass criteria
    passed = not echo_present or (aec_enabled and aec_reduction_db > 6.0)

    return EchoMetrics(
        scenario=scenario,
        echo_present=echo_present,
        echo_energy_db=echo_energy_db,
        signal_to_echo_db=signal_to_echo_db,
        feedback_loop=feedback_loop,
        aec_reduction_db=aec_reduction_db,
        latency_ms=0.0,  # Simulated, no real latency
        passed=passed,
    )


# ── Test Runner ─────────────────────────────────────────────────────────

def run_scenario(
    scenario_id: str,
    input_audio: np.ndarray,
    aec_enabled: bool,
    echo_params: EchoParams,
    bt_headset: bool = False,
    dual_device: bool = False,
) -> EchoMetrics:
    """Run a single AEC test scenario."""
    print(f"\n{'='*60}")
    print(f"  Szenario {scenario_id}")
    print(f"  AEC: {'ON' if aec_enabled else 'OFF'}")
    print(f"  BT-Headset: {'Ja' if bt_headset else 'Nein'}")
    print(f"  Dual-Device: {'Ja' if dual_device else 'Nein'}")
    print(f"  Echo-Delay: {echo_params.delay_ms}ms")
    print(f"  Echo-Dämpfung: {echo_params.attenuation_db}dB")
    print(f"{'='*60}")

    # Simulate: input_audio is what the speaker says
    # We need a "playback" signal — what the other person said (simulated as reversed input)
    playback = input_audio[::-1]  # Reversed audio as simulated "other person"

    # BT headset: less echo (closer to mouth, less acoustic coupling)
    if bt_headset:
        echo_params.attenuation_db -= 10  # 10 dB more attenuation
        echo_params.delay_ms *= 0.5       # Half the delay

    # Simulate echo
    contaminated = simulate_echo(input_audio, playback, echo_params)

    # Apply AEC if enabled
    t0 = time.perf_counter()
    if aec_enabled:
        cleaned = aec_spectral_subtraction(contaminated, playback)
    else:
        cleaned = contaminated
    latency = (time.perf_counter() - t0) * 1000

    # Dual device: simulate feedback loop (output feeds back into input)
    if dual_device:
        # Recursive feedback: cleaned output becomes new echo source
        feedback = simulate_echo(cleaned, cleaned * echo_params.feedback_gain, echo_params)
        cleaned = feedback

    # Measure
    metrics = measure_echo(input_audio, cleaned, playback, scenario_id, aec_enabled)
    metrics.latency_ms = latency

    # Print results
    print(f"\n  📊 Ergebnisse:")
    print(f"     Echo erkannt:        {'❌ JA' if metrics.echo_present else '✅ NEIN'}")
    print(f"     Echo-Energie:        {metrics.echo_energy_db:+.1f} dB")
    print(f"     Signal-zu-Echo:      {metrics.signal_to_echo_db:.1f} dB")
    print(f"     AEC-Reduktion:       {metrics.aec_reduction_db:.1f} dB")
    print(f"     Feedback-Loop:       {'❌ JA' if metrics.feedback_loop else '✅ NEIN'}")
    print(f"     Latenz:              {metrics.latency_ms:.1f} ms")
    print(f"     Bestanden:           {'✅ JA' if metrics.passed else '❌ NEIN'}")

    return metrics


# ── Main ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="M1 AEC Test — Echo Cancellation Simulation"
    )
    parser.add_argument(
        "--input",
        default="audio_samples/S1.wav",
        help="Input WAV file (default: audio_samples/S1.wav)",
    )
    parser.add_argument(
        "--scenario",
        choices=["E1", "E2", "E3", "E4", "E5", "all"],
        default="all",
        help="Test scenario (default: all)",
    )
    parser.add_argument(
        "--output",
        default="output/aec_results.json",
        help="Output JSON for results",
    )
    args = parser.parse_args()

    # Load audio
    input_path = Path(args.input)
    if not input_path.exists():
        print(f"❌ Input file not found: {input_path}")
        sys.exit(1)

    audio, sr = load_wav(str(input_path))
    print(f"📂 Geladen: {input_path} ({len(audio)/sr:.1f}s, {sr}Hz)")

    # Scenario definitions
    scenarios = {
        "E1": {
            "aec": False,
            "bt": False,
            "dual": False,
            "echo": EchoParams(delay_ms=50, attenuation_db=-20),
            "desc": "AEC off, Lautsprecher (Baseline)",
        },
        "E2": {
            "aec": True,
            "bt": False,
            "dual": False,
            "echo": EchoParams(delay_ms=50, attenuation_db=-20),
            "desc": "AEC on (Android AudioFX), Lautsprecher",
        },
        "E3": {
            "aec": True,
            "bt": False,
            "dual": False,
            "echo": EchoParams(delay_ms=40, attenuation_db=-18),
            "desc": "AEC on (iOS AVAudioSession), Lautsprecher",
        },
        "E4": {
            "aec": True,
            "bt": True,
            "dual": False,
            "echo": EchoParams(delay_ms=25, attenuation_db=-30),
            "desc": "AEC + BT-Headset, Lautsprecher",
        },
        "E5": {
            "aec": True,
            "bt": True,
            "dual": True,
            "echo": EchoParams(delay_ms=25, attenuation_db=-30, feedback_gain=0.3),
            "desc": "AEC + BT-Headset (beide Geräte) — Feedback-Loop-Test",
        },
    }

    # Run scenarios
    to_run = [args.scenario] if args.scenario != "all" else list(scenarios.keys())
    results: list[EchoMetrics] = []

    for sid in to_run:
        cfg = scenarios[sid]
        metrics = run_scenario(
            scenario_id=sid,
            input_audio=audio,
            aec_enabled=cfg["aec"],
            echo_params=cfg["echo"],
            bt_headset=cfg["bt"],
            dual_device=cfg["dual"],
        )
        results.append(metrics)

    # Summary
    print(f"\n{'='*60}")
    print(f"  📋 ZUSAMMENFASSUNG")
    print(f"{'='*60}")

    all_passed = all(r.passed for r in results)
    for r in results:
        status = "✅" if r.passed else "❌"
        print(f"  {status} {r.scenario}: Echo={'JA' if r.echo_present else 'NEIN'}, "
              f"Feedback={'JA' if r.feedback_loop else 'NEIN'}, "
              f"AEC-Red={r.aec_reduction_db:.1f}dB")

    print(f"\n  Gesamt: {'✅ ALLE BESTANDEN' if all_passed else '❌ NICHT BESTANDEN'}")

    # Go/No-Go decision
    e5 = next((r for r in results if r.scenario == "E5"), None)
    if e5 and not e5.feedback_loop:
        print(f"\n  🟢 GO → M2 (Streaming) oder M3 (Backend)")
    elif e5 and e5.feedback_loop:
        print(f"\n  🔴 NO-GO → Alternativen prüfen:")
        print(f"     - Halb-Duplex-Modus (Playback pausiert Mikrofon)")
        print(f"     - Externes AEC-Modul (RNNoise + AEC)")
        print(f"     - Andere BT-Headsets (LE Audio)")
    else:
        print(f"\n  ⚠️  E5 nicht getestet — Hardware-Test erforderlich")

    # Save results
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(
            {
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "input_file": str(input_path),
                "sample_rate": sr,
                "duration_s": len(audio) / sr,
                "results": [r.to_dict() for r in results],
                "all_passed": all_passed,
                "go_nogo": "GO" if (e5 and not e5.feedback_loop) else "NO_GO" if e5 else "UNTESTED",
            },
            f,
            indent=2,
        )
    print(f"\n💾 Ergebnisse gespeichert: {output_path}")


if __name__ == "__main__":
    main()
