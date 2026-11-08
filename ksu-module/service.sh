#!/system/bin/sh
# Boot hook: start the MaliBridge host server when autostart is enabled.
#
# KernelSU runs this at late_start service as root. The bridge is started only
# when /data/adb/modules/xring_o3_mali_host/autostart exists; without that
# marker this script exits 0 immediately. SELinux, boot images and init scripts
# are not touched.

MODDIR=${MODPATH:-/data/adb/modules/xring_o3_mali_host}
AUTOSTART=$MODDIR/autostart
DEST=/data/local/tmp/xring-o3-host
LOG=$DEST/boot.log

[ -f "$AUTOSTART" ] || exit 0
[ -x "$DEST/start-bridge.sh" ] || exit 0

# Pin SRV so the installed scripts never depend on a different host.env value.
export SRV=$DEST

# The vendor Mali driver creates /dev/mali0 during boot; wait briefly instead
# of failing this boot when the service stage wins the race.
_n=0
while [ ! -c /dev/mali0 ] && [ "$_n" -lt 10 ]; do
    _n=$((_n + 1))
    sleep 1
done

{
    printf '[service] %s start (autostart)\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo unknown)"
    [ -c /dev/mali0 ] || printf '[service] 警告: /dev/mali0 不存在，server 可能无法工作\n'

    # The container bind mount resolves the alias when it is created, so
    # refresh it before starting the bridge. Failure here is not fatal: the
    # bridge itself does not need Anland.
    if ! "$DEST/anland-link.sh"; then
        printf '[service] 警告: anland-link.sh 失败；容器重启前需重新运行\n'
    fi

    "$DEST/start-bridge.sh"
    _status=$?
    printf '[service] start-bridge.sh 退出码=%s\n' "$_status"
    exit "$_status"
} >> "$LOG" 2>&1
