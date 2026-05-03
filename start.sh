#!/usr/bin/env bash
set -euo pipefail

PORT=8888
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/.uvicorn.pid"
LOG_FILE="$SCRIPT_DIR/uvicorn.log"

# Source stop logic inline so start.sh has no dependency on stop.sh path
stop_existing() {
    local pids
    pids=$(ss -tlnp | grep ":${PORT} " | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    [[ -z "$pids" ]] && return 0

    for pid in $pids; do
        echo "  Stopping PID $pid..."
        if ! kill -TERM "$pid" 2>/dev/null; then
            echo "  Permission denied — escalating to sudo..."
            sudo kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    # Wait up to 5s for them to exit
    for i in {1..5}; do
        local still_up=0
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && still_up=1 || sudo kill -0 "$pid" 2>/dev/null && still_up=1 || true
        done
        [[ $still_up -eq 0 ]] && { echo "  Stopped."; rm -f "$PID_FILE"; return 0; }
        sleep 1
    done

    echo "  Graceful stop timed out — sending SIGKILL..."
    for pid in $pids; do
        kill -KILL "$pid" 2>/dev/null || sudo kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 1
    rm -f "$PID_FILE"
}

# Check if already running via PID file
if [[ -f "$PID_FILE" ]]; then
    EXISTING_PID=$(cat "$PID_FILE")
    if kill -0 "$EXISTING_PID" 2>/dev/null; then
        echo "Service is already running (PID $EXISTING_PID)."
        read -rp "Stop it and restart? [y/N] " answer
        if [[ "${answer,,}" == "y" ]]; then
            stop_existing
        else
            echo "Aborted."
            exit 1
        fi
    else
        echo "Stale PID file found — removing."
        rm -f "$PID_FILE"
    fi
fi

# Check if port is in use by something else
if ss -tlnp | grep -q ":${PORT} "; then
    echo "Port $PORT is already in use:"
    ss -tlnp | grep ":${PORT} "
    read -rp "Stop the existing process and start fresh? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
        stop_existing
    else
        echo "Aborted."
        exit 1
    fi
fi

# Verify uvicorn is available
if ! command -v uvicorn &>/dev/null; then
    echo "uvicorn not found. Run: pip install -r requirements.txt"
    exit 1
fi

# Verify main.py exists
if [[ ! -f "$SCRIPT_DIR/main.py" ]]; then
    echo "main.py not found in $SCRIPT_DIR"
    exit 1
fi

echo "Starting nxytdl on port $PORT..."
cd "$SCRIPT_DIR"
nohup uvicorn main:app --host 0.0.0.0 --port "$PORT" >> "$LOG_FILE" 2>&1 &
BGPID=$!
echo "$BGPID" > "$PID_FILE"

# Give it a moment to confirm it started
sleep 1
if kill -0 "$BGPID" 2>/dev/null; then
    echo "Started (PID $BGPID). Logs: $LOG_FILE"
else
    echo "Process exited immediately. Check $LOG_FILE for details."
    rm -f "$PID_FILE"
    tail -n 20 "$LOG_FILE"
    exit 1
fi
