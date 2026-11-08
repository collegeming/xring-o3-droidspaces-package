#!/system/bin/sh
# KernelSU/Magisk install hook: copy the host payload to the Android host.
#
# Runs as root during module installation. It only copies files: nothing is
# started, no boot image or init script is touched, and no network is used.
# Reinstalling is safe; an existing $DEST/host.env is never overwritten.

MODPATH=${MODPATH:-.}
PAYLOAD=$MODPATH/payload
DEST=/data/local/tmp/xring-o3-host
MANIFEST=$DEST/.install-manifest

ui() { if command -v ui_print >/dev/null 2>&1; then ui_print "$*"; else printf '%s\n' "$*"; fi; }
die() {
    ui "错误: $*"
    if command -v abort >/dev/null 2>&1; then abort "错误: $*"; fi
    exit 1
}

[ -d "$PAYLOAD" ] || die "缺少 payload/ 目录（$PAYLOAD）"
[ -f "$PAYLOAD/mbsrv/vkbridge-server" ] || die "缺少 payload/mbsrv/vkbridge-server"

mkdir -p "$DEST/mbsrv" || die "无法创建 $DEST"

if [ -e "$DEST/host.env" ]; then
    ui "保留已有 $DEST/host.env"
fi

: > "$MANIFEST.tmp" || die "无法写入 $DEST"

for _src in "$PAYLOAD"/*.sh; do
    [ -f "$_src" ] || continue
    _name=${_src##*/}
    # Write then rename: the payload may be in use by a running supervisor.
    cp -f "$_src" "$DEST/.$_name.new" || die "复制 $_name 失败"
    chmod 0755 "$DEST/.$_name.new"
    mv -f "$DEST/.$_name.new" "$DEST/$_name" || die "替换 $_name 失败"
    printf '%s\n' "$_name" >> "$MANIFEST.tmp"
done

cp -f "$PAYLOAD/host.env.example" "$DEST/host.env.example" || die "复制 host.env.example 失败"
chmod 0644 "$DEST/host.env.example"
printf 'host.env.example\n' >> "$MANIFEST.tmp"

# host.env is generated once so that local edits survive reinstalls.
if [ ! -e "$DEST/host.env" ]; then
    sed "s|^SRV=.*|SRV=$DEST|" "$PAYLOAD/host.env.example" > "$DEST/.host.env.new" || die "生成 host.env 失败"
    chmod 0644 "$DEST/.host.env.new"
    mv -f "$DEST/.host.env.new" "$DEST/host.env" || die "写入 host.env 失败"
    ui "已生成 $DEST/host.env"
fi
printf 'host.env\n' >> "$MANIFEST.tmp"

cp -f "$PAYLOAD/mbsrv/vkbridge-server" "$DEST/mbsrv/.vkbridge-server.new" || die "复制 vkbridge-server 失败"
chown 0:0 "$DEST/mbsrv/.vkbridge-server.new" 2>/dev/null || true
chmod 0755 "$DEST/mbsrv/.vkbridge-server.new"
# A running server keeps its old inode; rename never hits ETXTBSY.
mv -f "$DEST/mbsrv/.vkbridge-server.new" "$DEST/mbsrv/vkbridge-server" || die "替换 vkbridge-server 失败"
printf 'mbsrv/vkbridge-server\n' >> "$MANIFEST.tmp"

sort -u "$MANIFEST.tmp" > "$MANIFEST" || die "写入 manifest 失败"
rm -f "$MANIFEST.tmp"
chmod 0644 "$MANIFEST"

# Autostart is on by default; the config lives outside the module directory so
# a module update does not reset it.
CFG_DIR=/data/adb/xring-o3-host
mkdir -p "$CFG_DIR" || die "无法创建 $CFG_DIR"
if [ ! -e "$CFG_DIR/config.env" ]; then
    {
        printf '# XRING-O3 MaliBridge host module\n'
        printf 'AUTOSTART=1\n'
        printf 'WAIT_MALI_SECONDS=60\n'
        printf 'WAIT_ROOTFS_SECONDS=60\n'
    } > "$CFG_DIR/config.env" || die "无法写入 $CFG_DIR/config.env"
    chmod 0644 "$CFG_DIR/config.env"
    ui "已写入默认配置：$CFG_DIR/config.env（AUTOSTART=1）"
fi

# The legacy malibridge module starts a second server on the same socket with
# the older binary and budget. Disable it; deleting the disable file restores it.
LEGACY=/data/adb/modules/malibridge
if [ -d "$LEGACY" ] && [ ! -e "$LEGACY/disable" ]; then
    : > "$LEGACY/disable" || ui "警告: 无法禁用旧 malibridge 模块"
    printf 'malibridge\n' > "$CFG_DIR/.legacy-malibridge-disabled" 2>/dev/null || true
    ui "已禁用旧 malibridge 模块（同一 socket 避免双 server；删除 $LEGACY/disable 可恢复）"
fi

ui "已安装到 $DEST"
ui "开机自启默认开启；关闭：把 $CFG_DIR/config.env 的 AUTOSTART 改为 0"
