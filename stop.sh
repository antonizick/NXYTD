#!/usr/bin/env bash
set -euo pipefail

PORT=8888
PID_FILE="$(dirname "$0")/.uvicorn.pid"

# Try kill, escalate to sudo if permission denied
try_kill() {
    local sig=$1
    local pid=$2
    if kill "-${sig}" "$pid" 2>/dev/null; then
        return 0
    fi
    # Permission denied — escalate
    echo "  Permission denied for PID $pid — escalating to sudo..."
    sudo kill "-${sig}" "$pid" 2>/dev/null && return 0
    return 1
}

stop_pid() {
    local pid=$1
    if ! kill -0 "$pid" 2>/dev/null && ! sudo kill -0 "$pid" 2>/dev/null; then
        echo "PID $pid is not running."
        return 0
    fi

    echo "Stopping PID $pid..."
    try_kill TERM "$pid" || true

    # Wait up to 5 seconds for graceful shutdown
    for i in {1..5}; do
        if ! kill -0 "$pid" 2>/dev/null && ! sudo kill -0 "$pid" 2>/dev/null; then
            echo "  Stopped."
            return 0
        fi
        sleep 1
    done

    echo "  Did not stop gracefully — sending SIGKILL..."
    if try_kill KILL "$pid"; then
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null && ! sudo kill -0 "$pid" 2>/dev/null; then
            echo "  Killed."
            return 0
        fi
    fi

    echo "  Failed to kill PID $pid. You may need to investigate manually."
    return 1
}

# Get all PIDs listening on the port (may include parent + worker)
get_port_pids() {
    ss -tlnp | grep ":${PORT} " | grep -oP 'pid=\K[0-9]+' | sort -u || true
}

# Stop via PID file if present
if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    stop_pid "$PID"
    rm -f "$PID_FILE"
    # Also clean up any remaining workers that shared the port
    REMAINING=$(get_port_pids)
    for RPID in $REMAINING; do
        [[ "$RPID" != "$PID" ]] && stop_pid "$RPID"
    done
    exit 0
fi

# Fallback: find by port
echo "No PID file found — searching for process on port $PORT..."
PIDS=$(get_port_pids)

if [[ -z "$PIDS" ]]; then
    echo "Nothing is running on port $PORT."
    exit 0
fi

for PID in $PIDS; do
    stop_pid "$PID"
done
