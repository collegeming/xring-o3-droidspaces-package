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

ui "已安装到 $DEST"
ui "未启动任何进程；开机自启需手动创建 $MODPATH/autostart（见 README.md）"
