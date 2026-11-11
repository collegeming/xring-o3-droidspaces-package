#!/system/bin/sh
# One reconciliation pass: every running Droidspaces container must have its
# own MaliBridge server; bridges whose container is gone are stopped.
# Also refreshes the Anland display aliases, because every container start
# creates a new anland-<hash>.sock. If the latest alias points at a dead
# socket, the Anland app loops reconnecting and repeatedly flips
# Gold_Keyboardremaps' anland-profile request, which makes fn-remap re-grab
# the keyboard (laggy input, Caps Lock OSD spam). Fall back to a live container.
set -u
DS=${DROIDSPACES_BIN:-/data/local/tmp/droidspaces}
LOG=${WATCH_LOG:-/data/local/tmp/xring-o3-mali-watch.log}
LATEST=/data/local/tmp/archniri-latest-display.sock
STABLE=/data/local/tmp/archniri-display.sock

log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >>"$LOG"; }
sock_live() {
    [ -S "$1" ] || return 1
    [ -r /proc/net/unix ] || return 0
    awk -v p="$1" '$NF == p { f = 1 } END { exit f ? 0 : 1 }' /proc/net/unix
}
[ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && : >"$LOG"

JSON=$("$DS" show --json 2>/dev/null)

# --- bridges: one vkbridge-server per running container ---
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

# --- display aliases: per-container + live fallback for latest ---
CANDIDATES=
OIFS=$IFS
IFS='
'
for obj in $(printf '%s' "$JSON" | tr '}' '\n'); do
    name=$(printf '%s' "$obj" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
    sock=$(printf '%s' "$obj" | sed -n 's/.*"anland_sock":"\([^"]*\)".*/\1/p')
    up=$(printf '%s' "$obj" | sed -n 's/.*"uptime_sec":\([0-9]*\).*/\1/p')
    [ -n "$name" ] && [ -n "$sock" ] || continue
    ln -sfn "$sock" "/data/local/tmp/$name-display.sock" 2>/dev/null
    CANDIDATES="$CANDIDATES${up:-999999}|$sock
"
done
IFS=$OIFS
target=$(readlink -f "$LATEST" 2>/dev/null)
# Only a socket that belongs to a running container counts: a stopped
# container's socket file can linger briefly and its /proc/net/unix entry can
# still look present. CANDIDATES is built from `droidspaces show --json`.
if [ -z "${target:-}" ] || ! printf '%s' "$CANDIDATES" | grep -Fq "|$target"; then
    pick=$(printf '%s' "$CANDIDATES" | sed '/^$/d' | sort -n | head -n 1 | cut -d'|' -f2)
    if [ -n "${pick:-}" ]; then
        ln -sfn "$pick" "$LATEST"
        ln -sfn "$pick" "$STABLE"
        log "latest display fallback -> $pick"
    fi
fi
