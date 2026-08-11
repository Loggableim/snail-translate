"""GPT-Realtime-Translate Client — Speech-to-Speech via WebSocket.

Endpoint: wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate
Pricing: $0.034/min audio
Input: 24kHz PCM16, base64-encoded
Output: response.text.delta (transcript), response.audio.delta (translated audio)
"""

import asyncio
import base64
import json
import os
import time
import wave
from dataclasses import dataclass, field
from pathlib import Path

import websockets


@dataclass
class RealtimeTranslateResult:
    """Result of a realtime translation session."""
    input_file: str
    source_lang: str
    target_lang: str
    transcript: str = ""
    translation: str = ""
    audio_chunks: list[bytes] = field(default_factory=list)
    ttfa_ms: float = 0.0  # Time to first audio
    ttf_text_ms: float = 0.0  # Time to first text
    total_time_ms: float = 0.0
    error: str | None = None


async def translate_realtime(
    audio_path: str,
    api_key: str,
    source_lang: str = "de",
    target_lang: str = "en",
    timeout: float = 30.0,
) -> RealtimeTranslateResult:
    """Stream audio to GPT-Realtime-Translate and collect results.

    Args:
        audio_path: Path to WAV file (will be resampled to 24kHz if needed).
        api_key: OpenAI API key.
        source_lang: Source language code (e.g. "de").
        target_lang: Target language code (e.g. "en").
        timeout: Max seconds to wait for response.

    Returns:
        RealtimeTranslateResult with transcript, translation, audio, and timing.
    """
    result = RealtimeTranslateResult(
        input_file=Path(audio_path).name,
        source_lang=source_lang,
        target_lang=target_lang,
    )

    # Read and resample audio to 24kHz PCM16 mono
    with wave.open(audio_path, "rb") as wf:
        assert wf.getnchannels() == 1, "Mono only"
        assert wf.getsampwidth() == 2, "16-bit only"
        in_rate = wf.getframerate()
        pcm = wf.readframes(wf.getnframes())

    # Resample to 24kHz if needed
    if in_rate != 24000:
        import numpy as np
        samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        new_len = int(len(samples) * 24000 / in_rate)
        resampled = np.interp(
            np.linspace(0, len(samples) - 1, new_len),
            np.arange(len(samples)),
            samples,
        )
        pcm = (resampled * 32767).astype(np.int16).tobytes()

    # Split into 100ms chunks (2400 samples = 4800 bytes at 24kHz 16-bit)
    CHUNK_SAMPLES = 2400
    CHUNK_BYTES = CHUNK_SAMPLES * 2
    chunks = [pcm[i:i + CHUNK_BYTES] for i in range(0, len(pcm), CHUNK_BYTES)]

    url = "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate"
    headers = {
        "Authorization": f"Bearer {api_key}",
        # The dedicated translation endpoint no longer accepts the legacy
        # OpenAI-Beta realtime header.
        "OpenAI-Safety-Identifier": "snail-development-test",
    }

    t_start = time.monotonic()
    first_text = True
    first_audio = True

    try:
        async with websockets.connect(url, additional_headers=headers, open_timeout=10) as ws:
            # Configure session
            await ws.send(json.dumps({
                "type": "session.update",
                "session": {
                    "audio": {
                        "output": {"language": target_lang},
                    },
                },
            }))

            # Wait for session.updated
            async for raw in ws:
                evt = json.loads(raw)
                if evt.get("type") == "session.updated":
                    break

            # Send audio chunks
            for chunk in chunks:
                b64 = base64.b64encode(chunk).decode("ascii")
                await ws.send(json.dumps({
                    "type": "session.input_audio_buffer.append",
                    "audio": b64,
                }))
                await asyncio.sleep(0.02)  # Simulate real-time pacing

            # Close the translation input gracefully. This flushes pending
            # audio and lets the server emit the remaining output chunks.
            await ws.send(json.dumps({"type": "session.close"}))

            # Receive results
            async for raw in ws:
                evt = json.loads(raw)
                etype = evt.get("type", "")

                if etype == "session.output_transcript.delta":
                    text = evt.get("delta", "")
                    if first_text:
                        result.ttf_text_ms = (time.monotonic() - t_start) * 1000
                        first_text = False
                    result.translation += text

                elif etype == "session.output_audio.delta":
                    audio_b64 = evt.get("delta", "")
                    if audio_b64:
                        if first_audio:
                            result.ttfa_ms = (time.monotonic() - t_start) * 1000
                            first_audio = False
                        result.audio_chunks.append(base64.b64decode(audio_b64))

                elif etype == "session.input_transcript.delta":
                    result.transcript += evt.get("delta", "")

                elif etype == "session.closed":
                    break  # Translation session drained completely

                elif etype == "error":
                    result.error = json.dumps(evt.get("error", {}))
                    break

    except Exception as e:
        result.error = str(e)

    result.total_time_ms = (time.monotonic() - t_start) * 1000
    return result


# ── Benchmark ──────────────────────────────────────────────────────────

async def benchmark(samples_dir: str, api_key: str, n_runs: int = 3):
    """Run benchmark across all samples."""
    samples = sorted(Path(samples_dir).glob("S*.wav"))[:5]  # First 5 for speed
    results = []

    for wav in samples:
        for run in range(n_runs):
            print(f"  {wav.name} run {run+1}...", end=" ", flush=True)
            r = await translate_realtime(str(wav), api_key, "de", "en")
            if r.error:
                print(f"ERROR: {r.error[:80]}")
            else:
                print(f"TTFA={r.ttfa_ms:.0f}ms, Text={r.translation[:50]}")
            results.append(r)
            await asyncio.sleep(0.5)

    # Stats
    ttfas = [r.ttfa_ms for r in results if r.ttfa_ms > 0]
    if ttfas:
        ttfas.sort()
        n = len(ttfas)
        print(f"\n📊 GPT-Realtime-Translate Benchmark ({n} runs)")
        print(f"   P50 TTFA: {ttfas[n//2]:.0f}ms")
        print(f"   P95 TTFA: {ttfas[int(n*0.95)]:.0f}ms" if n >= 20 else f"   Max TTFA: {ttfas[-1]:.0f}ms")
        print(f"   Mean TTFA: {sum(ttfas)/n:.0f}ms")
        print(f"   Min TTFA: {ttfas[0]:.0f}ms")

    errors = [r for r in results if r.error]
    if errors:
        print(f"   Errors: {len(errors)}/{len(results)}")

    return results


if __name__ == "__main__":
    api_key = os.environ.get("SNAIL_OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY")
    if not api_key:
        print("Set SNAIL_OPENAI_API_KEY or OPENAI_API_KEY")
        exit(1)

    asyncio.run(benchmark("audio_samples", api_key))
