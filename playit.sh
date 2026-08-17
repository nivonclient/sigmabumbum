#!/bin/bash
set -uo pipefail

cd "$(dirname "$0")" || exit 1

PLAYIT_DIR=".playit"
SOCKET="$PLAYIT_DIR/playitd.sock"
SECRET="$PLAYIT_DIR/playit.toml"
PLAYITD_PID=""

# --- sanity checks -----------------------------------------------------
for bin in playitd playit; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in PATH." >&2
        exit 1
    fi
done

mkdir -p "$PLAYIT_DIR"

# --- cleanup: runs on normal exit, Ctrl+C, or kill ----------------------
cleanup() {
    if [ -n "$PLAYITD_PID" ] && kill -0 "$PLAYITD_PID" 2>/dev/null; then
        echo ""
        echo "Stopping Playit daemon (pid $PLAYITD_PID)..."
        kill "$PLAYITD_PID" 2>/dev/null
        # give it a moment, then force if it won't die
        for _ in {1..10}; do
            kill -0 "$PLAYITD_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -0 "$PLAYITD_PID" 2>/dev/null && kill -9 "$PLAYITD_PID" 2>/dev/null
        wait "$PLAYITD_PID" 2>/dev/null
    fi
    [ -S "$SOCKET" ] && rm -f "$SOCKET"
}
trap cleanup EXIT INT TERM

echo "============================================"
echo "  Starting Playit Agent"
echo "  Data:   $PLAYIT_DIR"
echo "  Socket: $SOCKET"
echo "============================================"

# stale socket from a previous crashed run will block bind
[ -S "$SOCKET" ] && rm -f "$SOCKET"

playitd \
    --socket-path "$SOCKET" \
    --secret-path "$SECRET" &
PLAYITD_PID=$!

echo "Waiting for Playit daemon..."
for _ in {1..30}; do
    [ -S "$SOCKET" ] && break
    if ! kill -0 "$PLAYITD_PID" 2>/dev/null; then
        echo "Playit daemon stopped unexpectedly." >&2
        exit 1
    fi
    sleep 1
done

if [ ! -S "$SOCKET" ]; then
    echo "Timed out waiting for Playit socket." >&2
    exit 1
fi

echo "Playit daemon is ready."
echo ""

playit --socket-path "$SOCKET"
# cleanup trap handles killing playitd on exit