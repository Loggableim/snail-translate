"""Read the live widget tree of the Snail desktop app over the VM service.

The vision tool guesses at dark, dense layouts and repeatedly misread the
window chrome as app content. The running app knows exactly what it renders:
`ext.flutter.debugDumpApp` returns the widget tree, so this extracts the real
labels and the currently visible screen.

Usage:
    python widgets.py <vm-service-http-url>
"""
import json
import re
import sys

import websocket


def vm_ws_url(http_url):
    """Turn the logged HTTP VM-service URL into its WebSocket endpoint."""
    base = http_url.rstrip("/")
    return f"{base}/ws".replace("http://", "ws://")


def rpc(ws, method, params=None):
    ws.send(json.dumps({"jsonrpc": "2.0", "id": "1", "method": method,
                        "params": params or {}}))
    return json.loads(ws.recv())


def dump(http_url, pattern=r'Text\("([^"]{1,90})"'):
    ws = websocket.create_connection(vm_ws_url(http_url), timeout=25)
    vm = rpc(ws, "getVM")
    isolates = vm["result"].get("isolates", [])
    if not isolates:
        print("no isolates")
        return []
    iso = isolates[0]["id"]
    result = rpc(ws, "ext.flutter.debugDumpApp", {"isolateId": iso})
    data = result.get("result", {}).get("data", "")
    ws.close()
    return re.findall(pattern, data)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: widgets.py http://127.0.0.1:PORT/TOKEN=/")
        sys.exit(1)
    labels = dump(sys.argv[1])
    for label in labels:
        print(label)
