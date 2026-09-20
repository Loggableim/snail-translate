"""Verifies the listener path against a live guide room.

The desktop UI cannot be driven reliably by script (Flutter-Windows focus),
so this exercises the same relay messages the ListenerScreen consumes: it
joins as a listener, waits for a subtitle, and asserts the payload carries
everything the screen needs to render it (targetLang for filtering, text for
display, sourceLang for the annotation).

Usage:
    python verify_listener_path.py <worker-base-url> <room-id> [api-key]
"""
import asyncio
import json
import sys
import urllib.parse
import urllib.request

import websockets


def relay_url_for(base, reported):
    relay = urllib.parse.urlparse(reported)
    worker = urllib.parse.urlparse(base)
    scheme = "wss" if worker.scheme == "https" else "ws"
    return urllib.parse.urlunparse(
        (scheme, worker.netloc, relay.path, relay.params, relay.query,
         relay.fragment)
    )


async def main():
    base = sys.argv[1].rstrip("/")
    room_id = sys.argv[2]
    api_key = sys.argv[3] if len(sys.argv) > 3 else "local-dev-api-key"

    request = urllib.request.Request(
        f"{base}/api/rooms/{room_id}/listen",
        method="POST",
        headers={"X-API-Key": api_key, "User-Agent": "snail-verify/1.0"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        session = json.loads(response.read())

    print(f"listener session: mode={session.get('mode')} "
          f"languages={session.get('listenerLanguages')}")

    async with websockets.connect(
        relay_url_for(base, session["relayUrl"])
    ) as socket:
        await socket.send(json.dumps({
            "type": "auth",
            "protocolVersion": 1,
            "token": session["sessionToken"],
        }))

        deadline = asyncio.get_event_loop().time() + 90
        subtitles = []
        live = []
        while asyncio.get_event_loop().time() < deadline:
            try:
                raw = await asyncio.wait_for(socket.recv(), timeout=5)
            except asyncio.TimeoutError:
                continue
            if isinstance(raw, bytes):
                continue
            message = json.loads(raw)
            kind = message.get("type")
            if kind == "auth_ok":
                print(f"authenticated as {message.get('peerId')}")
            elif kind == "chat_history":
                history = message.get("history", [])
                subtitles.extend(
                    entry for entry in history if entry.get("type") == "subtitle"
                )
                print(f"history: {len(subtitles)} subtitles (from earlier turns)")
            elif kind == "subtitle":
                # A live subtitle: this is what the screen renders as it
                # arrives, and the only proof the guide is publishing now.
                subtitles.append(message)
                live.append(message)
                print(f"LIVE subtitle [{message.get('targetLang')}] "
                      f"{str(message.get('text'))[:60]}")
                if len(live) >= 2:
                    break

    # The screen needs targetLang to filter, text to render and sourceLang for
    # the annotation. A payload missing any of them renders nothing.
    complete = [
        s for s in subtitles
        if s.get("targetLang") and s.get("text") and s.get("sourceLang")
    ]
    print(f"\nsubtitles received: {len(subtitles)} "
          f"({len(live)} live, {len(subtitles) - len(live)} from history)")
    print(f"renderable (all fields present): {len(complete)}")
    for entry in live[:3]:
        print(f"  live [{entry['sourceLang']}->{entry['targetLang']}] "
              f"{str(entry['text'])[:60]}")
    if live and len(complete) == len(subtitles):
        print("\nLISTENER PATH OK — live subtitles arrived and are renderable")
    elif live:
        print("\nLIVE SUBTITLES ARRIVED but some payloads are incomplete")
    else:
        print("\nNO LIVE SUBTITLE ARRIVED (history only)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    asyncio.run(main())
