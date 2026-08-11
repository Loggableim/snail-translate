"""Relay-Client: Python-Client für WebSocket-Verbindung zum Durable Object.

Sendet Audio-Chunks und empfängt übersetzte Audio-Chunks.
Simuliert die Flutter-App auf PC für End-to-End-Tests.

Nutzung:
    python -m pipeline.relay_client --room snail-4821 --token <session-token> --role host
"""

import asyncio
import json
import time
import wave
import io
import sys
from pathlib import Path

import numpy as np

# WebSocket library (install: pip install websockets)
try:
    import websockets
except ImportError:
    print("⚠️  websockets not installed. Run: pip install websockets")
    sys.exit(1)

from pipeline.audio_io import load_wav, encode_wav, mp3_to_pcm, play_audio
from pipeline.vad import detect_speech, remove_silence
from pipeline.config import SAMPLE_RATE

# ── Types ──────────────────────────────────────────────────────────────

class RelayClient:
    """WebSocket client for Snail Relay (Durable Object)."""

    def __init__(
        self,
        relay_url: str,
        session_token: str,
        role: str = "host",
        source_lang: str = "de",
        target_lang: str = "en",
    ):
        self.relay_url = relay_url
        self.session_token = session_token
        self.role = role
        self.source_lang = source_lang
        self.target_lang = target_lang
        self.ws = None
        self.authenticated = False
        self.peer_connected = False
        self.received_audio: list[bytes] = []
        self.running = False

    async def connect(self) -> bool:
        """Connect to relay and authenticate."""
        try:
            self.ws = await websockets.connect(
                self.relay_url,
                ping_interval=30,
                ping_timeout=10,
                close_timeout=5,
            )
        except Exception as e:
            print(f"❌ Connection failed: {e}")
            return False

        # Send auth
        await self.ws.send(json.dumps({
            "type": "auth",
            "token": self.session_token,
        }))

        # Wait for auth response
        response = await self.ws.recv()
        msg = json.loads(response)

        if msg.get("type") == "auth_ok":
            self.authenticated = True
            print(f"✅ Authenticated as {self.role}")
            return True
        else:
            print(f"❌ Auth failed: {msg.get('error', 'unknown')}")
            return False

    async def send_audio(self, audio: np.ndarray) -> None:
        """Send audio chunk to relay."""
        if not self.authenticated or not self.ws:
            return

        # Encode as WAV bytes
        wav_bytes = encode_wav(audio, SAMPLE_RATE)

        # Send as audio message
        await self.ws.send(json.dumps({
            "type": "audio",
            "audio": list(wav_bytes),
            "timestamp": time.time(),
        }))

    async def send_audio_file(self, wav_path: str, chunk_duration: float = 0.5) -> None:
        """Send a WAV file in chunks (simulating live microphone)."""
        audio, sr = load_wav(wav_path)

        # VAD: only send speech segments
        segments = detect_speech(audio, sr)
        speech = remove_silence(audio, segments)

        if len(speech) == 0:
            print("⚠️  No speech detected")
            return

        # Split into chunks
        chunk_size = int(SAMPLE_RATE * chunk_duration)
        total_chunks = (len(speech) + chunk_size - 1) // chunk_size

        print(f"📤 Sending {total_chunks} chunks ({len(speech)/SAMPLE_RATE:.1f}s audio)")

        for i in range(0, len(speech), chunk_size):
            chunk = speech[i : i + chunk_size]
            await self.send_audio(chunk)
            await asyncio.sleep(chunk_duration)  # Simulate real-time

        print("✅ Audio sent")

    async def receive_loop(self) -> None:
        """Receive messages from relay."""
        if not self.ws:
            return

        self.running = True
        try:
            async for message in self.ws:
                msg = json.loads(message)
                msg_type = msg.get("type")

                if msg_type == "audio":
                    # Received translated audio
                    audio_data = bytes(msg.get("audio", []))
                    if audio_data:
                        self.received_audio.append(audio_data)
                        print(f"  🔊 Received audio: {len(audio_data)} bytes")

                elif msg_type == "peer_joined":
                    self.peer_connected = True
                    print(f"👤 Peer joined: {msg.get('peerId')}")

                elif msg_type == "peer_left":
                    self.peer_connected = False
                    print(f"👋 Peer left: {msg.get('peerId')}")

                elif msg_type == "session_end":
                    print(f"🛑 Session ended: {msg.get('reason')}")
                    self.running = False
                    break

                elif msg_type == "error":
                    print(f"⚠️  Error: {msg.get('error')}")

                elif msg_type == "ping":
                    pass  # Keep-alive

        except websockets.exceptions.ConnectionClosed:
            print("🔌 Connection closed")
        finally:
            self.running = False

    async def wait_for_peer(self, timeout: float = 30.0) -> bool:
        """Wait for peer to connect."""
        start = time.time()
        while time.time() - start < timeout:
            if self.peer_connected:
                return True
            await asyncio.sleep(0.5)
        return False

    async def close(self) -> None:
        """Close connection."""
        self.running = False
        if self.ws:
            try:
                await self.ws.send(json.dumps({"type": "end"}))
                await self.ws.close()
            except Exception:
                pass

    def save_received_audio(self, output_path: str) -> None:
        """Save all received audio chunks to a WAV file."""
        if not self.received_audio:
            print("⚠️  No audio received")
            return

        # Decode all MP3 chunks and concatenate
        all_pcm = []
        for mp3_bytes in self.received_audio:
            try:
                pcm = mp3_to_pcm(mp3_bytes)
                all_pcm.append(pcm)
            except Exception as e:
                print(f"⚠️  Failed to decode chunk: {e}")

        if not all_pcm:
            return

        combined = np.concatenate(all_pcm)

        # Write WAV
        import soundfile as sf
        sf.write(output_path, combined, SAMPLE_RATE)
        print(f"💾 Saved {len(combined)/SAMPLE_RATE:.1f}s audio to {output_path}")

    def play_received_audio(self) -> None:
        """Play all received audio."""
        if not self.received_audio:
            print("⚠️  No audio received")
            return

        all_pcm = []
        for mp3_bytes in self.received_audio:
            try:
                pcm = mp3_to_pcm(mp3_bytes)
                all_pcm.append(pcm)
            except Exception:
                pass

        if all_pcm:
            combined = np.concatenate(all_pcm)
            print(f"🔊 Playing {len(combined)/SAMPLE_RATE:.1f}s audio...")
            play_audio(combined, SAMPLE_RATE)


# ── CLI ────────────────────────────────────────────────────────────────

async def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Snail Relay Client — WebSocket to Durable Object"
    )
    parser.add_argument(
        "--url",
        default="wss://snail-worker.pixstash.workers.dev/ws",
        help="Relay WebSocket URL (default: wss://snail-worker.pixstash.workers.dev/ws)",
    )
    parser.add_argument(
        "--room", required=True, help="Room ID (e.g., snail-4821)"
    )
    parser.add_argument(
        "--token", required=True, help="Session token from Worker"
    )
    parser.add_argument(
        "--role", choices=["host", "guest"], default="host", help="Role"
    )
    parser.add_argument(
        "--input", help="WAV file to send (optional)"
    )
    parser.add_argument(
        "--output", default="output/received.wav", help="Output WAV file for received audio"
    )
    parser.add_argument(
        "--play", action="store_true", help="Play received audio"
    )

    args = parser.parse_args()

    # Build relay URL with room parameter
    relay_url = f"{args.url}?room={args.room}"

    client = RelayClient(
        relay_url=relay_url,
        session_token=args.token,
        role=args.role,
    )

    # Connect
    if not await client.connect():
        return

    # Start receive loop in background
    receive_task = asyncio.create_task(client.receive_loop())

    # Wait for peer
    print("⏳ Waiting for peer...")
    if await client.wait_for_peer(timeout=60):
        print("✅ Both peers connected!")

        # Send audio if provided
        if args.input:
            await client.send_audio_file(args.input)
            # Wait a bit for responses
            await asyncio.sleep(3)
    else:
        print("⚠️  Timeout waiting for peer")

    # Close
    await client.close()
    await receive_task

    # Save/play received audio
    if client.received_audio:
        client.save_received_audio(args.output)
        if args.play:
            client.play_received_audio()


if __name__ == "__main__":
    asyncio.run(main())
