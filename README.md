# notify-bridge

Bridge desktop notifications from a Linux machine to macOS clients over WebSocket.

Get notified on your Mac when Claude Code finishes a task, a build completes, or any desktop notification fires on your remote Linux dev server.

## How It Works

```
Linux Server                          macOS Client(s)

┌──────────────────────┐
│  D-Bus Monitor       │              ┌─────────────────────┐
│  (all desktop notifs)├──┐      ws://│  terminal-notifier   │
└──────────────────────┘  │     ┌─────┤  (native alerts)     │
                          ▼     │     └─────────────────────┘
┌──────────────────────┐  │     │
│  WebSocket Server    ├──┴─────┤     ┌─────────────────────┐
│  :9876               │        └─────┤  Another Mac...      │
└──────────────────────┘              └─────────────────────┘
        ▲
        │
┌───────┴──────────────┐
│  notify-bridge send  │
│  (CLI / scripts)     │
└──────────────────────┘
```

- **Server** runs on Linux, captures all D-Bus notifications and exposes a WebSocket endpoint
- **Clients** connect from macOS (or anywhere), receive notifications in real time
- **CLI send** lets any script or tool push notifications to all connected clients
- Multiple clients supported simultaneously
- Auto-reconnect on disconnect

## Use Cases

- **Remote development** — SSH into a Linux server, get notifications on your Mac
- **AI coding agents** — Know when Claude Code, Codex, or Copilot finishes a task
- **CI/CD & builds** — `make build && notify-bridge send "Build Done"`
- **Long-running jobs** — Training, deploys, test suites — never miss when they complete
- **Multi-monitor** — Notifications on your laptop while working on an external display

## Quick Start

### Linux (server)

```bash
git clone https://github.com/qtnx/notify-bridge.git
cd notify-bridge
./install.sh

# Start manually
notify-bridge

# Or enable as systemd service
systemctl --user enable --now notify-bridge
```

**Dependencies:** Python 3.10+, `dbus-python`, `PyGObject`, `websockets` (all available via system package manager on Arch/Ubuntu/Fedora).

### macOS (client)

```bash
git clone https://github.com/qtnx/notify-bridge.git
cd notify-bridge
./install.sh   # installs terminal-notifier + sets up venv

# Connect to your Linux server
notify-bridge-client <linux-ip>
```

No `sudo` required. Everything installs to `~/.local/`.

## CLI: Send Notifications from Scripts

Push notifications from shell scripts, CI hooks, or coding agents:

```bash
# Basic usage
notify-bridge send "Build Complete" "All 142 tests passed"

# With custom app name
notify-bridge send "Deploy Done" "v2.1.0 is live" --app "deploy-bot"

# Chain with any command
cargo build --release && notify-bridge send "Rust Build" "Release build finished"

# Notify when an AI agent completes
claude -p "implement auth module" && notify-bridge send "Claude Code" "Task finished"
```

## Configuration

Server config at `~/.config/notify-bridge/config.env`:

```bash
NOTIFY_LISTEN=0.0.0.0   # bind address
NOTIFY_PORT=9876         # WebSocket port
NOTIFY_EXCLUDE=          # comma-separated app names to ignore
```

## Protocol

Simple JSON over WebSocket:

```json
// Server → Client: notification
{"type": "notification", "app": "Firefox", "summary": "Download Complete", "body": "file.zip"}

// Client → Server: register
{"type": "register", "name": "MacBook-Pro"}

// Any client → Server: send notification (relayed to all clients)
{"type": "notification", "app": "my-script", "summary": "Done", "body": ""}
```

## Architecture

| Component | Tech | Role |
|-----------|------|------|
| D-Bus monitor | `dbus-python` + GLib | Captures `org.freedesktop.Notifications.Notify` calls via `BecomeMonitor` (dbus-broker) or eavesdrop (dbus-daemon) |
| WebSocket server | `websockets` + asyncio | Broadcasts to all connected clients, relays client-sent notifications |
| macOS client | `websockets` + `terminal-notifier` | Connects, receives, displays native macOS notifications |
| CLI send | `websockets` client | One-shot connect → send → disconnect |

## Requirements

### Linux (server)
- Python 3.10+
- `dbus-python` — D-Bus bindings
- `PyGObject` (gi) — GLib mainloop
- `websockets` — WebSocket server/client

### macOS (client)
- Python 3.10+
- `websockets` — installed in venv by `install.sh`
- `terminal-notifier` — native macOS notifications (installed via Homebrew by `install.sh`)

## License

MIT
