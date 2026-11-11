#!/system/bin/sh
# One reconciliation pass: every running Droidspaces container must have its
# own MaliBridge server; bridges whose container is gone are stopped.
#
# Two ordering gaps this closes:
#
# 1. A container created after the host payload was installed has no private
#    Containers/<name>/host directory yet. The old loop skipped it forever, so
#    its desktop started without a bridge. Provision it from the template
#    directory (the same files the installer wrote to /data/local/tmp).
#
# 2. desktop-session waits 30 s for the bridge and then starts anyway. If the
#    bridge appears later, niri is already running without a renderer and keeps
#    failing until someone restarts the session. When the bridge becomes ready
#    after niri started, restart desktop-session once (no-block, throttled).
#
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
# Source for a container's private host dir. Must contain the bridge scripts,
# host.env.example and mbsrv/vkbridge-server.
TEMPLATE=${XRING_O3_HOST_TEMPLATE:-/data/local/tmp/xring-o3-host}
# Minimum seconds between two late-bridge restarts of the same container.
RESTART_COOLDOWN=120

log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >>"$LOG"; }
sock_live() {
    [ -S "$1" ] || return 1
    [ -r /proc/net/unix ] || return 0
    awk -v p="$1" '$NF == p { f = 1 } END { exit f ? 0 : 1 }' /proc/net/unix
}
[ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && : >"$LOG"

# Copy the host payload into Containers/<name>/host and generate its host.env.
# Existing directories are never overwritten: hand-tuned values stay.
provision_host() {
    _ctr=$1
    _rootfs=$2
    _host=$3
    [ -x "$TEMPLATE/start-bridge.sh" ] || return 1
    [ -x "$TEMPLATE/mbsrv/vkbridge-server" ] || return 1
    mkdir -p "$_host/mbsrv" || return 1
    for _f in start-bridge.sh stop-bridge.sh bridge-supervisor.sh \
              anland-link.sh verify-host.sh host.env.example; do
        [ -f "$TEMPLATE/$_f" ] || return 1
        cp -f "$TEMPLATE/$_f" "$_host/$_f" || return 1
        chmod 0755 "$_host/$_f" 2>/dev/null || true
    done
    cp -f "$TEMPLATE/mbsrv/vkbridge-server" "$_host/mbsrv/vkbridge-server" || return 1
    chmod 0755 "$_host/mbsrv/vkbridge-server" 2>/dev/null || true
    if [ ! -f "$_host/host.env" ]; then
        sed -e "s|^CTR=.*|CTR=$_ctr|" \
            -e "s|^ROOTFS=.*|ROOTFS=$_rootfs|" \
            -e "s|^SRV=.*|SRV=$_host|" \
            -e "s|^ANLAND_LINK=.*|ANLAND_LINK=/data/local/tmp/$_ctr-display.sock|" \
            "$TEMPLATE/host.env.example" >"$_host/.host.env.new" || return 1
        mv -f "$_host/.host.env.new" "$_host/host.env" || return 1
    fi
    return 0
}

# desktop-session writes /tmp/xring-o3-bridge-timeout when wait-for-bridge
# times out; while that marker exists the session is running without a
# renderer. Once the bridge is live, restart it once. The marker is removed
# before restarting so a failed restart cannot loop; a cooldown bounds retries.
# Containers with an older rootfs never write the marker and are left alone.
late_restart() {
    _ctr=$1
    _rootfs=$2
    _host=$3
    [ -S "$_rootfs/opt/mb-sock/mali.sock" ] || return 0
    _state=$("$DS" -n "$_ctr" run -- sh -c '
        [ -e /tmp/xring-o3-bridge-timeout ] || { echo NO_MARKER; exit 0; }
        [ -S /opt/mb-sock/mali.sock ] || { echo NO_BRIDGE; exit 0; }
        echo TIMEOUT_MARKED
    ' 2>/dev/null)
    [ "$_state" = TIMEOUT_MARKED ] || return 0
    _now=$(date +%s)
    _last=$(cat "$_host/.late-restart.stamp" 2>/dev/null | tr -d '\r\n')
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    if [ $((_now - _last)) -lt "$RESTART_COOLDOWN" ]; then
        return 0
    fi
    log "desktop-session started without the bridge ($_ctr), restarting it now that the bridge is up"
    printf '%s\n' "$_now" >"$_host/.late-restart.stamp"
    "$DS" -n "$_ctr" run -- rm -f /tmp/xring-o3-bridge-timeout >>"$LOG" 2>&1
    "$DS" -n "$_ctr" run -- systemctl restart --no-block desktop-session >>"$LOG" 2>&1
}

JSON=$("$DS" show --json 2>/dev/null)

# --- bridges: one vkbridge-server per running container ---
for R in /data/local/Droidspaces/Containers/*/rootfs; do
    [ -d "$R" ] || continue
    HOST=$(dirname "$R")/host
    CTR=$(basename "$(dirname "$R")")
    case "$JSON" in
        *"\"name\":\"$CTR\""*)
            if [ ! -x "$HOST/start-bridge.sh" ] || [ ! -x "$HOST/mbsrv/vkbridge-server" ]; then
                log "provision host dir: $CTR"
                if ! provision_host "$CTR" "$R" "$HOST"; then
                    log "provision failed (template $TEMPLATE): $CTR"
                    continue
                fi
            fi
            PID=$(cat "$HOST/server.pid" 2>/dev/null | tr -d '\r\n')
            if [ -n "${PID:-}" ] && [ -d "/proc/$PID" ] && sock_live "$R/opt/mb-sock/mali.sock"; then
                late_restart "$CTR" "$R" "$HOST"
                continue
            fi
            log "start bridge: $CTR"
            SRV="$HOST" sh "$HOST/start-bridge.sh" >>"$LOG" 2>&1
            late_restart "$CTR" "$R" "$HOST"
            ;;
        *)
            if [ -f "$HOST/start-bridge.sh" ]; then
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
