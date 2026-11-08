#!/usr/bin/env bash
# Build the XRING-O3 MaliBridge host KernelSU/Magisk module zip.
#
# Inputs: ksu-module/ (module files and README), host/ (scripts and
# host.env.example) and a bionic AArch64 vkbridge-server binary. The server is
# not stored in this repository, so --server is required.
#
# The zip is deterministic: fixed entry order, timestamps, permissions and
# compression level, and text files are normalized to LF (Android sh cannot
# parse CRLF).
#
# Usage: build-module.sh --server PATH [--out DIR] [--force]

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
MOD_DIR=$REPO_DIR/ksu-module
HOST_DIR=$REPO_DIR/host
ZIP_PREFIX=xring-o3-mali-host-ksu

SERVER_PATH=""
OUT_DIR=$REPO_DIR/dist
FORCE=false

log() { printf '[build-module] %s\n' "$*"; }
die() { printf '[build-module] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: build-module.sh --server PATH [--out DIR] [--force]

  --server PATH  vkbridge-server（AArch64 bionic 可执行文件）
  --out DIR      输出目录（默认 <repo>/dist）
  --force        覆盖已存在的 zip
  -h, --help     显示帮助

产物: <out>/xring-o3-mali-host-ksu-<version>.zip 与同名 .sha256
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --server) [ "$#" -ge 2 ] || die "--server 缺少参数"; SERVER_PATH=$2; shift 2 ;;
        --out) [ "$#" -ge 2 ] || die "--out 缺少参数"; OUT_DIR=$2; shift 2 ;;
        --force) FORCE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "不支持的参数：$1（使用 --help 查看用法）" ;;
    esac
done

[ -n "$SERVER_PATH" ] || die "缺少 --server PATH"
[ -f "$SERVER_PATH" ] || die "找不到 server：$SERVER_PATH"
[ -f "$MOD_DIR/module.prop" ] || die "找不到 $MOD_DIR/module.prop"

VERSION=$(sed -n 's/^version=//p' "$MOD_DIR/module.prop" | head -n 1 | tr -d '\r')
case "$VERSION" in
    [0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]) ;;
    *) die "module.prop 的 version 不是 YYYY.MM.DD：$VERSION" ;;
esac

# The server must be a bionic AArch64 executable: a glibc build cannot run on
# Android, and the wrong architecture fails only at boot.
IDENTITY=$(od -An -tx1 -N6 "$SERVER_PATH" | tr -d '[:space:]')
MACHINE=$(od -An -tx1 -j18 -N2 "$SERVER_PATH" | tr -d '[:space:]')
[ "$IDENTITY" = 7f454c460201 ] || die "server 不是 ELF 文件：$SERVER_PATH"
[ "$MACHINE" = b700 ] || die "server 不是 AArch64（e_machine=$MACHINE）"
if ! grep -aq '/system/bin/linker64' "$SERVER_PATH" && \
   ! grep -aq -e 'liblog\.so' -e 'libandroid\.so' "$SERVER_PATH"; then
    die "server 看起来不是 bionic 可执行文件（缺少 linker64/liblog/libandroid）"
fi

PYTHON_BIN=${PYTHON:-}
if [ -z "$PYTHON_BIN" ]; then
    for _candidate in python3 python py; do
        if command -v "$_candidate" >/dev/null 2>&1 && "$_candidate" -c 'import sys' >/dev/null 2>&1; then
            PYTHON_BIN=$_candidate
            break
        fi
    done
fi
[ -n "$PYTHON_BIN" ] || die "需要 Python 3 来生成确定性 zip"
"$PYTHON_BIN" -c 'import sys' >/dev/null 2>&1 || die "PYTHON 不可用：$PYTHON_BIN"

for _name in module.prop customize.sh service.sh uninstall.sh README.md; do
    [ -e "$MOD_DIR/$_name" ] || die "ksu-module/ 缺少 $_name"
done
for _name in start-bridge.sh stop-bridge.sh bridge-supervisor.sh anland-link.sh verify-host.sh host.env.example; do
    [ -e "$HOST_DIR/$_name" ] || die "host/ 缺少 $_name"
done

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)
ARCHIVE=$OUT_DIR/$ZIP_PREFIX-$VERSION.zip
SUMFILE=$ARCHIVE.sha256
if [ -e "$ARCHIVE" ] && [ "$FORCE" = false ]; then
    die "产物已存在：$ARCHIVE；确认覆盖时加 --force"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE=$WORK/module
mkdir -p "$STAGE/payload/mbsrv"

cp -f -- "$MOD_DIR/module.prop" "$MOD_DIR/customize.sh" "$MOD_DIR/service.sh" \
         "$MOD_DIR/uninstall.sh" "$MOD_DIR/README.md" "$STAGE/"
cp -f -- "$HOST_DIR"/*.sh "$HOST_DIR/host.env.example" "$STAGE/payload/"
cp -f -- "$SERVER_PATH" "$STAGE/payload/mbsrv/vkbridge-server"

log "打包 $ZIP_PREFIX-$VERSION（固定顺序、时间戳、权限；文本转 LF）"
"$PYTHON_BIN" -I - "$STAGE" "$ARCHIVE" "$VERSION" <<'PY'
import hashlib
import os
import sys
import zipfile

stage, archive, version = sys.argv[1], sys.argv[2], sys.argv[3]
# Fixed DOS timestamp: the module version date at 00:00:00.
year, month, day = (int(part) for part in version.split("."))
DATE_TIME = (year, month, day, 0, 0, 0)
BINARY = "payload/mbsrv/vkbridge-server"

entries = []
for root, dirs, names in os.walk(stage):
    dirs.sort()
    rel_root = os.path.relpath(root, stage).replace(os.sep, "/")
    if rel_root != ".":
        entries.append((rel_root + "/", None, 0o40755))
    for name in sorted(names):
        path = os.path.join(root, name)
        rel = os.path.relpath(path, stage).replace(os.sep, "/")
        mode = 0o100755 if (name.endswith(".sh") or rel == BINARY) else 0o100644
        entries.append((rel, path, mode))
entries.sort(key=lambda entry: entry[0])

with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    zf.comment = b""
    for rel, path, mode in entries:
        info = zipfile.ZipInfo(rel, date_time=DATE_TIME)
        info.create_system = 3  # Unix, so external_attr carries the mode
        info.external_attr = mode << 16
        if path is None:
            info.external_attr |= 0x10  # MS-DOS directory attribute
            info.compress_type = zipfile.ZIP_STORED
            zf.writestr(info, b"")
            continue
        with open(path, "rb") as handle:
            data = handle.read()
        if rel != BINARY:
            data = data.replace(b"\r\n", b"\n")
        info.compress_type = zipfile.ZIP_DEFLATED
        zf.writestr(info, data, compresslevel=9)

with open(archive, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
with open(archive + ".sha256", "w", newline="\n") as handle:
    handle.write("%s  %s\n" % (digest, os.path.basename(archive)))

print("[build-module] sha256=%s size=%d entries=%d"
      % (digest, os.path.getsize(archive), len(entries)))
PY

[ -s "$ARCHIVE" ] || die "产物为空：$ARCHIVE"
[ -s "$SUMFILE" ] || die "缺少校验文件：$SUMFILE"
log "产物：$ARCHIVE"
log "校验文件：$SUMFILE"
