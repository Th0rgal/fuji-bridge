#!/usr/bin/env python3
"""Find a Fujifilm body that joined *your* Wi-Fi router, the way libfuji does, and prove a PTP session.

Two modes put the camera on the home network instead of its own access point, so this computer keeps its
internet while it imports:

  PC AutoSave   camera broadcasts "DISCOVER" on UDP 51542 (register) or 51541 (connect); we NOTIFY it on
                TCP 51540, answer its REGISTER/IMPORT on our own TCP 51542/51541, then open PTP on :55740.
  Wireless      we broadcast "DISCOVERY ... PCSS/1.0" on UDP 51562; the camera connects to our TCP 51560 and
  tether        says DSC:<ip> DSCPORT:<port>; we answer 200 OK and open PTP to that address.

Protocol from petabyt/libfuji lib/discovery.c (Daniel Cook). Everything received is printed as is.

    python3 tools/fujilan.py            # listen until a camera shows up, then try PTP and exit
"""
import datetime
import socket
import struct
import sys
import threading
import time

NOTIFY, CONNECT, REGISTER, TETHER, PCSS = 51540, 51541, 51542, 51560, 51562
CLIENT = "Fuji Bridge"


def log(*parts):
    print(datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3], *parts, flush=True)


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("1.1.1.1", 1234))
    ip = s.getsockname()[0]
    s.close()
    return ip


def fields(text):
    out = {}
    for line in text.replace("\r", "").split("\n"):
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip().upper()] = v.strip()
    return out


found = threading.Event()
target = {}


def ptp_probe(ip, port):
    """Fuji init packet, then OpenSession: the same first two steps as Fuji Bridge's Wi-Fi importer."""
    log(f"PTP: connecting to {ip}:{port}")
    try:
        s = socket.create_connection((ip, port), timeout=8)
    except OSError as e:
        log("PTP: connect failed:", e)
        return
    init = bytearray(82)
    struct.pack_into("<IIIIIII", init, 0, 0x52, 1, 0x8F53E4F2, 0x5D48A5AD, 0x0B7FB287, 0xD0DED5D3, 0)
    for i, ch in enumerate(CLIENT):
        struct.pack_into("<H", init, 28 + i * 2, ord(ch))
    s.sendall(bytes(init))
    try:
        head = s.recv(8)
        log("PTP: init reply", head.hex(" "), "(type 2 = ack, 5 = init fail)")
        s.recv(4096)
        s.sendall(struct.pack("<IHHII", 16, 1, 0x1002, 1, 1))
        time.sleep(0.2)
        log("PTP: OpenSession reply", s.recv(64).hex(" "))
    except OSError as e:
        log("PTP: read failed:", e)
    s.close()


def autosave_listener(port, kind):
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    u.bind(("", port))
    log(f"listening UDP {port} for PC AutoSave {kind}")
    while not found.is_set():
        data, addr = u.recvfrom(2048)
        text = data.decode(errors="replace")
        log(f"UDP {port} from {addr[0]}:\n{text}")
        f = fields(text)
        cam = f.get("DSCADDR", addr[0])
        try:
            n = socket.create_connection((cam, NOTIFY), timeout=3)
            msg = f"NOTIFY * HTTP/1.1\r\nHOST: {cam}:{NOTIFY}\r\nIMPORTER: {CLIENT}\r\n"
            n.sendall(msg.encode())
            log("NOTIFY reply:", n.recv(512).decode(errors="replace").strip())
            n.close()
        except OSError as e:
            log("NOTIFY failed:", e)
            continue
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("", port))
        srv.listen(1)
        srv.settimeout(30)
        try:
            c, caddr = srv.accept()
            req = c.recv(2048).decode(errors="replace")
            log(f"TCP {port} from {caddr[0]}:\n{req}")
            if kind == "register":
                c.sendall(b"HTTP/1.1 200 OK\r\nFOLDER: guest\r\nServiceName: PCAUTOSAVE/1.0\r\n")
                log("registered. Start PC AUTO SAVE again on the camera to connect.")
            else:
                c.sendall(b"HTTP/1.1 200 OK\r\n")
                target.update(ip=cam, port=55740, mode="PC AutoSave")
                found.set()
            c.close()
        except OSError as e:
            log(f"invite server {port}:", e)
        srv.close()


def tether_listener(me):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("", TETHER))
    srv.listen(2)
    log(f"listening TCP {TETHER} for wireless tether")
    while not found.is_set():
        c, caddr = srv.accept()
        req = c.recv(2048).decode(errors="replace")
        log(f"TCP {TETHER} from {caddr[0]}:\n{req}")
        f = fields(req)
        c.sendall(b"HTTP/1.1 200 OK\r\n")
        c.close()
        target.update(ip=f.get("DSC", caddr[0]), port=int(f.get("DSCPORT", "15740") or 15740), mode="wireless tether")
        found.set()


def pcss_broadcaster(me):
    b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    b.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    bcast = ".".join(me.split(".")[:3] + ["255"])
    msg = f"DISCOVERY * HTTP/1.1\r\nHOST: {me}\r\nMX: 5\r\nSERVICE: PCSS/1.0\r\n".encode()
    log(f"broadcasting PCSS to {bcast}:{PCSS} every second")
    while not found.is_set():
        for dst in (bcast, "255.255.255.255"):
            try:
                b.sendto(msg, (dst, PCSS))
            except OSError:
                pass
        time.sleep(1)


def main():
    me = local_ip()
    log(f"this computer is {me}")
    for port, kind in ((REGISTER, "register"), (CONNECT, "connect")):
        threading.Thread(target=autosave_listener, args=(port, kind), daemon=True).start()
    threading.Thread(target=tether_listener, args=(me,), daemon=True).start()
    threading.Thread(target=pcss_broadcaster, args=(me,), daemon=True).start()
    limit = float(sys.argv[1]) if len(sys.argv) > 1 else 900
    if not found.wait(limit):
        log("no camera after", limit, "s")
        return
    log("camera found:", target)
    ptp_probe(target["ip"], target["port"])


if __name__ == "__main__":
    main()
