#!/system/bin/sh
# KernelSU/Magisk uninstall hook: stop the bridge, then remove the installed
# host payload. Runs as root before the module directory is deleted.
#
# Logs written by the server live in the container rootfs
# (<ROOTFS>/opt/mb-sock/server.log and stdout.log) and are intentionally kept;
# delete them by hand if they are no longer wanted. The Anland alias symlink
# (/data/local/tmp/archniri-display.sock) is also kept, because a container
# bind mount may still reference it.

DEST=/data/local/tmp/xring-o3-host

if [ -x "$DEST/stop-bridge.sh" ]; then
    SRV=$DEST "$DEST/stop-bridge.sh" || true
fi

rm -rf "$DEST"
