# -*- coding: utf-8 -*-
"""
MT5 Live Bridge Server (Python - Zero Dependencies)
Compatible with Railway, Heroku, Render, and Localhost
"""

import http.server
import socketserver
import threading
import json
import time
import hashlib
import base64
import struct
import os
import urllib.parse

PORT = int(os.environ.get('PORT', 8080))

MIME_TYPES = {
    '.html': 'text/html; charset=UTF-8',
    '.js': 'text/javascript; charset=UTF-8',
    '.css': 'text/css; charset=UTF-8',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.mq5': 'text/plain; charset=UTF-8'
}

# In-Memory Data Store (M5: 900 candles, M15: 300 candles)
state = {
    "candlesM5": [],
    "candlesM15": [],
    "currentBid": 0.0,
    "currentAsk": 0.0,
    "symbol": "XAUUSD",
    "lastMt5Time": 0,
    "isConnectedToMT5": False
}

ws_clients = set()
clients_lock = threading.Lock()

def get_ws_accept_header(key):
    guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    sha1 = hashlib.sha1((key.strip() + guid).encode('utf-8')).digest()
    return base64.b64encode(sha1).decode('utf-8')

def frame_ws_message(data_dict):
    json_str = json.dumps(data_dict)
    payload = json_str.encode('utf-8')
    length = len(payload)

    if length <= 125:
        header = bytes([0x81, length])
    elif length <= 65535:
        header = bytes([0x81, 126]) + struct.pack("!H", length)
    else:
        header = bytes([0x81, 127]) + struct.pack("!Q", length)
    return header + payload

def broadcast(data_dict):
    frame = frame_ws_message(data_dict)
    with clients_lock:
        to_remove = set()
        for client in ws_clients:
            try:
                client.sendall(frame)
            except Exception:
                to_remove.add(client)
        for c in to_remove:
            ws_clients.remove(c)

class CombinedHandler(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        req_path = urllib.parse.unquote(self.path.split('?')[0])
        if req_path == '/':
            req_path = '/index.html'

        safe_path = req_path.lstrip('/')
        file_path = os.path.join(os.getcwd(), safe_path)

        if os.path.exists(file_path) and os.path.isfile(file_path):
            _, ext = os.path.splitext(file_path)
            content_type = MIME_TYPES.get(ext.lower(), 'application/octet-stream')
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            with open(file_path, 'rb') as f:
                self.wfile.write(f.read())
            return
        
        self.send_response(404)
        self.send_header('Content-Type', 'text/plain; charset=UTF-8')
        self.end_headers()
        self.wfile.write(b'404 Not Found')

    def do_POST(self):
        if self.path == '/api/mt5-data':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')
            
            try:
                payload = json.loads(body)
                handle_mt5_payload(payload)
                
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                res = json.dumps({"status": "ok", "clients": len(ws_clients)}).encode('utf-8')
                self.wfile.write(res)
            except Exception as e:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                res = json.dumps({"status": "error", "message": str(e)}).encode('utf-8')
                self.wfile.write(res)
            return

        self.send_response(404)
        self.end_headers()

    def handle(self):
        raw_req = self.rfile.readline(65537)
        if not raw_req:
            return

        req_line = raw_req.decode('iso-8859-1').strip()
        headers = {}
        while True:
            line = self.rfile.readline(65537).decode('iso-8859-1').strip()
            if not line:
                break
            if ':' in line:
                k, v = line.split(':', 1)
                headers[k.strip().lower()] = v.strip()

        if headers.get('upgrade', '').lower() == 'websocket':
            key = headers.get('sec-websocket-key')
            if key:
                accept_key = get_ws_accept_header(key)
                resp = (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept_key}\r\n\r\n"
                )
                self.wfile.write(resp.encode('utf-8'))
                self.wfile.flush()

                sock = self.connection
                with clients_lock:
                    ws_clients.add(sock)
                print(f"[WebSocket] Client connected. Total clients: {len(ws_clients)}")

                init_msg = frame_ws_message({
                    "type": "initial",
                    "symbol": state["symbol"],
                    "currentBid": state["currentBid"],
                    "currentAsk": state["currentAsk"],
                    "candlesM5": state["candlesM5"],
                    "candlesM15": state["candlesM15"],
                    "mt5Connected": state["isConnectedToMT5"]
                })
                try:
                    sock.sendall(init_msg)
                except Exception:
                    pass

                try:
                    while True:
                        data = sock.recv(1024)
                        if not data:
                            break
                except Exception:
                    pass
                finally:
                    with clients_lock:
                        if sock in ws_clients:
                            ws_clients.remove(sock)
                    print(f"[WebSocket] Client disconnected. Remaining: {len(ws_clients)}")
                return

        parts = req_line.split()
        if len(parts) >= 2:
            self.command = parts[0]
            self.path = parts[1]
            self.headers = headers
            if self.command == 'GET':
                self.do_GET()
            elif self.command == 'POST':
                self.do_POST()
            elif self.command == 'OPTIONS':
                self.do_OPTIONS()

def handle_mt5_payload(payload):
    state["lastMt5Time"] = time.time()
    
    if not state["isConnectedToMT5"]:
        state["isConnectedToMT5"] = True
        print("[MT5] ✅ Connected to MetaTrader 5 EA!")
        broadcast({"type": "status", "mt5Connected": True})

    action = payload.get("action")

    if action == "initial":
        if isinstance(payload.get("candlesM5"), list):
            state["candlesM5"] = payload["candlesM5"][-900:]
        if isinstance(payload.get("candlesM15"), list):
            state["candlesM15"] = payload["candlesM15"][-300:]

        state["currentBid"] = payload.get("currentBid", state["currentBid"])
        state["currentAsk"] = payload.get("currentAsk", state["currentAsk"])
        state["symbol"] = payload.get("symbol", "XAUUSD")

        print(f"[MT5] 🚀 Received Initial Snapshot: {len(state['candlesM5'])} M5 candles & {len(state['candlesM15'])} M15 candles.")

        broadcast({
            "type": "initial",
            "symbol": state["symbol"],
            "currentBid": state["currentBid"],
            "currentAsk": state["currentAsk"],
            "candlesM5": state["candlesM5"],
            "candlesM15": state["candlesM15"],
            "mt5Connected": True
        })
    elif action == "tick":
        state["currentBid"] = payload.get("currentBid", state["currentBid"])
        state["currentAsk"] = payload.get("currentAsk", state["currentAsk"])
        
        tf = payload.get("timeframe", "M5")
        candle = payload.get("candle")

        if tf == "M5" and len(state["candlesM5"]) > 0 and candle:
            state["candlesM5"][-1] = candle
        elif tf == "M15" and len(state["candlesM15"]) > 0 and candle:
            state["candlesM15"][-1] = candle

        broadcast({
            "type": "tick",
            "timeframe": tf,
            "currentBid": state["currentBid"],
            "currentAsk": state["currentAsk"],
            "candle": candle,
            "mt5Connected": True
        })
    elif action == "candle_close":
        tf = payload.get("timeframe", "M5")
        new_candle = payload.get("newCandle")
        closed_candle = payload.get("closedCandle")

        if tf == "M5":
            if closed_candle and len(state["candlesM5"]) > 0:
                state["candlesM5"][-1] = closed_candle
            if new_candle:
                state["candlesM5"].append(new_candle)
                if len(state["candlesM5"]) > 900:
                    state["candlesM5"].pop(0)
        elif tf == "M15":
            if closed_candle and len(state["candlesM15"]) > 0:
                state["candlesM15"][-1] = closed_candle
            if new_candle:
                state["candlesM15"].append(new_candle)
                if len(state["candlesM15"]) > 300:
                    state["candlesM15"].pop(0)

        print(f"[MT5] 🕯️ Candle Closed on {tf}")
        broadcast({
            "type": "candle_close",
            "timeframe": tf,
            "closedCandle": closed_candle,
            "newCandle": new_candle,
            "currentBid": state["currentBid"],
            "currentAsk": state["currentAsk"],
            "mt5Connected": True
        })

def heartbeat_monitor():
    while True:
        time.sleep(3)
        if state["isConnectedToMT5"] and (time.time() - state["lastMt5Time"] > 6.0):
            state["isConnectedToMT5"] = False
            print("[MT5] ⚠️ Connection to MetaTrader 5 EA timed out.")
            broadcast({"type": "status", "mt5Connected": False})

if __name__ == '__main__':
    t = threading.Thread(target=heartbeat_monitor, daemon=True)
    t.start()

    class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server = ThreadedHTTPServer(('0.0.0.0', PORT), CombinedHandler)
    print("====================================================")
    print(f"🚀 MT5 Live Python Bridge running on port {PORT}")
    print("====================================================")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server...")
