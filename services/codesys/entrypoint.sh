#!/bin/bash
# entrypoint.sh — PID 1 wrapper for CODESYS container
#
# Keeps the container alive while allowing codesyscontrol.bin
# to be started/stopped independently via:
#   /etc/init.d/codesyscontrol start|stop|status
#
# PID 1 = this script (always running)
# codesyscontrol.bin = child process (can be stopped/restarted)

set -e

EXEC=/opt/codesys/bin/codesyscontrol.bin
CFG=/etc/CODESYSControl.cfg
PIDFILE=/var/run/codesyscontrol.pid

# Trap SIGTERM/SIGINT for clean shutdown
cleanup() {
    echo "[entrypoint] Received shutdown signal — stopping CODESYS runtime..."
    if [ -f "$PIDFILE" ]; then
        kill "$(cat $PIDFILE)" 2>/dev/null || true
        sleep 2
    fi
    # Also kill by name in case pidfile is stale
    killall -q codesyscontrol.bin 2>/dev/null || true
    echo "[entrypoint] Shutdown complete"
    exit 0
}
trap cleanup SIGTERM SIGINT

# Start CODESYS runtime
echo "[entrypoint] Starting CODESYS runtime..."
/etc/init.d/codesyscontrol start

# Keep container alive — wait forever, check runtime periodically
echo "[entrypoint] Container alive, runtime managed via /etc/init.d/codesyscontrol"
while true; do
    sleep 10 &
    wait $!
done
