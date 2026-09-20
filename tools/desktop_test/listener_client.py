"""Listener client for the Snail guide mode.

Joins a guide room as a listener over the real WebSocket relay and prints
every subtitle it receives. This is the counterpart to the guide app: it
proves the end-to-end flow (worker mints the token, relay admits the
listener, the guide's subtitles reach the audience) without needing a
second phone or emulator.

Usage:
    python listener_client.py <worker-base-url> <room-id> [api-key]
"""
import asyncio
import json
import sys

import websockets


async def main():
    base = sys.argv[1].rstrip("/")
    room_id = sys.argv[2]
    api_key = sys.argv[3] if len(sys.argv) > 3 else "local-dev-api-key"

    import urllib.request

    # 1. Mint a listener token through the worker.
    request = urllib.request.Request(
        f"{base}/api/rooms/{room_id}/listen",
        method="POST",
        headers={"X-API-Key": api_key},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            session = json.loads(response.read())
    except urllib.error.HTTPError as error:
        print(f"listen failed: HTTP {error.code} {error.read()[:200]}")
        return

    print(f"joined as listener: mode={session.get('mode')} "
          f"languages={session.get('listenerLanguages')}")

    # 2. Open the relay socket and authenticate.
    relay_url = session["relayUrl"]
    # The worker reports the production host; the local dev worker serves the
    # same path on its own port.
    relay_url = relay_url.replace("wss://snail.dominik.in", base.replace("http://", "ws://"))
    relay_url = relay_url.replace("wss://", "ws://")

    async with websockets.connect(relay_url) as socket:
        await socket.send(json.dumps({
            "type": "auth",
            "protocolVersion": 1,
            "token": session["sessionToken"],
        }))

        print("waiting for subtitles (Ctrl+C to stop)...")
        while True:
            raw = await socket.recv()
            if isinstance(raw, bytes):
                continue
            message = json.loads(raw)
            kind = message.get("type")
            if kind == "auth_ok":
                print(f"authenticated as {message.get('peerId')}")
            elif kind == "subtitle":
                print(f"[{message.get('targetLang')}] {message.get('text')}")
            elif kind == "chat":
                print(f"(chat) {message.get('text')}")
            elif kind == "peer_left":
                print("guide disconnected")
            elif kind == "error":
                print(f"error: {message.get('error')}")
            elif kind == "chat_history":
                history = message.get("history", [])
                print(f"history: {len(history)} entries")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    asyncio.run(main())
