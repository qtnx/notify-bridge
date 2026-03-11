#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$(uname)" in
    Linux)
        BIN="$HOME/.local/bin"
        CONF="$HOME/.config/notify-bridge"
        SVC="$HOME/.config/systemd/user"

        mkdir -p "$BIN" "$CONF" "$SVC"
        cp "$SCRIPT_DIR/server.py" "$BIN/notify-bridge"
        chmod +x "$BIN/notify-bridge"

        [ -f "$CONF/config.env" ] || cp "$SCRIPT_DIR/config.env" "$CONF/config.env"

        cp "$SCRIPT_DIR/notify-bridge.service" "$SVC/notify-bridge.service"
        systemctl --user daemon-reload

        echo "Installed. Enable with:"
        echo "  systemctl --user enable --now notify-bridge"
        ;;

    Darwin)
        VENV="$HOME/.local/share/notify-bridge/venv"
        BIN="$HOME/.local/bin"

        echo "Checking dependencies..."

        if ! command -v brew &>/dev/null; then
            echo "  brew: NOT FOUND (install from https://brew.sh)"
            exit 1
        fi

        if command -v terminal-notifier &>/dev/null; then
            echo "  terminal-notifier: OK"
        else
            echo "  Installing terminal-notifier..."
            brew install terminal-notifier
        fi

        # Find a Python with working SSL (Homebrew > system)
        PYTHON=""
        for candidate in \
            "$(brew --prefix 2>/dev/null)/bin/python3" \
            "$(brew --prefix python 2>/dev/null)/libexec/bin/python" \
            /usr/bin/python3; do
            if [ -x "$candidate" ] && "$candidate" -c "import ssl" 2>/dev/null; then
                PYTHON="$candidate"
                break
            fi
        done

        if [ -z "$PYTHON" ]; then
            echo "  No Python with SSL found. Installing via Homebrew..."
            brew install python
            PYTHON="$(brew --prefix)/bin/python3"
        fi
        echo "  python: $PYTHON"

        # Create venv and install websockets
        if [ ! -d "$VENV" ]; then
            echo "  Creating virtualenv..."
            "$PYTHON" -m venv "$VENV"
        fi
        "$VENV/bin/pip" install -q websockets
        echo "  websockets: OK"

        mkdir -p "$BIN"
        cat > "$BIN/notify-bridge-client" <<WRAPPER
#!/bin/bash
exec "$VENV/bin/python3" "$SCRIPT_DIR/client.py" "\$@"
WRAPPER
        chmod +x "$BIN/notify-bridge-client"

        echo ""
        echo "Installed. Run with:"
        echo "  notify-bridge-client <linux-host>"
        echo ""
        echo "Make sure ~/.local/bin is in PATH:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;

    *)
        echo "Unsupported: $(uname)" && exit 1
        ;;
esac
