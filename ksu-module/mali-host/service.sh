#!/system/bin/sh
# Boot hook: start the MaliBridge host server.
#
# KernelSU runs this at late_start service as root. Autostart is on by default,
# matching the droidspaces/anland/malibridge modules: a config file can opt out
# with AUTOSTART=0. SELinux, boot images and init scripts are not touched.

MODDIR=${MODPATH:-/data/adb/modules/xring_o3_mali_host}
DEST=/data/local/tmp/xring-o3-host
LOG=$DEST/boot.log
CONF=/data/adb/xring-o3-host/config.env
[ -r "$CONF" ] || CONF=$MODDIR/config.env

: "${AUTOSTART:=1}"
: "${WAIT_MALI_SECONDS:=60}"
: "${WAIT_ROOTFS_SECONDS:=60}"
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi
[ "$AUTOSTART" = "0" ] && exit 0
[ -x "$DEST/start-bridge.sh" ] || exit 0

# Pin SRV so the installed scripts never depend on a different host.env value.
export SRV=$DEST

ROOTFS=$(sed -n 's/^[[:space:]]*ROOTFS[[:space:]]*=[[:space:]]*//p' "$DEST/host.env" 2>/dev/null | tail -n 1 | tr -d '\r')
: "${ROOTFS:=/data/local/Droidspaces/Containers/archniri/rootfs}"
SOCK_DIR=$ROOTFS/opt/mb-sock

wait_for() {
    _seconds=$1
    _path=$2
    _i=0
    while [ ! -e "$_path" ] && [ "$_i" -lt "$_seconds" ]; do
        _i=$((_i + 1))
        sleep 1
    done
    [ -e "$_path" ]
}

{
    printf '[service] %s autostart (AUTOSTART=%s)\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo unknown)" "$AUTOSTART"

    if ! wait_for "$WAIT_MALI_SECONDS" /dev/mali0; then
        printf '[service] 警告: %s 秒内没有 /dev/mali0，server 可能无法工作\n' "$WAIT_MALI_SECONDS"
    fi
    if ! wait_for "$WAIT_ROOTFS_SECONDS" "$ROOTFS"; then
        printf '[service] 警告: %s 秒内没有 rootfs %s\n' "$WAIT_ROOTFS_SECONDS" "$ROOTFS"
    fi

    # The container bind mount resolves the alias when it is created. Anland
    # may start after this service, so retry the alias in the background while
    # the bridge is started now.
    (
        _i=0
        while [ "$_i" -lt 24 ]; do
            "$DEST/anland-link.sh" && exit 0
            _i=$((_i + 1))
            sleep 5
        done
        printf '[service] 警告: anland-link.sh 在 120 秒内失败；容器重启前需重新运行\n'
        exit 1
    ) >> "$LOG" 2>&1 &

    "$DEST/start-bridge.sh"
    _status=$?
    printf '[service] start-bridge.sh 退出码=%s\n' "$_status"
    exit "$_status"
} >> "$LOG" 2>&1
