"""Quick WebSocket test for Snail DO relay."""
import asyncio
import websockets
import json
import sys

WORKER_URL = "wss://snail-worker.pixstash.workers.dev"
ROOM_ID = "test-room-001"

async def test_ws():
    url = f"{WORKER_URL}/?room={ROOM_ID}"
    print(f"Connecting to {url}...")
    try:
        async with websockets.connect(url, subprotocols=["snail-v1"]) as ws:
            print("Connected!")
            # Send a ping
            await ws.send(json.dumps({"type": "ping"}))
            print("Sent: ping")
            try:
                resp = await asyncio.wait_for(ws.recv(), timeout=5)
                print(f"Received: {resp}")
            except asyncio.TimeoutError:
                print("No response within 5s (expected if DO doesn't echo ping)")
            
            # Send a test message
            await ws.send(json.dumps({"type": "audio", "data": "test"}))
            print("Sent: audio test")
            
            await asyncio.sleep(1)
            print("Test complete!")
    except websockets.exceptions.InvalidStatus as e:
        print(f"WebSocket upgrade failed: {e.response.status_code}")
        print(f"Headers: {dict(e.response.headers)}")
    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}")

asyncio.run(test_ws())
