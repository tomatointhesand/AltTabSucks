#!/usr/bin/env python3
"""cdp.py - evaluates JavaScript in a Chromium target over the DevTools protocol, stdlib only (the
test VM has no websocket module). Chromium must run with --remote-debugging-port.
Usage: cdp.py <port> <target url prefix> <expression>   prints the result as JSON
The expression may be a promise; it's awaited."""

import base64
import json
import os
import socket
import struct
import sys
import urllib.request


def ws_connect(url):
    host_port, path = url[len("ws://"):].split("/", 1)
    host, port = host_port.split(":")
    s = socket.create_connection((host, int(port)), timeout=30)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /{path} HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(1)
    if b" 101 " not in head.split(b"\r\n")[0]:
        raise OSError(head.decode(errors="replace"))
    return s


def ws_send(s, text):
    data = text.encode()
    mask = os.urandom(4)
    n = len(data)
    header = b"\x81" + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536
                        else bytes([0x80 | 127]) + struct.pack(">Q", n))
    s.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise OSError("closed")
        buf += chunk
    return buf


def ws_recv(s):
    msg = b""
    while True:
        b0, b1 = recv_exact(s, 2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", recv_exact(s, 2))[0]
        elif n == 127:
            n = struct.unpack(">Q", recv_exact(s, 8))[0]
        msg += recv_exact(s, n)
        if b0 & 0x80:
            return msg.decode()


def evaluate(port, prefix, expression):
    targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=10))
    target = next(t for t in targets if t["url"].startswith(prefix))
    s = ws_connect(target["webSocketDebuggerUrl"])
    ws_send(s, json.dumps({"id": 1, "method": "Runtime.evaluate",
                           "params": {"expression": expression, "awaitPromise": True, "returnByValue": True}}))
    while True:
        reply = json.loads(ws_recv(s))
        if reply.get("id") == 1:
            break
    result = reply.get("result", {})
    if "exceptionDetails" in result:
        raise SystemExit("JS: " + json.dumps(result["exceptionDetails"].get("exception", {}).get("description")))
    return result.get("result", {}).get("value")


if __name__ == "__main__":
    print(json.dumps(evaluate(int(sys.argv[1]), sys.argv[2], sys.argv[3])))
