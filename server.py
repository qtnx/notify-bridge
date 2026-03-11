#!/usr/bin/env python3
"""notify-bridge server: forward Linux desktop notifications via WebSocket.

Monitors D-Bus Notify calls and broadcasts to all connected WebSocket
clients. Also accepts notifications from any WebSocket client or CLI
and relays them to all other clients.

Usage:
    notify-bridge                          # start server
    notify-bridge send "Title" "Message"   # send from shell / scripts
"""

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
import threading

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

log = logging.getLogger("notify-bridge")

# --- WebSocket server ---

_loop: asyncio.AbstractEventLoop | None = None
_clients: dict[asyncio.Queue, str] = {}  # queue -> client name
_lock = threading.Lock()


def broadcast(data: dict) -> None:
    """Thread-safe broadcast to all WebSocket clients."""
    if not _loop or not _clients:
        return
    payload = json.dumps(data, ensure_ascii=False)
    with _lock:
        for q in _clients:
            _loop.call_soon_threadsafe(q.put_nowait, payload)


async def ws_handler(websocket):
    """Handle a single WebSocket client connection."""
    peer = websocket.remote_address
    client_name = f"{peer[0]}:{peer[1]}"
    client_queue: asyncio.Queue = asyncio.Queue()

    with _lock:
        _clients[client_queue] = client_name
    log.info("Client connected: %s (%d total)", client_name, len(_clients))

    try:
        send_task = asyncio.create_task(_ws_sender(websocket, client_queue))
        recv_task = asyncio.create_task(_ws_receiver(websocket, client_queue))
        done, pending = await asyncio.wait(
            [send_task, recv_task], return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
    finally:
        with _lock:
            _clients.pop(client_queue, None)
        log.info("Client disconnected: %s (%d remaining)", client_name, len(_clients))


async def _ws_sender(websocket, queue: asyncio.Queue):
    """Send notifications and keepalives to a client."""
    try:
        while True:
            try:
                payload = await asyncio.wait_for(queue.get(), timeout=30)
                await websocket.send(payload)
            except asyncio.TimeoutError:
                await websocket.ping()
    except ConnectionClosed:
        return


async def _ws_receiver(websocket, queue: asyncio.Queue):
    """Receive messages from client (registration or notification relay)."""
    async for msg in websocket:
        try:
            data = json.loads(msg)
        except (json.JSONDecodeError, AttributeError):
            continue

        msg_type = data.get("type")

        if msg_type == "register":
            name = data.get("name", "unknown")
            with _lock:
                _clients[queue] = name
            log.info("Client registered as: %s", name)

        elif msg_type == "notification":
            app = data.get("app", "notify-bridge")
            summary = data.get("summary", "")
            log.info("[%s] %s (via client)", app, summary)
            broadcast(data)


async def run_server(host: str, port: int):
    """Run WebSocket server."""
    async with serve(ws_handler, host, port):
        log.info("WebSocket server on ws://%s:%d", host, port)
        await asyncio.get_event_loop().create_future()  # run forever


def start_server_thread(host: str, port: int):
    """Start WebSocket server in background thread."""
    global _loop
    _loop = asyncio.new_event_loop()

    def run():
        asyncio.set_event_loop(_loop)
        _loop.run_until_complete(run_server(host, port))

    t = threading.Thread(target=run, daemon=True)
    t.start()


# --- D-Bus monitor ---


def start_dbus_monitor(excluded_apps: set[str]):
    """Monitor D-Bus notifications (blocks on GLib mainloop)."""
    DBusGMainLoop(set_as_default=True)

    bus_address = os.environ.get("DBUS_SESSION_BUS_ADDRESS")
    if not bus_address:
        log.error("DBUS_SESSION_BUS_ADDRESS not set")
        sys.exit(1)

    conn = dbus.bus.BusConnection(bus_address)

    match_rule = (
        "type='method_call',"
        "interface='org.freedesktop.Notifications',"
        "member='Notify'"
    )

    try:
        proxy = conn.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus")
        iface = dbus.Interface(proxy, "org.freedesktop.DBus.Monitoring")
        iface.BecomeMonitor(
            dbus.Array([match_rule], signature="s"),
            dbus.UInt32(0),
        )
        log.info("D-Bus: BecomeMonitor")
    except dbus.exceptions.DBusException as e:
        log.info("BecomeMonitor unavailable (%s), using eavesdrop", e)
        conn.add_match_string_non_blocking(match_rule + ",eavesdrop='true'")
        log.info("D-Bus: eavesdrop")

    def on_message(_conn, msg):
        if (
            msg.get_member() != "Notify"
            or msg.get_interface() != "org.freedesktop.Notifications"
        ):
            return
        try:
            args = msg.get_args_list()
            if len(args) < 5:
                return
            app_name = str(args[0]) or "Unknown"
            summary = str(args[3])
            body = str(args[4])

            if app_name in excluded_apps:
                return

            log.info("[%s] %s", app_name, summary)
            broadcast({
                "type": "notification",
                "app": app_name,
                "summary": summary,
                "body": body,
            })
        except Exception:
            log.exception("Error processing notification")

    conn.add_message_filter(on_message)

    loop = GLib.MainLoop()

    def shutdown(_sig, _frame):
        log.info("Shutting down...")
        loop.quit()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    log.info("Listening for notifications...")
    loop.run()


# --- CLI send ---


async def _send_one(host: str, port: int, app: str, summary: str, body: str):
    """Connect to local server, send one notification, disconnect."""
    from websockets.asyncio.client import connect

    url = f"ws://{host}:{port}"
    async with connect(url, open_timeout=5, close_timeout=2) as ws:
        await ws.send(json.dumps({
            "type": "notification",
            "app": app,
            "summary": summary,
            "body": body,
        }))


# --- CLI ---


def main():
    parser = argparse.ArgumentParser(
        prog="notify-bridge",
        description="Bridge Linux desktop notifications to remote machines via WebSocket",
    )
    parser.add_argument("-v", "--verbose", action="store_true")

    sub = parser.add_subparsers(dest="command")

    # serve (default when no subcommand given)
    sp_serve = sub.add_parser("serve", help="Start notification server")
    sp_serve.add_argument(
        "--listen", default=os.environ.get("NOTIFY_LISTEN", "0.0.0.0"),
    )
    sp_serve.add_argument(
        "--port", type=int, default=int(os.environ.get("NOTIFY_PORT", "9876")),
    )
    sp_serve.add_argument(
        "--exclude", default=os.environ.get("NOTIFY_EXCLUDE", ""),
    )

    # send
    sp_send = sub.add_parser("send", help="Send a notification to connected clients")
    sp_send.add_argument("title", help="Notification title / summary")
    sp_send.add_argument("body", nargs="?", default="", help="Notification body")
    sp_send.add_argument("--app", default="notify-bridge", help="App name")
    sp_send.add_argument("--server", default="127.0.0.1")
    sp_send.add_argument(
        "--port", type=int, default=int(os.environ.get("NOTIFY_PORT", "9876")),
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    if args.command == "send":
        asyncio.run(_send_one(
            args.server, args.port, args.app, args.title, args.body,
        ))
        log.info("Sent: [%s] %s", args.app, args.title)

    else:
        # Default to serve
        listen = getattr(args, "listen", os.environ.get("NOTIFY_LISTEN", "0.0.0.0"))
        port = getattr(args, "port", int(os.environ.get("NOTIFY_PORT", "9876")))
        exclude = getattr(args, "exclude", os.environ.get("NOTIFY_EXCLUDE", ""))
        excluded = set(filter(None, exclude.split(",")))

        start_server_thread(listen, port)
        start_dbus_monitor(excluded)


if __name__ == "__main__":
    main()
