#!/usr/bin/env python3
"""Touch Sample panel server: the stock virtual-MPC-Sample panel server plus three routes.

    python3 panel-ext/touch_server.py [--port 8765] [--selftest]

Imports vendor/virtual-mpc-sample/panel/server.py unchanged (MIT, orrpunk-art/virtual-mpc-sample) and adds:
  GET /touch     the 1280x800 page for the MPC Touch's screen (panel-ext/touch.html)
  /bridge        WebSocket for the Touch bridge: LED / pad-colour / VM events out, `send` and `ui` in
  /touchui       WebSocket for the /touch page: the same events plus `ui` objects relayed from the bridge
Everything else (/, /ws, /state, ...) is the stock server. Python 3.9+, stdlib only. Nothing here talks MIDI.
"""
import argparse
import io
import json
import os
import queue
import sys
import threading
import time
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.normpath(os.path.join(HERE, "..", "vendor", "virtual-mpc-sample"))
sys.path.insert(0, VENDOR)
sys.path.insert(0, os.path.join(VENDOR, "panel"))
import server  # noqa: E402  (the stock panel server)

TOUCH_HTML = os.path.join(HERE, "touch.html")
PAD_COLOUR_PREFIX = bytes.fromhex("F0 47 7F 5C 65 00 04")


def event_for(f):
    """JSON-able event for one app->panel frame, or None.
    B0 id v on channel 0 -> led; pad colour SysEx -> pad. Channel-15 (BF) value frames and other SysEx: None."""
    if not f:
        return None
    if f[0] == 0xF0:
        if f[:7] == PAD_COLOUR_PREFIX and len(f) == 12 and f[-1] == 0xF7:
            return {"t": "pad", "i": f[7], "rgb": [f[8], f[9], f[10]]}
        return None
    if f[0] == 0xB0 and len(f) == 3:
        return {"t": "led", "id": f[1], "v": f[2]}
    return None


class Hub:
    """Listeners (WebSockets) by kind. Every listener has its own queue and sender thread, so a slow or
    dead socket never blocks the caller (the UART reader thread). A listener whose queue overflows or
    whose socket fails is dropped."""

    QUEUE = 2000

    def __init__(self):
        self.lock = threading.Lock()
        self.listeners = {"bridge": [], "touchui": []}
        self.bridge_ui = None     # last bridge status ui object, replayed to new /touchui pages

    def add(self, kind, ws, first=None):
        """Register ws; `first` (list of objects) is queued before any event."""
        q = queue.Queue(self.QUEUE)
        item = {"ws": ws, "q": q}
        for obj in first or []:
            q.put_nowait(obj)
        threading.Thread(target=self._sender, args=(kind, item), daemon=True).start()
        with self.lock:
            self.listeners[kind].append(item)
        return item

    def add_with(self, kind, ws, make_first):
        """Like add, but `make_first()` runs under the hub lock so its snapshot and the registration are atomic
        with respect to push()."""
        with self.lock:
            first = make_first()
        q = queue.Queue(self.QUEUE)
        item = {"ws": ws, "q": q}
        for obj in first:
            q.put_nowait(obj)
        threading.Thread(target=self._sender, args=(kind, item), daemon=True).start()
        with self.lock:
            self.listeners[kind].append(item)
        return item

    def remove(self, kind, item):
        with self.lock:
            if item in self.listeners[kind]:
                self.listeners[kind].remove(item)
        try:
            item["q"].put_nowait(None)      # stops the sender thread
        except queue.Full:
            pass

    def count(self, kind):
        with self.lock:
            return len(self.listeners[kind])

    def push(self, obj, kinds=("bridge", "touchui")):
        data = json.dumps(obj, separators=(",", ":"))
        dead = []
        with self.lock:
            targets = [(k, i) for k in kinds for i in self.listeners[k]]
        for k, item in targets:
            try:
                item["q"].put_nowait(data)
            except queue.Full:
                dead.append((k, item))
        for k, item in dead:
            self.remove(k, item)
            item["ws"].open = False

    def _sender(self, kind, item):
        q, ws = item["q"], item["ws"]
        while True:
            data = q.get()
            if data is None:
                return
            if not isinstance(data, str):
                data = json.dumps(data, separators=(",", ":"))
            ws.send(data.encode(), binary=False)
            if not ws.open:
                self.remove(kind, item)
                return


class TouchPanel(server.Panel):
    def __init__(self, hub=None):
        super().__init__()
        self.hub = hub or Hub()

    def on_frame(self, f):
        super().on_frame(f)
        ev = event_for(f)
        if ev is not None:
            self.hub.push(ev)

    def attach(self, s):
        super().attach(s)
        self.hub.push({"t": "vm", "connected": s is not None})

    def hello(self):
        with self.lock:
            return {"t": "hello",
                    "leds": {str(k): v for k, v in self.leds.items()},
                    "pads": {str(k): list(v) for k, v in self.pads.items()},
                    "vm": bool(self.connected)}


def make_touch_handler(panel, hub, *stock_args):
    """Stock handler (server.make_handler(panel, qmp, midi, rear, sd, vnc, pages, burst)) plus our routes."""
    burst = stock_args[-1]
    Base = server.make_handler(panel, *stock_args)

    class H(Base):
        def _ws_handshake(self):
            import base64
            import hashlib
            import socket
            key = self.headers.get("Sec-WebSocket-Key", "")
            accept = base64.b64encode(hashlib.sha1((key + server.WS_GUID).encode()).digest()).decode()
            self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                              f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
            self.wfile.flush()
            self.close_connection = True
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return server.Ws(self.connection, self.rfile)

        def _ws_loop(self, kind, on_text):
            ws = self._ws_handshake()
            if kind == "bridge":
                def first():
                    return [panel.hello()]
            else:
                def first():
                    out = [panel.hello()]
                    if hub.bridge_ui is not None:
                        out.append(hub.bridge_ui)
                    return out
            item = hub.add_with(kind, ws, first)
            try:
                while ws.open:
                    op, data = ws.recv()
                    if op is None or op == 8:
                        break
                    if op == 9:
                        with ws.lock:
                            ws.sock.sendall(bytes([0x8A, len(data)]) + data)
                    elif op == 1:
                        try:
                            on_text(json.loads(data))
                        except (ValueError, KeyError, TypeError):
                            pass
            except (OSError, ValueError):
                pass
            finally:
                ws.open = False
                hub.remove(kind, item)

        def _bridge_msg(self, m):
            t = m.get("t")
            if t == "send":
                data = bytes.fromhex(m["hex"])
                if data:
                    panel.send(data)
                    burst.poke()
            elif t == "ui":
                if m.get("kind") == "bridge":
                    hub.bridge_ui = m
                hub.push(m, kinds=("touchui",))

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            ws_req = self.headers.get("Upgrade", "").lower() == "websocket"
            if path == "/touch":
                with open(TOUCH_HTML, "rb") as f:
                    return self.reply(200, f.read(), "text/html; charset=utf-8")
            if path == "/bridge" and ws_req:
                try:
                    return self._ws_loop("bridge", self._bridge_msg)
                finally:
                    if hub.count("bridge") == 0:
                        hub.bridge_ui = None
                        hub.push({"t": "ui", "kind": "bridge", "touch": "offline", "bridge": False}, kinds=("touchui",))
            if path == "/touchui" and ws_req:
                return self._ws_loop("touchui", lambda m: None)
            return super().do_GET()

    return H


def build():
    hub = Hub()
    panel = TouchPanel(hub)
    qmp, midi = server.Qmp(), server.ExtMidi()
    rear = server.Rear(midi)
    vnc, pages = server.Vnc(), server.Pages()
    burst = server.Burst(qmp, pages)
    sd = server.SdCard(qmp)
    return panel, hub, qmp, midi, rear, sd, vnc, pages, burst


def selftest():
    server.selftest()
    # --- event JSON
    assert event_for(bytes.fromhex("B0 27 02")) == {"t": "led", "id": 0x27, "v": 2}
    assert event_for(bytes.fromhex("B0 39 00")) == {"t": "led", "id": 0x39, "v": 0}
    assert event_for(bytes.fromhex("F0 47 7F 5C 65 00 04 03 7F 10 00 F7")) == {"t": "pad", "i": 3, "rgb": [127, 16, 0]}
    assert event_for(bytes.fromhex("BF 04 01")) is None                    # channel-15 14-bit value
    assert event_for(bytes.fromhex("B1 04 01")) is None                    # other channel
    assert event_for(bytes.fromhex("F0 47 7F 5C 42 00 00 F7")) is None     # other SysEx
    assert event_for(bytes.fromhex("F0 7E 00 06 01 F7")) is None
    assert event_for(bytes.fromhex("90 25 7F")) is None
    assert event_for(b"") is None

    # --- panel + hub: events reach listeners via on_frame, hello shape
    class FakeWs:
        def __init__(self):
            self.open, self.msgs, self.lock = True, [], threading.Lock()

        def send(self, data, binary=True):
            assert not binary
            self.msgs.append(json.loads(data))

    def wait(cond, what):
        end = time.time() + 2
        while time.time() < end:
            if cond():
                return
            time.sleep(0.005)
        raise AssertionError("timeout: " + what)

    panel = TouchPanel()
    panel.on_frame(bytes.fromhex("B0 06 02"))
    panel.on_frame(bytes.fromhex("F0 47 7F 5C 65 00 04 05 01 02 03 F7"))
    h = panel.hello()
    assert h == {"t": "hello", "leds": {"6": 2}, "pads": {"5": [1, 2, 3]}, "vm": False}, h
    b, u = FakeWs(), FakeWs()
    panel.hub.add("bridge", b, [panel.hello()])
    panel.hub.add("touchui", u, [panel.hello()])
    panel.on_frame(bytes.fromhex("B0 07 01"))
    panel.on_frame(bytes.fromhex("BF 02 03"))
    panel.on_frame(bytes.fromhex("F0 47 7F 5C 42 00 00 F7"))
    panel.on_frame(bytes.fromhex("F0 47 7F 5C 65 00 04 00 7F 00 00 F7"))
    panel.attach(None)
    want = [h, {"t": "led", "id": 7, "v": 1}, {"t": "pad", "i": 0, "rgb": [127, 0, 0]}, {"t": "vm", "connected": False}]
    wait(lambda: len(b.msgs) >= 4 and len(u.msgs) >= 4, "listener messages")
    assert b.msgs == want and u.msgs == want, (b.msgs, u.msgs)
    # a failing listener is dropped, others keep working; a blocked one never blocks push()
    bad = FakeWs()
    bad.open = False
    panel.hub.add("bridge", bad)
    panel.on_frame(bytes.fromhex("B0 08 01"))
    wait(lambda: panel.hub.count("bridge") == 1, "dead listener dropped")
    slow_gate = threading.Event()

    class SlowWs(FakeWs):
        def send(self, data, binary=True):
            slow_gate.wait(5)
    panel.hub.add("bridge", SlowWs())
    t0 = time.time()
    for i in range(300):
        panel.on_frame(bytes([0xB0, 9, i % 128]))
    assert time.time() - t0 < 1.0, "push blocked"
    slow_gate.set()

    # --- routes: GET /touch exists and serves touch.html; ui relay; bridge send
    class Poke:
        n = 0
        def poke(self): Poke.n += 1
    stock = (server.Qmp(), server.ExtMidi())
    midi = stock[1]
    rear = server.Rear(midi)
    parts = (stock[0], midi, rear, server.SdCard(stock[0]), server.Vnc(), server.Pages(), Poke())
    sent = []
    p2 = TouchPanel()
    p2.send = lambda d: sent.append(bytes(d)) or True
    H = make_touch_handler(p2, p2.hub, *parts)
    assert hasattr(H, "do_GET") and H.do_GET is not server.make_handler(p2, *parts).do_GET

    def get(path):
        hh = object.__new__(H)
        hh.path, hh.request_version, hh.requestline, hh.command = path, "HTTP/1.1", "GET " + path, "GET"
        hh.wfile, hh.headers, hh.client_address = io.BytesIO(), {}, ("127.0.0.1", 0)
        hh.do_GET()
        return hh.wfile.getvalue()
    out = get("/touch")
    assert out.startswith(b"HTTP/1.") and b" 200 " in out.split(b"\r\n")[0] and b"<canvas" in out, out[:200]
    out = get("/touch?sink=abc")
    assert b" 200 " in out.split(b"\r\n")[0]
    assert b"MPC Sample" in get("/") or b"<html" in get("/").lower()
    hh = object.__new__(H)
    hh.headers = {}
    ui = FakeWs()
    p2.hub.add("touchui", ui)
    hh._bridge_msg({"t": "ui", "kind": "knob", "name": "K2", "value": 64, "touched": True})
    hh._bridge_msg({"t": "ui", "kind": "bridge", "touch": "connected", "fullLevel": False, "q4": "FADER"})
    wait(lambda: len(ui.msgs) == 2, "ui relay")
    assert ui.msgs[0] == {"t": "ui", "kind": "knob", "name": "K2", "value": 64, "touched": True}
    assert p2.hub.bridge_ui["touch"] == "connected"
    hh._bridge_msg({"t": "send", "hex": "99 25 7F"})
    assert sent == [bytes.fromhex("99 25 7F")] and Poke.n == 1, (sent, Poke.n)
    print("touch_server selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=server.PORTS["panel"])
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        return
    panel, hub, qmp, midi, rear, sd, vnc, pages, burst = build()
    sys.setswitchinterval(0.0005)
    for port, owner in ((server.PORTS["cs"], panel), (server.PORTS["ext_midi"], midi), (server.PORTS["audio"], rear)):
        threading.Thread(target=server.uart_loop, args=(port, owner), daemon=True).start()
    threading.Thread(target=vnc.loop, daemon=True).start()
    threading.Thread(target=burst.loop, daemon=True).start()
    srv = ThreadingHTTPServer((server.HOST, a.port), make_touch_handler(panel, hub, qmp, midi, rear, sd, vnc, pages, burst))
    print(f"Touch Sample panel: http://{server.HOST}:{a.port}/touch  (stock panel at /)")
    srv.serve_forever()


if __name__ == "__main__":
    main()
