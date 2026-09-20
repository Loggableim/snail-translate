"""Load test for the guide-mode listener cap.

The cap is 50 listeners. This connects that many, publishes a subtitle and
asserts every one receives it, then checks that the 51st is refused — the
behaviour the relay's admission check promises but that no test exercised
with real sockets.

Usage:
    python load_test_listeners.py <worker-base-url> [api-key] [listeners]
"""
import asyncio
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import websockets


def post(url, api_key, body=None, identity=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"User-Agent": "snail-load/1.0"}
    if api_key:
        headers["X-API-Key"] = api_key
    if identity:
        # Real listener devices each carry their own Snail identity, and the
        # worker keys its rate limit on that identity — so 50 distinct
        # listeners do not share one bucket. A test that reuses a single
        # identity would hit the 20/min join limit and measure nothing real.
        headers["X-Snail-Identity"] = identity
    if data:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method="POST", headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.status, json.loads(response.read())


def relay_url_for(base, reported):
    relay = urllib.parse.urlparse(reported)
    worker = urllib.parse.urlparse(base)
    scheme = "wss" if worker.scheme == "https" else "ws"
    return urllib.parse.urlunparse(
        (scheme, worker.netloc, relay.path, relay.params, relay.query,
         relay.fragment)
    )


async def join_listener(base, room_id, api_key, identity):
    """Mints a listener token and opens an authenticated relay socket."""
    _, session = post(
        f"{base}/api/rooms/{room_id}/listen", api_key, identity=identity
    )
    # The identity also travels on the upgrade: the worker's websocket rate
    # limit keys on it, so an audience behind one NAT is not throttled as a
    # single client.
    socket = await websockets.connect(
        relay_url_for(base, session["relayUrl"]),
        additional_headers={"X-Snail-Identity": identity,
                            "User-Agent": "snail-load/1.0"},
    )
    await socket.send(json.dumps({
        "type": "auth", "protocolVersion": 1, "token": session["sessionToken"],
    }))
    # Drain until auth_ok so the relay has admitted this socket.
    while True:
        raw = await asyncio.wait_for(socket.recv(), timeout=10)
        if isinstance(raw, bytes):
            continue
        message = json.loads(raw)
        if message.get("type") == "auth_ok":
            return socket, message
        if message.get("type") == "auth_error":
            return None, message


async def main():
    base = sys.argv[1].rstrip("/")
    api_key = sys.argv[2] if len(sys.argv) > 2 else "local-dev-api-key"
    target = int(sys.argv[3]) if len(sys.argv) > 3 else 50

    print(f"creating a guide room...")
    # The guide's own identity authenticates the create call in production
    # (DEV_ALLOW_IDENTITY_AUTH); the local dev worker accepts the API key.
    _, room = post(f"{base}/api/rooms", api_key, {
        "mode": "guide", "sourceLang": "de", "listenerLanguages": ["en"],
    }, identity="abcdef0123456789abcdef01")
    room_id = room["roomId"]
    print(f"room: {room_id}")

    # The guide connects first so it can observe the audience counter.
    host = await websockets.connect(
        relay_url_for(base, room["relayUrl"]),
        additional_headers={"X-Snail-Identity": "abcdef0123456789abcdef01",
                            "User-Agent": "snail-load/1.0"},
    )
    await host.send(json.dumps({
        "type": "auth", "protocolVersion": 1, "token": room["sessionToken"],
    }))
    while True:
        raw = await asyncio.wait_for(host.recv(), timeout=10)
        if not isinstance(raw, bytes) and json.loads(raw).get("type") == "auth_ok":
            break

    print(f"connecting {target} listeners...")
    started = time.time()
    sockets = []
    for index in range(target):
        # Each listener is its own device with its own identity, which is what
        # the worker's rate limit keys on. The identity must be hex only —
        # the worker rejects anything outside /^[a-f0-9-]{16,80}$/i.
        identity = f"{index:04d}" + "abcdef0123456789abcdef01"
        socket, message = await join_listener(base, room_id, api_key, identity)
        if socket is None:
            print(f"  listener {index + 1} refused: {message}")
            break
        sockets.append(socket)
    elapsed = time.time() - started
    print(f"connected {len(sockets)} listeners in {elapsed:.1f}s")

    # The relay's own counter is the authoritative audience size.
    status_request = urllib.request.Request(
        f"{base}/api/rooms/{room_id}/status",
        headers={"User-Agent": "snail-load/1.0"},
    )
    with urllib.request.urlopen(status_request, timeout=15) as response:
        status = json.loads(response.read())
    print(f"relay reports listenerCount: {status.get('listenerCount')}")

    # One subtitle must reach every listener.
    print("publishing one subtitle...")
    await host.send(json.dumps({
        "type": "subtitle", "messageId": "load-1",
        "text": "Guten Tag an alle Zuhörer.",
        "sourceLang": "de", "targetLang": "en", "timestamp": 1,
    }))

    received = 0
    for socket in sockets:
        try:
            while True:
                raw = await asyncio.wait_for(socket.recv(), timeout=8)
                if isinstance(raw, bytes):
                    continue
                if json.loads(raw).get("type") == "subtitle":
                    received += 1
                    break
        except asyncio.TimeoutError:
            pass
    print(f"subtitle delivered to {received}/{len(sockets)} listeners")

    # The 51st listener must be refused.
    overflow_socket, overflow_message = await join_listener(
        base, room_id, api_key, "ffffffffffffffffffffffff"
    )
    if overflow_socket is None:
        print(f"51st listener refused: {overflow_message.get('error')}")
    else:
        print("51st listener was ADMITTED (cap not enforced)")
        await overflow_socket.close()

    for socket in sockets:
        await socket.close()
    await host.close()

    ok = (
        len(sockets) == target
        and status.get("listenerCount") == target
        and received == len(sockets)
        and overflow_socket is None
    )
    print(f"\n{'LOAD TEST OK' if ok else 'LOAD TEST FAILED'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    asyncio.run(main())
