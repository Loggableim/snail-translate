"""Guide client for the Snail guide mode.

Acts as the guide: creates a guide room, opens the relay socket as the host
and publishes subtitles. Used to verify the fan-out end to end against the
real worker and relay without driving the desktop UI.

Usage:
    python guide_client.py <worker-base-url> [api-key]
"""
import asyncio
import json
import sys
import urllib.request

import websockets


async def main():
    base = sys.argv[1].rstrip("/")
    api_key = sys.argv[2] if len(sys.argv) > 2 else "local-dev-api-key"

    # 1. Create a guide room.
    body = json.dumps({
        "mode": "guide",
        "sourceLang": "de",
        "listenerLanguages": ["en", "fr"],
    }).encode()
    request = urllib.request.Request(
        f"{base}/api/rooms",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "X-API-Key": api_key},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        session = json.loads(response.read())
    room_id = session["roomId"]
    print(f"ROOM={room_id}")

    relay_url = session["relayUrl"]
    relay_url = relay_url.replace(
        "wss://snail.dominik.in", base.replace("http://", "ws://")
    ).replace("wss://", "ws://")

    async with websockets.connect(relay_url) as socket:
        await socket.send(json.dumps({
            "type": "auth",
            "protocolVersion": 1,
            "token": session["sessionToken"],
        }))

        async def listen():
            while True:
                raw = await socket.recv()
                if isinstance(raw, bytes):
                    continue
                message = json.loads(raw)
                kind = message.get("type")
                if kind == "listener_joined":
                    print(f"LISTENER_JOINED count={message.get('count')}")
                elif kind == "listener_left":
                    print(f"LISTENER_LEFT count={message.get('count')}")
                elif kind == "delivery_ack":
                    print(f"ACK {message.get('messageId')}")
                elif kind == "error":
                    print(f"ERROR {message.get('error')}")

        listener_task = asyncio.create_task(listen())

        # 2. Publish subtitles once a listener is present.
        print("waiting for a listener...")
        await asyncio.sleep(6)
        for index, (lang, text) in enumerate([
            ("en", "Guten Tag, willkommen zur Fuehrung."),
            ("fr", "Bonjour, bienvenue a la visite."),
        ]):
            await socket.send(json.dumps({
                "type": "subtitle",
                "messageId": f"e2e-subtitle-{index}",
                "text": text,
                "sourceLang": "de",
                "targetLang": lang,
                "timestamp": index,
            }))
            print(f"SENT [{lang}] {text}")
            await asyncio.sleep(1)

        await asyncio.sleep(3)
        listener_task.cancel()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    asyncio.run(main())
