#!/usr/bin/env python3
"""A pretend X100 VI on TCP 55740, for rehearsing the camera path in the iOS simulator.

The simulator shares the Mac's network, so point the app at 127.0.0.1:

    python3 tools/fakecam.py --photos ~/Pictures/some-jpegs --latency 30 --rate 4
    xcrun simctl launch booted md.thomas.fujibridge -BridgeHost 127.0.0.1 -BridgeAutoRun camera

It speaks the same packets as FujiBridge/VirtualBody.swift: Fuji's 82-byte init, then USB-style PTP
containers. Knobs make it misbehave the way the real body does: Init Fail, OK prompt, a socket
that dies mid-file, slow first byte, thin Wi-Fi.
"""
import argparse
import os
import socket
import struct
import threading
import time

OPEN_SESSION = 0x1002
GET_OBJECT_INFO = 0x1008
GET_PROP = 0x1015
SET_PROP = 0x1016
GET_PARTIAL = 0x101B
OK = 0x2001
INVALID_OBJECT = 0x2009


def container(kind, code, tid, payload=b""):
    return struct.pack("<IHHI", 12 + len(payload), kind, code, tid) + payload


def ptp_string(text):
    units = text[:31]
    out = bytes([len(units) + 1])
    for ch in units:
        out += struct.pack("<H", ord(ch))
    return out + b"\x00\x00"


class Card:
    def __init__(self, args):
        self.frames = []
        if args.photos:
            names = sorted(n for n in os.listdir(args.photos) if n.lower().endswith((".jpg", ".jpeg", ".heif", ".hif", ".raf")))
            for index, name in enumerate(names[: args.count], start=1):
                with open(os.path.join(args.photos, name), "rb") as f:
                    self.frames.append((index, name.upper(), f.read()))
        else:
            for index in range(1, args.count + 1):
                size = args.size + index * 137_000
                body = b"\xff\xd8\xff\xe0" + os.urandom(size - 6) + b"\xff\xd9"
                self.frames.append((index, "DSCF%04d.JPG" % (4400 + index), body))

    def get(self, handle):
        for frame in self.frames:
            if frame[0] == handle:
                return frame
        return None


class Session(threading.Thread):
    connections = 0
    stalled = False

    def __init__(self, sock, card, args):
        super().__init__(daemon=True)
        self.sock = sock
        self.card = card
        self.args = args
        self.opened = time.time()
        self.correct = 0
        Session.connections += 1
        self.number = Session.connections

    def log(self, text):
        print("[%d %6.0f ms] %s" % (self.number, (time.time() - self.opened) * 1000, text), flush=True)

    def recv_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("client closed")
            data += chunk
        return data

    def packet(self):
        head = self.recv_exact(4)
        (length,) = struct.unpack("<I", head)
        return head + self.recv_exact(length - 4)

    def send(self, data, rate=None):
        if not rate:
            self.sock.sendall(data)
            return
        step = 32 * 1024
        per = step / (rate * 1024 * 1024)
        for i in range(0, len(data), step):
            self.sock.sendall(data[i : i + step])
            time.sleep(per)

    def run(self):
        try:
            self.serve()
        except (ConnectionError, BrokenPipeError, OSError) as error:
            self.log("closed: %s" % error)
        finally:
            self.sock.close()

    def serve(self):
        first = self.packet()
        if len(first) == 82 and struct.unpack("<I", first[4:8])[0] == 1:
            if self.args.flaky and self.number == 1:
                self.log("init -> Init Fail")
                self.sock.sendall(struct.pack("<IIII", 16, 5, 0, 0))
                first = self.packet()
            ack = bytearray(82)
            struct.pack_into("<II", ack, 0, 0x52, 2)
            for i, ch in enumerate("X100VI"):
                struct.pack_into("<H", ack, 28 + i * 2, ord(ch))
            self.log("init -> ack")
            self.sock.sendall(bytes(ack))
        pending = None
        while True:
            pkt = self.packet()
            kind, code, tid = struct.unpack("<HHI", pkt[4:12])
            params = [struct.unpack("<I", pkt[i : i + 4])[0] for i in range(12, len(pkt) - 3, 4)]
            if kind == 2 and pending is not None:
                value = struct.unpack("<H", pkt[12:14])[0] if len(pkt) >= 14 else 0
                if pending == 0xD227:
                    self.correct = value
                self.log("set 0x%04x = %d" % (pending, value))
                pending = None
                time.sleep(self.args.latency / 1000)
                self.sock.sendall(container(3, OK, tid))
                continue
            if kind != 1:
                continue
            time.sleep(self.args.latency / 1000)
            if code == SET_PROP:
                pending = params[0] if params else 0
            elif code == GET_PROP:
                payload = self.prop(params[0] if params else 0)
                self.sock.sendall(container(2, code, tid, payload) + container(3, OK, tid))
            elif code == GET_OBJECT_INFO:
                frame = self.card.get(params[0])
                if not frame:
                    self.sock.sendall(container(3, INVALID_OBJECT, tid))
                    continue
                size = len(frame[2]) if self.correct or not self.args.lie else 102_400
                info = bytearray(208)
                struct.pack_into("<I", info, 8, 0x100000)
                struct.pack_into("<I", info, 13, size)
                name = ptp_string(frame[1])
                info[52 : 52 + len(name)] = name
                self.log("object info %d %s %d" % (frame[0], frame[1], size))
                self.sock.sendall(container(2, code, tid, bytes(info)) + container(3, OK, tid))
            elif code == GET_PARTIAL:
                handle, offset, ask = params[0], params[1], params[2]
                frame = self.card.get(handle)
                if not frame:
                    self.sock.sendall(container(3, INVALID_OBJECT, tid))
                    continue
                time.sleep(self.args.first_byte / 1000)
                chunk = frame[2][offset : offset + ask]
                data = container(2, code, tid, chunk)
                if self.args.stall and not Session.stalled and offset > 0:
                    Session.stalled = True
                    self.log("partial %d @%d -> sending half, then going silent" % (handle, offset))
                    self.send(data[: len(data) // 2], self.args.rate)
                    time.sleep(self.args.stall)
                    raise ConnectionError("stall fault")
                self.send(data, self.args.rate)
                self.sock.sendall(container(3, OK, tid))
            else:
                if code == OPEN_SESSION:
                    self.log("open session tid %d" % tid)
                self.sock.sendall(container(3, OK, tid))

    def prop(self, prop):
        if prop == 0xD212:
            ready = time.time() - self.opened >= self.args.ok_after
            state = 2 if ready else 0
            self.log("events DF00=%d" % state)
            return struct.pack("<HHIHI", 2, 0xD222, len(self.card.frames), 0xDF00, state)
        if prop == 0xD621:
            handles = [f[0] for f in self.card.frames]
            return struct.pack("<I", len(handles)) + b"".join(struct.pack("<I", h) for h in handles)
        if prop == 0xD620:
            return struct.pack("<I", len(self.card.frames))
        if prop in (0xDF22, 0xDF24):
            return struct.pack("<I", 0x0002000C)
        if prop == 0xDF25:
            return struct.pack("<I", 5)
        if prop == 0xDF21:
            return struct.pack("<I", 0x0002000A)
        if prop == 0xDF28:
            return struct.pack("<I", 1)
        return struct.pack("<I", 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=55740)
    parser.add_argument("--photos", help="folder of real files to serve")
    parser.add_argument("--count", type=int, default=4, help="frames on the card")
    parser.add_argument("--size", type=int, default=2_400_000, help="bytes per generated frame")
    parser.add_argument("--latency", type=float, default=5, help="ms before answering every command")
    parser.add_argument("--first-byte", type=float, default=20, help="extra ms before each partial's data")
    parser.add_argument("--rate", type=float, default=0, help="MB/s cap on partial data, 0 = unlimited")
    parser.add_argument("--ok-after", type=float, default=1.5, help="seconds before DF00 leaves the OK prompt")
    parser.add_argument("--flaky", action="store_true", help="first init gets Init Fail")
    parser.add_argument("--lie", action="store_true", help="report 100 KB until D227 = 1")
    parser.add_argument("--stall", type=float, default=0, help="go silent this many seconds mid-file once, then drop")
    parser.add_argument("--dump", help="write the served frames here, to diff against what the app saved")
    args = parser.parse_args()

    card = Card(args)
    if args.dump:
        os.makedirs(args.dump, exist_ok=True)
        for _, name, body in card.frames:
            with open(os.path.join(args.dump, name), "wb") as f:
                f.write(body)
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(4)
    print("fakecam on %s:%d, %d frames, %.1f MB" % (args.host, args.port, len(card.frames), sum(len(f[2]) for f in card.frames) / 1048576), flush=True)
    while True:
        sock, _ = server.accept()
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        Session(sock, card, args).start()


if __name__ == "__main__":
    main()
