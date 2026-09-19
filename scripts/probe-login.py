#!/usr/bin/env python3
"""Diag probe: log into the local Velocity proxy (127.0.0.1:25565) and print
every packet the proxy sends back, with timestamps. Bypasses the minekube edge
so a failure here is unambiguously a proxy/backend problem, not a tunnel problem.

Framing note: once the server sends Set Compression, EVERY client->server packet
must be wrapped as  <len:varint> <data_length:varint> <payload>  where
data_length == 0 means the payload is stored raw. Sending the pre-compression
framing after that handshake is malformed and makes the server kill the socket
with no disconnect packet -- exactly the symptom we are chasing, so it must be
excluded before any conclusion is drawn.
"""
import socket, struct, zlib, uuid, time, sys

HOST, PORT, PROTO = "127.0.0.1", 25565, 776
T0 = time.time()


def ts():
    return "t+%6.2fs" % (time.time() - T0)


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


compressed = False


def pkt(pid, data=b""):
    """Frame one client->server packet, honouring the compression handshake."""
    body = wvarint(pid) + data
    if compressed:
        # data_length = 0 -> payload below threshold, stored uncompressed
        return wvarint(len(body) + 1) + b"\x00" + body
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
            raise EOFError
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


def text(d):
    """Best-effort decode of a disconnect reason payload."""
    try:
        sl, i = vf(d, 0)
        return d[i:i + sl].decode("utf-8", "ignore")
    except Exception:
        pass
    try:
        return d.decode("utf-8", "ignore")
    except Exception:
        return repr(d[:120])


try:
    s = socket.create_connection((HOST, PORT), timeout=15)
except Exception as e:
    print(f"{ts()} PROBE: cannot connect to {HOST}:{PORT}: {e}")
    sys.exit(0)

print(f"{ts()} PROBE: connected to {HOST}:{PORT}")
hs = wvarint(PROTO) + wstr("127.0.0.1") + struct.pack(">H", PORT) + wvarint(2)
s.sendall(pkt(0x00, hs))
s.sendall(pkt(0x00, wstr("DiagProbe") + uuid.uuid4().bytes))
print(f"{ts()} PROBE -> handshake(proto={PROTO}, state=2) + Login Start")

acked_at = None
deadline = time.time() + 25
while time.time() < deadline:
    s.settimeout(max(1, deadline - time.time()))
    try:
        length = rv(s)
        body = rx(s, length)
    except EOFError:
        if acked_at is not None:
            print(f"{ts()} PROBE: server CLOSED the stream {time.time() - acked_at:.2f}s "
                  f"after Login Success — no disconnect packet, no reason given")
        else:
            print(f"{ts()} PROBE: server CLOSED the stream during login")
        break
    except socket.timeout:
        print(f"{ts()} PROBE: no packet within the 25s deadline — stream still open "
              f"(a real client would sit on 'Logging in...' forever)")
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
        print(f"{ts()} PROBE <- Set Compression (threshold={th})")
    elif pid == 0x02 and acked_at is None:
        print(f"{ts()} PROBE <- Login Success (sending Login Acknowledged, compressed framing)")
        s.sendall(pkt(0x03))
        acked_at = time.time()
    elif pid == 0x00 and acked_at is None:
        print(f"{ts()} PROBE <- LOGIN-STATE DISCONNECT: {text(data)}")
        break
    elif pid == 0x02:
        print(f"{ts()} PROBE <- CONFIG-STATE DISCONNECT: {text(data)}")
        break
    elif pid == 0x1D and acked_at is not None:
        print(f"{ts()} PROBE <- PLAY-STATE DISCONNECT: {text(data)}")
        break
    else:
        print(f"{ts()} PROBE <- packet id 0x{pid:02x} len={len(data)}")

print(f"{ts()} PROBE: done")
