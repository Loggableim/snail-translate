"""Verifies the safety-number path against a live relay.

Two peers join the same room, exchange agreement keys the way the app does,
and derive the fingerprint from the resulting shared secret. The check that
matters: both sides must arrive at the *same* number, because that is what
makes the comparison meaningful. A relay that substituted a key would produce
different numbers, which is the whole point of showing them.

Usage:
    python verify_fingerprint.py <worker-base-url> [api-key]
"""
import asyncio
import base64
import hashlib
import hmac
import json
import sys
import urllib.parse
import urllib.request

import websockets

# A stand-in for the device ECDH key pair: both sides need a key pair, and the
# shared secret must be identical for a matching fingerprint.
ALICE_PRIVATE = b"alice-agreement-private-key-material"
BOB_PRIVATE = b"bob-agreement-private-key-material"


def public_for(private: bytes) -> str:
    """Stands in for the device public key the app sends."""
    return base64.b64encode(hashlib.sha256(private).digest()).decode()


def shared_secret(mine: bytes, theirs_public: str) -> bytes:
    """Stands in for ECDH: both sides must reach the same value."""
    theirs = base64.b64decode(theirs_public)
    # A real ECDH is commutative; this mirrors that property for the test.
    return hashlib.sha256(b"|".join(sorted([hashlib.sha256(mine).digest(), theirs]))).digest()


def hkdf(secret: bytes, info: bytes, length: int = 32) -> bytes:
    """HKDF-SHA256, matching what ChatCryptoService.derive does."""
    prk = hmac.new(b"\x00" * 32, secret, hashlib.sha256).digest()
    okm = b""
    block = b""
    counter = 1
    while len(okm) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        okm += block
        counter += 1
    return okm[:length]


def fingerprint_digits(secret: bytes) -> str:
    """The 12x5-digit safety number, matching KeyFingerprint.digits."""
    derived = hkdf(secret, b"snail-chat-v1-fingerprint")
    groups = []
    index = 0
    for _ in range(12):
        high = derived[index % len(derived)]
        low = derived[(index + 1) % len(derived)]
        groups.append(f"{((high << 8) | low) % 100000:05d}")
        index += 2
    return " ".join(groups)


def post(url, api_key, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"User-Agent": "snail-verify/1.0"}
    if api_key:
        headers["X-API-Key"] = api_key
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


async def main():
    base = sys.argv[1].rstrip("/")
    api_key = sys.argv[2] if len(sys.argv) > 2 else "local-dev-api-key"
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(f"{'PASS' if ok else 'FAIL'}  {name}{'  ' + detail if detail else ''}")

    # 1. A duo room, since the fingerprint guards a two-party conversation.
    _, room = post(f"{base}/api/rooms", api_key, {
        "sourceLang": "de", "targetLang": "en",
    })
    room_id = room["roomId"]
    print(f"room: {room_id}")

    # 2. The host joins and announces its agreement key.
    host = await websockets.connect(
        relay_url_for(base, room["relayUrl"]),
        additional_headers={"User-Agent": "snail-verify/1.0"},
    )
    await host.send(json.dumps({
        "type": "auth", "protocolVersion": 1, "token": room["sessionToken"],
        "agreementPublicKey": public_for(ALICE_PRIVATE),
    }))
    while True:
        message = json.loads(await asyncio.wait_for(host.recv(), timeout=10))
        if message.get("type") == "auth_ok":
            break

    # 3. The guest joins and receives the host's key.
    _, guest_session = post(f"{base}/api/rooms/{room_id}/join", api_key)
    guest = await websockets.connect(
        relay_url_for(base, guest_session["relayUrl"]),
        additional_headers={"User-Agent": "snail-verify/1.0"},
    )
    await guest.send(json.dumps({
        "type": "auth", "protocolVersion": 1, "token": guest_session["sessionToken"],
        "agreementPublicKey": public_for(BOB_PRIVATE),
    }))

    host_peer_key = None
    guest_peer_key = None
    deadline = asyncio.get_event_loop().time() + 15
    while asyncio.get_event_loop().time() < deadline:
        for socket, label in ((host, "host"), (guest, "guest")):
            try:
                raw = await asyncio.wait_for(socket.recv(), timeout=2)
            except asyncio.TimeoutError:
                continue
            if isinstance(raw, bytes):
                continue
            message = json.loads(raw)
            if message.get("type") == "peer_joined":
                peer_key = message.get("peerAgreementPublicKey")
                if label == "host":
                    host_peer_key = peer_key
                else:
                    guest_peer_key = peer_key
        if host_peer_key and guest_peer_key:
            break

    check("host received the guest's agreement key", host_peer_key is not None,
          str(host_peer_key)[:24])
    check("guest received the host's agreement key", guest_peer_key is not None,
          str(guest_peer_key)[:24])

    # 4. Both derive the shared secret and the fingerprint.
    # Alice is the host: she combines her private key with the key she
    # received from the guest. Bob is the guest: his private key with the
    # host's key. Swapping these is the mistake the check below catches.
    alice_secret = shared_secret(ALICE_PRIVATE, host_peer_key or "")
    bob_secret = shared_secret(BOB_PRIVATE, guest_peer_key or "")
    check("both sides derive the same shared secret", alice_secret == bob_secret)

    alice_number = fingerprint_digits(alice_secret)
    bob_number = fingerprint_digits(bob_secret)
    check("both sides show the same safety number", alice_number == bob_number,
          alice_number[:23] + "…")
    check("the number has twelve groups",
          len(alice_number.split(" ")) == 12)

    # 5. A relay that substituted a key produces different numbers.
    impostor_secret = shared_secret(ALICE_PRIVATE, public_for(b"relay-key"))
    impostor_number = fingerprint_digits(impostor_secret)
    check("a substituted key produces a different number",
          impostor_number != alice_number)

    await host.close()
    await guest.close()

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    asyncio.run(main())
