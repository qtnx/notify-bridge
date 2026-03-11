#!/usr/bin/env python3
"""macOS notification client - connects to Linux WebSocket server.

Receives desktop notifications from Linux and displays them
natively on macOS. Auto-detects terminal-notifier or osascript.

Setup:
    brew install terminal-notifier
    pip3 install websockets

Run:
    python3 notify-client.py <linux-host>
"""

import argparse
import asyncio
import json
import logging
import platform
import shutil
import subprocess
import sys

log = logging.getLogger("notify-client")


def _find_notifier():
    """Detect best available notification backend."""
    if shutil.which("terminal-notifier"):
        return "terminal-notifier"
    if shutil.which("osascript"):
        return "osascript"
    return None


_BACKEND = _find_notifier()


def display_notification(app: str, summary: str, body: str) -> None:
    """Display notification using best available backend."""
    if not _BACKEND:
        log.warning("No notification backend found")
        return

    text = body or summary
    if not text:
        return

    if _BACKEND == "terminal-notifier":
        cmd = [
            "terminal-notifier",
            "-title", app or "Linux",
            "-subtitle", summary,
            "-message", body or summary,
            "-group", app or "linux-notify",
        ]
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        # osascript fallback
        def esc(s: str) -> str:
            return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").strip()[:200]

        title = esc(app or "Linux")
        subtitle = esc(summary)
        body_text = esc(body)

        if body_text:
            script = (
                f'display notification "{body_text}" '
                f'with title "{title}" subtitle "{subtitle}"'
            )
        else:
            script = f'display notification "{subtitle}" with title "{title}"'

        subprocess.Popen(
            ["osascript", "-e", script],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


async def listen(url: str, name: str) -> None:
    """Connect to WebSocket server and process notifications."""
    from websockets.asyncio.client import connect

    async for ws in connect(url, open_timeout=10):
        try:
            log.info("Connected to %s", url)

            await ws.send(json.dumps({
                "type": "register",
                "name": name,
            }))

            async for msg in ws:
                try:
                    data = json.loads(msg)
                except json.JSONDecodeError:
                    continue

                if data.get("type") != "notification":
                    continue

                app = data.get("app", "Unknown")
                summary = data.get("summary", "")
                body = data.get("body", "")

                log.info("[%s] %s", app, summary)
                display_notification(app, summary, body)

        except Exception as e:
            log.warning("Disconnected (%s), reconnecting...", e)


def main():
    parser = argparse.ArgumentParser(
        description="Receive Linux notifications via WebSocket",
    )
    parser.add_argument("host", help="Linux server host")
    parser.add_argument(
        "--port", type=int, default=9876,
        help="WebSocket port (default: 9876)",
    )
    parser.add_argument(
        "--name", default=platform.node(),
        help="Client name (default: hostname)",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    log.info("Backend: %s", _BACKEND or "none")
    url = f"ws://{args.host}:{args.port}"
    log.info("%s -> %s", args.name, url)

    try:
        asyncio.run(listen(url, args.name))
    except KeyboardInterrupt:
        log.info("Bye!")


if __name__ == "__main__":
    main()
