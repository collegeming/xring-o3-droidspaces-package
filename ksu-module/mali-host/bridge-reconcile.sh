#!/system/bin/sh
# One reconciliation pass: every running Droidspaces container must have its
# own MaliBridge server; bridges whose container is gone are stopped.
#
# Containers are independent: two or more may run at the same time, each with
# its own vkbridge-server and its own rootfs socket. Nothing here is limited to
# a single "current" container.
set -u
DS=${DROIDSPACES_BIN:-/data/local/tmp/droidspaces}
LOG=${WATCH_LOG:-/data/local/tmp/xring-o3-mali-watch.log}

log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

sock_live() {
    [ -S "$1" ] || return 1
    [ -r /proc/net/unix ] || return 0
    awk -v p="$1" '$NF == p { f = 1 } END { exit f ? 0 : 1 }' /proc/net/unix
}

[ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && : >"$LOG"

JSON=$("$DS" show --json 2>/dev/null)
for R in /data/local/Droidspaces/Containers/*/rootfs; do
    [ -d "$R" ] || continue
    HOST=$(dirname "$R")/host
    CTR=$(basename "$(dirname "$R")")
    [ -f "$HOST/start-bridge.sh" ] || continue
    [ -x "$HOST/mbsrv/vkbridge-server" ] || continue
    SOCK="$R/opt/mb-sock/mali.sock"
    case "$JSON" in
        *"\"name\":\"$CTR\""*)
            PID=$(cat "$HOST/server.pid" 2>/dev/null | tr -d '\r\n')
            if [ -n "${PID:-}" ] && [ -d "/proc/$PID" ] && sock_live "$SOCK"; then
                continue
            fi
            log "start bridge: $CTR"
            SRV="$HOST" sh "$HOST/start-bridge.sh" >>"$LOG" 2>&1
            ;;
        *)
            if [ -f "$HOST/server.pid" ]; then
                log "stop bridge (container not running): $CTR"
                SRV="$HOST" sh "$HOST/stop-bridge.sh" >>"$LOG" 2>&1
            fi
            ;;
    esac
done
