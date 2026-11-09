#!/usr/bin/env bash
# 构建 Gold Keyboard Remaps 模块 zip（本设备定制：伪装 15d9:00a3）。
#
# 默认从上游拉取；也可用 GOLD_SRC 指向已 checkout 的上游工作树（离线/网络不稳）。
# CI 里由 .github/workflows/build-gold-keyboard-ksu.yml 调用，NDK 由该 workflow
# 安装；本地运行需要自备 NDK（r27c 或更新）与 javac。
#
# 用法：
#   GOLD_SRC=/path/to/Gold_Keyboardremaps ./build-module.sh --ndk /path/to/ndk
#   ./build-module.sh --ndk /path/to/ndk --out /tmp/dist
set -euo pipefail

UPSTREAM_REPO=${UPSTREAM_REPO:-https://github.com/Goldzxcbug/Gold_Keyboardremaps.git}
UPSTREAM_TAG=${UPSTREAM_TAG:-v1.1.1}
UPSTREAM_SHA=${UPSTREAM_SHA:-73b40145f531e1cfa6202bf84c721314c7baa1ab}
ANDROID_API=${ANDROID_API:-26}
ANDROID_PLATFORM=${ANDROID_PLATFORM:-35}
GH_MIRROR_PREFIX=${GH_MIRROR_PREFIX:-https://gh-proxy.com/}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
ndk=${ANDROID_NDK_ROOT:-}
out_dir="$script_dir/dist"

while [ $# -gt 0 ]; do
    case "$1" in
        --ndk) ndk=$2; shift 2 ;;
        --out) out_dir=$2; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

[ -n "$ndk" ] || { echo "需要 Android NDK：--ndk DIR 或 ANDROID_NDK_ROOT" >&2; exit 2; }
[ -d "$ndk" ] || { echo "NDK 目录不存在：$ndk" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/gold-ksu.XXXXXX")
trap 'rm -rf "$work"' EXIT

echo "==> 准备上游 $UPSTREAM_TAG（$UPSTREAM_SHA）"
src_dir=${GOLD_SRC:-}
if [ -n "$src_dir" ] && [ -d "$src_dir" ] && [ -f "$src_dir/fn_remap.c" ]; then
    echo "    使用本地工作树：$src_dir"
    cp -a "$src_dir" "$work/src"
else
    cloned=false
    for attempt in 1 2 3; do
        if git clone "$UPSTREAM_REPO" "$work/src" 2>"$work/clone.err"; then
            cloned=true; break
        fi
        rm -rf "$work/src"
        if git -c "url.${GH_MIRROR_PREFIX%/}/https://github.com/.insteadOf=https://github.com/" \
            clone "$UPSTREAM_REPO" "$work/src" 2>"$work/clone.err"; then
            cloned=true; break
        fi
        rm -rf "$work/src"
        echo "    第 $attempt 次克隆失败：$(tail -n2 "$work/clone.err" | tr '\n' ' ')"
        sleep 3
    done
    [ "$cloned" = true ] || { echo "上游克隆失败（可用 GOLD_SRC 指定本地树）" >&2; exit 1; }
    git -C "$work/src" checkout --quiet --detach "$UPSTREAM_SHA"
fi

actual=$(git -C "$work/src" rev-parse HEAD 2>/dev/null || echo unknown)
[ "$actual" = "$UPSTREAM_SHA" ] || {
    echo "上游 commit 不匹配：期望 $UPSTREAM_SHA，实际 $actual" >&2; exit 1; }

echo "==> 应用补丁"
for patch in "$script_dir"/patches/*.patch; do
    [ -f "$patch" ] || continue
    echo "    $(basename "$patch")"
    git -C "$work/src" apply --check "$patch" || {
        echo "补丁无法应用（上游结构变化？）：$patch" >&2; exit 1; }
    git -C "$work/src" apply "$patch"
done

# 这两个常量是本补丁的全部意义，构建前强校验。
grep -q '^#define VIRTUAL_VENDOR 0x15d9'  "$work/src/fn_remap.c" || {
    echo "补丁未生效：VIRTUAL_VENDOR != 0x15d9" >&2; exit 1; }
grep -q '^#define VIRTUAL_PRODUCT 0x00a3' "$work/src/fn_remap.c" || {
    echo "补丁未生效：VIRTUAL_PRODUCT != 0x00a3" >&2; exit 1; }

# NDK 的 prebuilt 目录名随宿主平台变化（linux-x86_64 / windows-x86_64 / darwin-*），
# 按实际存在的目录选择，不在脚本里写死。
prebuilt=$(find "$ndk/toolchains/llvm/prebuilt" -maxdepth 1 -mindepth 1 -type d | head -n1)
[ -n "$prebuilt" ] || { echo "NDK 缺少 toolchains/llvm/prebuilt" >&2; exit 2; }
compiler="$prebuilt/bin/aarch64-linux-android${ANDROID_API}-clang"
[ -x "$compiler" ] || compiler="$compiler.cmd"
[ -x "$compiler" ] || { echo "NDK 缺少 aarch64 clang：$prebuilt/bin" >&2; exit 2; }

echo "==> 编译 fn-remap（aarch64, Android API $ANDROID_API）"
mkdir -p "$work/out/bin"
"$compiler" -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror -fPIE -pie \
    "$work/src/fn_remap.c" -o "$work/out/bin/fn-remap"
if command -v file >/dev/null 2>&1; then
    file "$work/out/bin/fn-remap" | grep -qE 'aarch64|ARM aarch64' || {
        echo "产物不是 aarch64" >&2; exit 1; }
fi

echo "==> 编译 ColorOS 启动器（缺 javac/d8 时跳过，不影响按键重映射）"
jar_ok=false
if command -v javac >/dev/null 2>&1; then
    android_jar=$(find "$ndk" -maxdepth 5 -path "*platforms/android-${ANDROID_PLATFORM}/android.jar" 2>/dev/null | head -n1)
    [ -n "$android_jar" ] || android_jar=${ANDROID_JAR:-}
    d8=$(find "$ndk" -maxdepth 6 -name d8 -type f 2>/dev/null | sort -V | tail -n1)
    [ -n "$d8" ] || d8=$(command -v d8 || true)
    if [ -n "$android_jar" ] && [ -f "$android_jar" ] && [ -n "$d8" ]; then
        mkdir -p "$work/classes"
        if javac -source 8 -target 8 -cp "$android_jar" -d "$work/classes" \
                "$work/src/ColorOS.java" >/dev/null 2>&1 && \
            "$d8" --min-api "$ANDROID_API" --lib "$android_jar" \
                --output "$work/out/bin/coloros-window-launcher.jar" \
                "$work/classes/gold/keyboardremaps/ColorOS.class" >/dev/null 2>&1; then
            jar_ok=true
        fi
    fi
fi
[ "$jar_ok" = true ] || echo "    跳过（未找到 android.jar 或 d8）"

echo "==> 组装模块"
install -m 0644 "$work/src/module.prop" "$work/out/module.prop"
install -m 0644 "$script_dir/config/config.conf" "$work/out/config.conf"
for f in service.sh action.sh keylayout.sh customize.sh; do
    [ -f "$work/src/$f" ] && install -m 0755 "$work/src/$f" "$work/out/$f"
done
[ -f "$work/src/keyboardctl" ] && install -m 0755 "$work/src/keyboardctl" "$work/out/bin/keyboardctl"
[ -d "$work/src/webroot" ] && cp -a "$work/src/webroot" "$work/out/webroot"

# 描述里标出本设备定制，避免与上游同版本号产物混淆。
sed -i.bak 's|^description=.*|description=Gold Keyboard Remaps（本设备定制：虚拟键盘伪装 Xiaomi 15d9:00a3，MIUI 原生快捷键可用）|' \
    "$work/out/module.prop" && rm -f "$work/out/module.prop.bak"
module_version=$(awk -F= '$1=="version"{print $2; exit}' "$work/src/module.prop")

mkdir -p "$out_dir"
archive="$out_dir/Gold_Keyboardremaps-${module_version}-yingtian.zip"
rm -f "$archive"
if command -v zip >/dev/null 2>&1; then
    ( cd "$work/out" && zip -q -r -9 "$archive" . )
else
    # Git Bash 默认没有 zip；用 python 的 zipfile 保持 CI 与本地一致。
    python3 - "$work/out" "$archive" <<'PY'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for base, _, files in os.walk(root):
        for name in files:
            full = os.path.join(base, name)
            z.write(full, os.path.relpath(full, root))
PY
fi
sha256sum "$archive" > "$archive.sha256"

echo
echo "产物：$archive"
cat "$archive.sha256"
echo
echo "安装：KernelSU Manager → 模块 → 从本地安装 → 选 zip → 重启"
echo "验证：adb shell getevent -pl | grep -A4 'Gold Keyboardremaps'   # 期望 15d9:00a3"
