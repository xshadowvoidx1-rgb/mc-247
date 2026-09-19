#!/usr/bin/env python3
"""Diag probe: log into the local Velocity proxy (127.0.0.1:25565) and print
every packet the proxy sends back. Bypasses the minekube edge so a failure here
is unambiguously a proxy/backend problem, not a tunnel problem."""
import socket, struct, json, zlib, uuid, time, sys

HOST, PORT, PROTO = "127.0.0.1", 25565, 776


def wvarint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def wstr(s):
    b = s.encode()
    return wvarint(len(b)) + b


def pkt(pid, data=b""):
    body = wvarint(pid) + data
    return wvarint(len(body)) + body


def rv(sock):
    n = 0
    sh = 0
    while True:
        b = sock.recv(1)
        if not b:
            raise EOFError
        n |= (b[0] & 0x7F) << sh
        if not (b[0] & 0x80):
            return n
        sh += 7


def rx(sock, n):
    b = b""
    while len(b) < n:
        c = sock.recv(n - len(b))
        if not c:
            break
        b += c
    return b


def vf(d, i):
    n = 0
    sh = 0
    while True:
        b = d[i]
        i += 1
        n |= (b & 0x7F) << sh
        if not (b & 0x80):
            return n, i
        sh += 7


try:
    s = socket.create_connection((HOST, PORT), timeout=15)
except Exception as e:
    print(f"PROBE: cannot connect to {HOST}:{PORT}: {e}")
    sys.exit(0)

hs = wvarint(PROTO) + wstr("127.0.0.1") + struct.pack(">H", PORT) + wvarint(2)
s.sendall(pkt(0x00, hs))
s.sendall(pkt(0x00, wstr("DiagProbe") + uuid.uuid4().bytes))

compressed = False
acked = False
deadline = time.time() + 25
while time.time() < deadline:
    s.settimeout(max(1, deadline - time.time()))
    try:
        length = rv(s)
        body = rx(s, length)
    except (EOFError, socket.timeout):
        print("PROBE: stream ended / timeout")
        break
    if compressed:
        dlen, i = vf(body, 0)
        if dlen == 0:
            pid, i = vf(body, i)
            data = body[i:]
        else:
            data = zlib.decompress(body[i:])
            pid, j = vf(data, 0)
            data = data[j:]
    else:
        pid, i = vf(body, 0)
        data = body[i:]

    if not compressed and pid == 0x03:
        th, _ = vf(data, 0)
        compressed = True
        print(f"PROBE <- Set Compression (threshold={th})")
    elif not acked and pid == 0x02:
        print("PROBE <- Login Success (sent Login Acknowledged)")
        s.sendall(pkt(0x03))
        acked = True
    elif pid == 0x00:
        try:
            sl, i = vf(data, 0)
            print("PROBE <- DISCONNECT:", data[i:i + sl].decode("utf-8", "ignore"))
        except Exception:
            print("PROBE <- packet 0x00 raw:", data[:200])
    else:
        print(f"PROBE <- packet id 0x{pid:02x} len={len(data)}")

print("PROBE: done")
