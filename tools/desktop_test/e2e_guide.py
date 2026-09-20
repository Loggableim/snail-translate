"""End-to-end guide-mode test against a running worker.

Creates a guide room, joins it as a listener, then publishes subtitles as
the guide and asserts they arrive. This is the two-device flow without two
devices: the same worker endpoints, the same relay, the same protocol.

Usage:
    python e2e_guide.py <worker-base-url> [api-key]
"""
import asyncio
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

import websockets


# Cloudflare's bot protection rejects the default urllib User-Agent with
# error 1010 before the request ever reaches the worker.
USER_AGENT = "snail-e2e/1.0"


def post(url, api_key, body=None, identity=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"User-Agent": USER_AGENT}
    if api_key:
        headers["X-API-Key"] = api_key
    if identity:
        # Production runs DEV_MODE with DEV_ALLOW_IDENTITY_AUTH, so a valid
        # Snail identity authenticates without the worker's DEV_API_KEY. The
        # worker only accepts /^[a-f0-9-]{16,80}$/i — anything else is
        # silently rejected as Unauthorized.
        headers["X-Snail-Identity"] = identity
    if data:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method="POST", headers=headers)
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.status, json.loads(response.read())


def get(url, identity=None):
    headers = {"User-Agent": USER_AGENT}
    if identity:
        headers["X-Snail-Identity"] = identity
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.status, json.loads(response.read())


def relay_url_for(base, reported):
    """Point the relay URL at the worker under test.

    The worker derives the URL from its own request host, which under
    `wrangler dev` is the configured production route (`snail.dominik.in`)
    rather than the local address. The relay lives on the same worker, so the
    host and scheme come from the base URL being tested.
    """
    relay = urllib.parse.urlparse(reported)
    worker = urllib.parse.urlparse(base)
    scheme = "wss" if worker.scheme == "https" else "ws"
    netloc = worker.netloc
    return urllib.parse.urlunparse(
        (scheme, netloc, relay.path, relay.params, relay.query, relay.fragment)
    )


async def connect(url, token):
    socket = await websockets.connect(url)
    await socket.send(json.dumps({
        "type": "auth", "protocolVersion": 1, "token": token,
    }))
    return socket


async def recv_until(socket, wanted, timeout=8.0):
    """Collects messages until one of `wanted` arrives."""
    seen = []
    deadline = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < deadline:
        remaining = deadline - asyncio.get_event_loop().time()
        try:
            raw = await asyncio.wait_for(socket.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            break
        if isinstance(raw, bytes):
            continue
        message = json.loads(raw)
        seen.append(message)
        if message.get("type") in wanted:
            return message, seen
    return None, seen


async def main():
    base = sys.argv[1].rstrip("/")
    api_key = sys.argv[2] if len(sys.argv) > 2 else "local-dev-api-key"
    # Production authenticates through a Snail identity (DEV_ALLOW_IDENTITY_AUTH);
    # the local dev worker accepts the API key. A valid identity works on both.
    identity = "abcdef0123456789abcdef01"
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(f"{'PASS' if ok else 'FAIL'}  {name}{'  ' + detail if detail else ''}")

    # 1. Create the guide room.
    status, room = post(f"{base}/api/rooms", api_key, {
        "mode": "guide", "sourceLang": "de", "listenerLanguages": ["en", "fr"],
    }, identity=identity)
    check("create guide room", status == 201 and room.get("mode") == "guide",
          f"room={room.get('roomId')} mode={room.get('mode')}")
    room_id = room["roomId"]

    # 2. Public status reports the guide room.
    status, info = get(f"{base}/api/rooms/{room_id}/status", identity=identity)
    check("status reports guide mode",
          status == 200 and info.get("mode") == "guide"
          and info.get("listenerLanguages") == ["en", "fr"],
          f"count={info.get('listenerCount')}")

    # 3. A guest join is refused with the fallback code.
    try:
        post(f"{base}/api/rooms/{room_id}/join", api_key, identity=identity)
        check("guest join refused", False, "join unexpectedly succeeded")
    except urllib.error.HTTPError as error:
        body = json.loads(error.read())
        check("guest join refused",
              error.code == 409 and body.get("code") == "guide_room_use_listen",
              f"HTTP {error.code} code={body.get('code')}")

    # 4. The guide connects as host.
    host = await connect(relay_url_for(base, room["relayUrl"]), room["sessionToken"])
    message, _ = await recv_until(host, {"auth_ok", "auth_error"})
    check("guide authenticated", message is not None and message["type"] == "auth_ok",
          str(message))

    # 5. A listener joins through the listen endpoint.
    status, listener_session = post(
        f"{base}/api/rooms/{room_id}/listen", api_key, identity=identity
    )
    check("listener token minted",
          status == 200 and listener_session.get("mode") == "guide",
          f"langs={listener_session.get('listenerLanguages')}")

    listener = await connect(
        relay_url_for(base, listener_session["relayUrl"]),
        listener_session["sessionToken"],
    )
    message, _ = await recv_until(listener, {"auth_ok", "auth_error"})
    check("listener authenticated",
          message is not None and message["type"] == "auth_ok", str(message))

    # 6. The host learns about the audience.
    message, _ = await recv_until(host, {"listener_joined"})
    check("host notified of listener",
          message is not None and message.get("count") == 1, str(message))

    # 7. Subtitles fan out to the listener.
    for index, (lang, text) in enumerate([
        ("en", "Guten Tag, willkommen zur Fuehrung."),
        ("fr", "Bonjour, bienvenue a la visite."),
    ]):
        await host.send(json.dumps({
            "type": "subtitle", "messageId": f"e2e-{index}", "text": text,
            "sourceLang": "de", "targetLang": lang, "timestamp": index,
        }))
        message, _ = await recv_until(listener, {"subtitle"})
        check(f"subtitle delivered [{lang}]",
              message is not None and message.get("text") == text
              and message.get("targetLang") == lang,
              str(message))

    # 8. The listener's own subtitle attempt is refused.
    await listener.send(json.dumps({
        "type": "subtitle", "text": "I am the guide now",
    }))
    message, _ = await recv_until(listener, {"error"})
    check("listener cannot publish subtitles",
          message is not None
          and "Only the host can send subtitles" in str(message.get("error")),
          str(message))

    # 9. A late listener receives the transcript.
    status, late_session = post(
        f"{base}/api/rooms/{room_id}/listen", api_key, identity=identity
    )
    late = await connect(
        relay_url_for(base, late_session["relayUrl"]), late_session["sessionToken"]
    )
    message, seen = await recv_until(late, {"chat_history"})
    history = (message or {}).get("history", [])
    check("late listener gets transcript",
          any(entry.get("text") == "Guten Tag, willkommen zur Fuehrung."
              for entry in history),
          f"{len(history)} entries")

    await host.close()
    await listener.close()
    await late.close()

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    asyncio.run(main())
