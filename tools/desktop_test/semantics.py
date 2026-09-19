"""Read the Flutter semantics tree from a running desktop app.

The vision tool guesses at dark, dense layouts. The app itself knows exactly
what is on screen: Flutter exposes the semantics tree over the VM service, so
this reads the real widget labels instead of interpreting pixels.
"""
import json
import sys

import websocket

VM_SERVICE = sys.argv[1] if len(sys.argv) > 1 else None


def rpc(ws, method, params=None):
    ws.send(json.dumps({"jsonrpc": "2.0", "id": "1", "method": method,
                        "params": params or {}}))
    return json.loads(ws.recv())


def main():
    if not VM_SERVICE:
        print("usage: semantics.py ws://127.0.0.1:PORT/TOKEN=/ws")
        return
    ws = websocket.create_connection(VM_SERVICE, timeout=15)
    vm = rpc(ws, "getVM")
    isolates = vm["result"].get("isolates", [])
    if not isolates:
        print("no isolates")
        return
    iso = isolates[0]["id"]

    # The semantics tree is exposed through the flutter service extension.
    result = rpc(ws, "ext.flutter.debugDumpSemanticsTreeInTraversalOrder",
                 {"isolateId": iso})
    if "result" in result and "data" in result["result"]:
        print(result["result"]["data"])
    else:
        print(json.dumps(result, indent=2)[:2000])
    ws.close()


if __name__ == "__main__":
    main()
