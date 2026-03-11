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

        # --- Interactive setup ---
        echo ""
        echo "============================================"
        echo "  Setup complete. Let's configure & test."
        echo "============================================"

        # Step 1: Notification permission
        echo ""
        echo "[1/3] Testing notification permission..."
        echo ""
        terminal-notifier \
            -title "notify-bridge" \
            -message "If you see this, notifications are working!" \
            -group "notify-bridge-test" 2>/dev/null

        echo "  A test notification was sent."
        echo ""
        echo "  If you did NOT see it, enable notifications:"
        echo "    1. Open System Settings"
        echo "    2. Go to Notifications > terminal-notifier"
        echo "    3. Toggle 'Allow Notifications' ON"
        echo "    4. Set alert style to 'Alerts' or 'Banners'"
        echo ""
        read -rp "  Did the notification appear? [Y/n] " notif_ok
        if [[ "${notif_ok,,}" == "n" ]]; then
            echo ""
            echo "  Opening System Settings > Notifications..."
            open "x-apple.systempreferences:com.apple.Notifications-Settings"
            echo ""
            echo "  Enable notifications for 'terminal-notifier', then re-run:"
            echo "    ./install.sh"
            exit 0
        fi

        # Step 2: Server host
        echo ""
        echo "[2/3] Linux server connection"
        echo ""

        CONF_DIR="$HOME/.config/notify-bridge"
        CONF_FILE="$CONF_DIR/client.conf"
        SAVED_HOST=""
        if [ -f "$CONF_FILE" ]; then
            SAVED_HOST=$(grep -E '^SERVER_HOST=' "$CONF_FILE" 2>/dev/null | cut -d= -f2)
        fi

        if [ -n "$SAVED_HOST" ]; then
            read -rp "  Server host [$SAVED_HOST]: " SERVER_HOST
            SERVER_HOST="${SERVER_HOST:-$SAVED_HOST}"
        else
            read -rp "  Server host (IP or hostname): " SERVER_HOST
        fi

        if [ -z "$SERVER_HOST" ]; then
            echo "  No host provided, skipping connection test."
            echo ""
            echo "  Run manually later:"
            echo "    notify-bridge-client <linux-host>"
            exit 0
        fi

        read -rp "  Server port [9876]: " SERVER_PORT
        SERVER_PORT="${SERVER_PORT:-9876}"

        # Save config
        mkdir -p "$CONF_DIR"
        cat > "$CONF_FILE" <<CONF
SERVER_HOST=$SERVER_HOST
SERVER_PORT=$SERVER_PORT
CONF

        # Update wrapper to use saved config
        cat > "$BIN/notify-bridge-client" <<WRAPPER
#!/bin/bash
CONF="\$HOME/.config/notify-bridge/client.conf"
if [ \$# -eq 0 ] && [ -f "\$CONF" ]; then
    HOST=\$(grep -E '^SERVER_HOST=' "\$CONF" | cut -d= -f2)
    PORT=\$(grep -E '^SERVER_PORT=' "\$CONF" | cut -d= -f2)
    exec "$VENV/bin/python3" "$SCRIPT_DIR/client.py" "\$HOST" --port "\${PORT:-9876}" "\$@"
else
    exec "$VENV/bin/python3" "$SCRIPT_DIR/client.py" "\$@"
fi
WRAPPER
        chmod +x "$BIN/notify-bridge-client"

        # Step 3: Test connection
        echo ""
        echo "[3/3] Testing connection to $SERVER_HOST:$SERVER_PORT..."
        echo ""

        if "$VENV/bin/python3" -c "
import asyncio, sys
async def test():
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection('$SERVER_HOST', $SERVER_PORT), timeout=5)
        writer.close()
        await writer.wait_closed()
        print('  Connection: OK')
        return True
    except Exception as e:
        print(f'  Connection: FAILED ({e})')
        return False
sys.exit(0 if asyncio.run(test()) else 1)
" 2>/dev/null; then
            echo ""
            echo "============================================"
            echo "  All good! Start the client with:"
            echo ""
            echo "    notify-bridge-client"
            echo ""
            echo "============================================"
        else
            echo ""
            echo "  Could not reach $SERVER_HOST:$SERVER_PORT"
            echo ""
            echo "  Make sure the Linux server is running:"
            echo "    notify-bridge          # or"
            echo "    systemctl --user start notify-bridge"
            echo ""
            echo "  And port $SERVER_PORT is open (firewall)."
            echo ""
            echo "  Once the server is up, run:"
            echo "    notify-bridge-client"
        fi

        echo ""
        echo "Make sure ~/.local/bin is in PATH:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;

    *)
        echo "Unsupported: $(uname)" && exit 1
        ;;
esac
