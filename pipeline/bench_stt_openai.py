"""Benchmark: OpenAI Whisper vs Groq Whisper STT latency."""
import os, sys, time, json, statistics
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
from pipeline.stt import transcribe_groq, transcribe_openai, STTResult
from pipeline.config import groq_api_key, openai_api_key

SAMPLES_DIR = Path("audio_samples")
SAMPLES = sorted(SAMPLES_DIR.glob("S*.wav"))[:10]
RUNS_PER_SAMPLE = 3  # 3 runs each for P50/P95

def run_benchmark(name: str, fn, api_key: str) -> list[dict]:
    results = []
    for wav in SAMPLES:
        for run in range(RUNS_PER_SAMPLE):
            try:
                r: STTResult = fn(str(wav), api_key, "de")
                results.append({
                    "sample": wav.name,
                    "run": run + 1,
                    "api": name,
                    "latency_ms": round(r.latency_ms, 1),
                    "transcript": r.transcript[:80],
                })
                print(f"  {name} {wav.name} run {run+1}: {r.latency_ms:.0f}ms — {r.transcript[:60]}")
            except Exception as e:
                print(f"  {name} {wav.name} run {run+1}: ERROR — {e}")
            time.sleep(0.3)  # rate limit
    return results

def stats(results: list[dict]) -> dict:
    lats = sorted(r["latency_ms"] for r in results)
    n = len(lats)
    return {
        "count": n,
        "min": round(min(lats), 1),
        "max": round(max(lats), 1),
        "mean": round(statistics.mean(lats), 1),
        "p50": round(lats[n // 2], 1),
        "p95": round(lats[int(n * 0.95)], 1) if n >= 20 else round(lats[-1], 1),
    }

def main():
    groq_key = groq_api_key()
    openai_key = openai_api_key()

    if not groq_key:
        print("❌ SNAIL_GROQ_API_KEY not set")
        return
    if not openai_key:
        print("❌ SNAIL_OPENAI_API_KEY not set")
        return

    print(f"🔬 STT Benchmark: OpenAI Whisper vs Groq Whisper")
    print(f"   Samples: {len(SAMPLES)} × {RUNS_PER_SAMPLE} runs = {len(SAMPLES) * RUNS_PER_SAMPLE} each")
    print()

    # Groq
    print("── Groq Whisper ──")
    groq_results = run_benchmark("groq", transcribe_groq, groq_key)
    print()

    # OpenAI
    print("── OpenAI Whisper ──")
    openai_results = run_benchmark("openai", transcribe_openai, openai_key)
    print()

    # Stats
    groq_s = stats(groq_results)
    openai_s = stats(openai_results)

    print("=" * 60)
    print("📊 RESULTS")
    print("=" * 60)
    print(f"{'Metric':<10} {'Groq':>10} {'OpenAI':>10} {'Delta':>10}")
    print("-" * 40)
    for m in ["count", "min", "max", "mean", "p50", "p95"]:
        g = groq_s[m]
        o = openai_s[m]
        d = round(o - g, 1) if isinstance(g, (int, float)) else "—"
        print(f"{m:<10} {str(g)+'ms':>10} {str(o)+'ms':>10} {str(d)+'ms':>10}")

    winner = "Groq" if groq_s["p50"] < openai_s["p50"] else "OpenAI"
    print(f"\n🏆 Faster P50: {winner}")
    print(f"   Groq P50={groq_s['p50']}ms, OpenAI P50={openai_s['p50']}ms")

    # Save
    out = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "samples": len(SAMPLES),
        "runs_per_sample": RUNS_PER_SAMPLE,
        "groq": groq_s,
        "openai": openai_s,
        "groq_raw": groq_results,
        "openai_raw": openai_results,
    }
    Path("output").mkdir(exist_ok=True)
    with open("output/stt_benchmark_openai_vs_groq.json", "w") as f:
        json.dump(out, f, indent=2)
    print(f"\n💾 Saved: output/stt_benchmark_openai_vs_groq.json")

if __name__ == "__main__":
    main()
