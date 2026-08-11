"""Benchmark-Runner: Automatisierte Pipeline-Durchläufe mit Statistik.

Führt Pipeline für alle Audio-Samples (S1–S10) durch, pro Tier,
mit n Wiederholungen. Speichert Ergebnisse als JSON in output/.
Berechnet P50, P95, Mean, Min, Max pro Sample und Tier.
"""

import json
import statistics
import time
from pathlib import Path

from pipeline.pipeline import run_pipeline, PipelineResult
from pipeline.config import validate_keys_for_tier

# Groq Free-Tier: 30 req/min → 2s Pause zwischen Calls
GROQ_RATE_LIMIT_DELAY = 2.0  # Sekunden


def run_benchmarks(
    audio_dir: str = "audio_samples/",
    output_dir: str = "output/",
    references_path: str = "pipeline/references.json",
    tiers: list[str] | None = None,
    runs_per_sample: int = 10,
    rate_limit_delay: float = GROQ_RATE_LIMIT_DELAY,
) -> list[PipelineResult]:
    """Führt Pipeline für alle Audio-Samples durch.

    Args:
        audio_dir: Verzeichnis mit WAV-Dateien (S1.wav, S2.wav, ...).
        output_dir: Verzeichnis für JSON-Ergebnisse.
        references_path: Pfad zu references.json.
        tiers: Liste der Tiers (default: ["free", "paid"]).
        runs_per_sample: Anzahl Wiederholungen pro Sample.
        rate_limit_delay: Pause zwischen Groq-Calls (Sekunden).

    Returns:
        Liste aller PipelineResult-Objekte.
    """
    if tiers is None:
        tiers = ["free", "paid"]

    # Keys validieren — fehlende Tiers überspringen
    valid_tiers = []
    for tier in tiers:
        missing = validate_keys_for_tier(tier)
        if missing:
            print(f"⚠️  Tier '{tier}': fehlende Keys: {missing}")
            print(f"   Überspringe Tier '{tier}'")
        else:
            valid_tiers.append(tier)

    if not valid_tiers:
        print("❌ Keine gültigen Tiers — breche ab.")
        return []

    # Referenz-Transkripte laden
    refs_path = Path(references_path)
    if refs_path.exists():
        references = json.loads(refs_path.read_text(encoding="utf-8"))
    else:
        references = {}

    # Audio-Samples finden
    audio_path = Path(audio_dir)
    wav_files = sorted(audio_path.glob("S*.wav"))
    if not wav_files:
        print(f"❌ Keine WAV-Dateien in {audio_dir} gefunden.")
        return []

    out_path = Path(output_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    results: list[PipelineResult] = []
    total_runs = len(valid_tiers) * len(wav_files) * runs_per_sample
    run_count = 0

    print(f"🚀 Starte Benchmark: {len(valid_tiers)} Tiers × "
          f"{len(wav_files)} Samples × {runs_per_sample} Runs = {total_runs} Durchläufe")
    print(f"   Tiers: {valid_tiers}")
    print(f"   Output: {out_path.absolute()}")
    print()

    for tier in valid_tiers:
        print(f"── Tier: {tier} ──")
        for sample_file in wav_files:
            sample_id = sample_file.stem  # "S1", "S2", ...
            ref = references.get(sample_id)
            print(f"  Sample {sample_id} ({sample_file.name})")

            for run in range(runs_per_sample):
                run_count += 1
                try:
                    result = run_pipeline(
                        audio_path=str(sample_file),
                        tier=tier,
                        reference_transcript=ref,
                    )
                    results.append(result)

                    # JSON speichern
                    run_file = out_path / f"{sample_id}_{tier}_run{run:02d}.json"
                    run_file.write_text(result.to_json(), encoding="utf-8")

                    print(f"    Run {run:02d}: t_total={result.t_total:.0f}ms, "
                          f"WER={result.wer:.3f}" if result.wer is not None else
                          f"    Run {run:02d}: t_total={result.t_total:.0f}ms")

                except Exception as e:
                    print(f"    Run {run:02d}: ❌ Fehler: {e}")

                # Rate-Limit für Groq (Free-Tier)
                if tier == "free":
                    time.sleep(rate_limit_delay)

                # Fortschritt
                if run_count % 10 == 0:
                    print(f"    ... {run_count}/{total_runs} Durchläufe")

    print(f"\n✅ Benchmark abgeschlossen: {len(results)}/{total_runs} erfolgreich")
    return results


def compute_stats(results: list[PipelineResult]) -> dict:
    """Berechnet P50, P95, Mean, Min, Max pro Sample und Tier.

    Args:
        results: Liste aller PipelineResult-Objekte.

    Returns:
        Dictionary mit Statistiken.
    """
    if not results:
        return {}

    # Gruppiere nach (tier, sample_id)
    groups: dict[tuple[str, str], list[PipelineResult]] = {}
    for r in results:
        sample_id = Path(r.input_file).stem
        key = (r.tier, sample_id)
        groups.setdefault(key, []).append(r)

    stats = {}
    for (tier, sample_id), group in sorted(groups.items()):
        latencies = [r.t_total for r in group]
        wers = [r.wer for r in group if r.wer is not None]

        stats[f"{sample_id}_{tier}"] = {
            "sample": sample_id,
            "tier": tier,
            "runs": len(latencies),
            "t_total": {
                "p50": statistics.median(latencies),
                "p95": _percentile(latencies, 95),
                "mean": statistics.mean(latencies),
                "min": min(latencies),
                "max": max(latencies),
            },
            "t_stt": {
                "p50": statistics.median([r.t_stt for r in group]),
                "mean": statistics.mean([r.t_stt for r in group]),
            },
            "t_mt": {
                "p50": statistics.median([r.t_mt for r in group]),
                "mean": statistics.mean([r.t_mt for r in group]),
            },
            "t_tts": {
                "p50": statistics.median([r.t_tts for r in group]),
                "mean": statistics.mean([r.t_tts for r in group]),
            },
            "wer": {
                "mean": statistics.mean(wers) if wers else None,
                "min": min(wers) if wers else None,
                "max": max(wers) if wers else None,
            },
        }

    # Gesamt-Statistik pro Tier
    for tier in ["free", "paid"]:
        tier_results = [r for r in results if r.tier == tier]
        if not tier_results:
            continue
        latencies = [r.t_total for r in tier_results]
        wers = [r.wer for r in tier_results if r.wer is not None]
        stats[f"__total_{tier}__"] = {
            "sample": "ALL",
            "tier": tier,
            "runs": len(latencies),
            "t_total": {
                "p50": statistics.median(latencies),
                "p95": _percentile(latencies, 95),
                "mean": statistics.mean(latencies),
                "min": min(latencies),
                "max": max(latencies),
            },
            "wer": {
                "mean": statistics.mean(wers) if wers else None,
            },
        }

    return stats


def _percentile(data: list[float], p: int) -> float:
    """Berechnet das p-te Perzentil (lineare Interpolation)."""
    if not data:
        return 0.0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * p / 100.0
    f = int(k)
    c = k - f
    if f + 1 < len(sorted_data):
        return sorted_data[f] + c * (sorted_data[f + 1] - sorted_data[f])
    return sorted_data[f]


def print_summary(stats: dict):
    """Gibt Zusammenfassung als Tabelle aus."""
    if not stats:
        print("Keine Daten.")
        return

    print("\n" + "=" * 80)
    print("BENCHMARK-ZUSAMMENFASSUNG")
    print("=" * 80)

    # Pro Sample
    print(f"\n{'Sample':<12} {'Tier':<6} {'Runs':<6} {'P50(ms)':<10} {'P95(ms)':<10} "
          f"{'Mean(ms)':<10} {'WER':<8}")
    print("-" * 70)

    for key, s in sorted(stats.items()):
        if key.startswith("__total"):
            continue
        wer_str = f"{s['wer']['mean']:.3f}" if s['wer']['mean'] is not None else "N/A"
        print(f"{s['sample']:<12} {s['tier']:<6} {s['runs']:<6} "
              f"{s['t_total']['p50']:<10.0f} {s['t_total']['p95']:<10.0f} "
              f"{s['t_total']['mean']:<10.0f} {wer_str:<8}")

    # Gesamt pro Tier
    print("\n── Gesamt pro Tier ──")
    print(f"{'Tier':<6} {'Runs':<6} {'P50(ms)':<10} {'P95(ms)':<10} "
          f"{'Mean(ms)':<10} {'WER':<8}")
    print("-" * 50)

    for key, s in sorted(stats.items()):
        if not key.startswith("__total"):
            continue
        wer_str = f"{s['wer']['mean']:.3f}" if s['wer']['mean'] is not None else "N/A"
        print(f"{s['tier']:<6} {s['runs']:<6} "
              f"{s['t_total']['p50']:<10.0f} {s['t_total']['p95']:<10.0f} "
              f"{s['t_total']['mean']:<10.0f} {wer_str:<8}")

    # Entscheidungs-Matrix
    print("\n── Entscheidungs-Matrix ──")
    for key, s in sorted(stats.items()):
        if not key.startswith("__total"):
            continue
        p50 = s["t_total"]["p50"]
        p95 = s["t_total"]["p95"]
        tier = s["tier"]

        if p50 < 2000 and p95 < 4000:
            status = "✅ GO"
        elif p50 < 2000 and p95 >= 4000:
            status = "⚠️  Ausreißer analysieren"
        elif p50 < 3000:
            status = "⚠️  Bottleneck identifizieren"
        else:
            status = "❌ NO-GO"

        print(f"  {tier}: P50={p50:.0f}ms, P95={p95:.0f}ms → {status}")

    print("=" * 80)


# ── CLI-Einstieg ──────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Snail Pipeline Benchmark — Automatisierte Durchläufe"
    )
    parser.add_argument(
        "--audio-dir",
        default="audio_samples/",
        help="Verzeichnis mit WAV-Dateien (default: audio_samples/)",
    )
    parser.add_argument(
        "--output-dir",
        default="output/",
        help="Verzeichnis für JSON-Ergebnisse (default: output/)",
    )
    parser.add_argument(
        "--references",
        default="pipeline/references.json",
        help="Pfad zu references.json",
    )
    parser.add_argument(
        "--tiers",
        nargs="+",
        default=["free", "paid"],
        help="Tiers (default: free paid)",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=10,
        help="Wiederholungen pro Sample (default: 10)",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=GROQ_RATE_LIMIT_DELAY,
        help="Pause zwischen Groq-Calls in Sekunden (default: 2.0)",
    )

    args = parser.parse_args()

    results = run_benchmarks(
        audio_dir=args.audio_dir,
        output_dir=args.output_dir,
        references_path=args.references,
        tiers=args.tiers,
        runs_per_sample=args.runs,
        rate_limit_delay=args.delay,
    )

    stats = compute_stats(results)
    print_summary(stats)

    # Stats als JSON speichern
    stats_path = Path(args.output_dir) / "benchmark_summary.json"
    stats_path.write_text(
        json.dumps(stats, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(f"\n📊 Zusammenfassung gespeichert: {stats_path.absolute()}")
