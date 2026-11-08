# 复刻步骤

本文给出从零复刻一台 XRING-O3 设备的顺序，以及换到其他 Mali/Droidspaces 设备时需要改什么。

## 1. 前置条件

| 项目 | 要求 | 检查 |
| --- | --- | --- |
| 设备 | XRING-O3 / Mali-G2-Ultra-NX，Android 17 | `getprop ro.product.board`、`getprop ro.build.version.sdk` |
| Root | KernelSU 可用 | `adb shell su -c id` |
| GPU 节点 | `/dev/mali0` 存在 | `ls -l /dev/mali0` |
| DRM | 主节点 `/dev/dri/card0`，无 `renderD*` | `ls -l /dev/dri` |
| Droidspaces | 7.1.0 APK，daemon 正常 | `/data/local/Droidspaces/bin/droidspaces show` |
| Anland | `com.anlandnext` + `com.anland.consumer` | `pm list packages | grep anland` |
| 主机工具 | `adb`；打包需要 `zstd`、GNU tar | `zstd --version` |

## 2. 安装 Android 主机侧

主机侧包包含 `vkbridge-server`、supervisor、启动/停止、Anland 别名和验证脚本。

```sh
# 解包
tar --zstd -xf xring-o3-mali-host-2026.11.08.tar.zst

# PC 通过 adb 安装（多设备时加 --serial）
bash mali-host/scripts/install-host.sh \
     --bundle xring-o3-mali-host-2026.11.08.tar.zst \
     --serial 0308A880499C3540
```

设备本地安装：

```sh
adb push mali-host/scripts/*.sh /data/local/tmp/xring-o3-host/
adb shell su -c 'sh /data/local/tmp/xring-o3-host/install-host.sh \
    --server /data/local/tmp/mbsrv/vkbridge-server'
```

安装结果：

| 路径 | 内容 |
| --- | --- |
| `/data/local/tmp/xring-o3-host/` | 脚本与 `host.env` |
| `/data/local/tmp/xring-o3-host/mbsrv/vkbridge-server` | bionic server |
| `host.env` | `CTR`、`ROOTFS`、`SRV`、`ANLAND_LINK`、预算 |

### 2.1 KernelSU 模块方式（可选）

`xring-o3-mali-host-ksu-2026.11.08.zip` 把同样的 host 脚本与 server 打包成 KernelSU 模块，适合快速部署多台设备。

- 模块安装只复制文件，不启动任何进程；
- 默认不自启；需要开机启动时手动创建标记：

```sh
adb shell su -c 'touch /data/adb/modules/xring_o3_mali_host/autostart'
```

- 模块不安装 Droidspaces/Anland APK，也不替代 rootfs 镜像；
- 这是用户空间 KernelSU 模块，不是内核 LKM，不修改 SELinux 或 boot 镜像。

`host.env` 的默认值适用于 `archniri`；换容器名或 rootfs 路径时必须改。

## 3. 启动桥并建立 Anland 别名

```sh
adb shell su -c 'sh /data/local/tmp/xring-o3-host/start-bridge.sh'
adb shell su -c 'sh /data/local/tmp/xring-o3-host/anland-link.sh'
adb shell su -c 'sh /data/local/tmp/xring-o3-host/verify-host.sh'
```

`start-bridge.sh` 成功后应看到：

```text
mali.sock     /data/local/Droidspaces/Containers/archniri/rootfs/opt/mb-sock/mali.sock
control.sock  /data/local/Droidspaces/Containers/archniri/rootfs/opt/mb-sock/control.sock
budget.conf   4096 / 2048 / 2048 / 60000
```

脚本不会写开机启动，也不会自动 root；设备重启后需要重新执行。

## 4. 构建 rootfs 镜像

在 `collegeming/Droidspaces-Arch-Niri-rootfs-builder` 的 `xring-o3-mali` 分支运行 workflow，关键输入：

| 输入 | 值 |
| --- | --- |
| `build_target` | `Arch` |
| `desktop` | `niri` |
| `display_backend` | `anland-wayland` |
| `device_profile` | `xring-o3` |
| `apply_preferences` | `true` |
| `mali_stack_bundle_url` | `xring-o3-mali-stack-2026.11.08-v2.tar.zst` 的下载地址 |
| `mali_stack_bundle_sha256` | `159ddd879241df78baa2f476e38ac1756e1a9b44c778bd0b8b7c18e50389c08d` |
| `mali_stack_version` | `2026.11.08` |
| `wayland_package_repository` | 带 Touch/AFBC 的 niri 包仓库；未构建时留空，使用上游包 |

`device_profile=xring-o3` 会强制 `ENABLE_mesa=true`，并在缺少 bundle URL/SHA 时直接失败，避免产出无 GPU 栈的镜像。

镜像内的最终阶段顺序：

```text
安装桌面与 Anland 包
安装 niri/Noctalia/应用
安装 Mali stack（bundle）
安装 card0/anland unit
应用 preferences
导出 rootfs
```

## 5. 导入并启动容器

容器配置需要：

```ini
enable_anland=1
enable_gpu_mode=1
bind_mounts=/data/local/tmp/vtest:/run/ds-gpu,/dev/dma_heap:/dev/dma_heap
```

启动：

```sh
adb shell su -c '/data/local/Droidspaces/bin/droidspaces -C /data/local/tmp/archniri-5x.config start'
```

首次启动后，`desktop-session.service` 的 `ExecStartPre` 会等待 `mali.sock` 与 `control.sock`；两个 socket 未就绪时最多等待 30 秒。

## 6. 验收

在容器内执行：

```sh
systemctl status desktop-session
journalctl -u desktop-session | grep -E 'GL Renderer|zink|Mali'
niri msg outputs
niri msg layers
mbctl status          # 以 uid 1000 运行
readlink -f /usr/local/bin/zc-run
ls -l /opt/mali-stack/current/conf
```

预期：

| 检查 | 预期 |
| --- | --- |
| niri renderer | `zink Vulkan 1.4(Mali-G2-Ultra-NX MC16 ...)` |
| Noctalia layer | `noctalia-wallpaper`（Background）+ `noctalia-bar-default`（Top） |
| Noctalia memfd | `/proc/<pid>/fd` 中 `memfd` 计数为 0 |
| 预算 | `total 4096 / per client 2048 / floor 2048 / map 60000` |
| zc-run | 指向 `/opt/mali-stack/current/bin/zc-run` |
| 配置 | `zc-env.conf`、`noctalia-env.conf` 均存在 |

## 7. 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| niri 启动后无 renderer | 启动时 server 未监听 | 先启动 bridge，再 `systemctl restart desktop-session` |
| `cannot reach the Vulkan bridge server` | `mali.sock` 不存在或 server 退出 | 检查 supervisor 与 server 日志 |
| Noctalia 不出现 | `noctalia-dt` 失败、ICD/shim 缺失 | 检查 `/usr/local/bin/noctalia-dt`、`conf/noctalia-env.conf`、shim 路径 |
| `mbctl: uid not allowed` | 以 root 连接，白名单是 uid 1000 | 用 `runuser -u colle -- mbctl status` |
| 触摸没有 seat | niri 包未包含 Touch 补丁 | 使用 `patches/anland/0001-touch-seat.patch` 重建包 |
| Zen 仍报 `Invalid stride` | niri/Smithay 未包含 AFBC 补丁 | 使用 `patches/smithay/0001-afbc-linear-size-check.patch` 重建包 |
| Chrome 走软件渲染 | zc-run 未命中 chromium 类 | 检查 `/etc/zc-desktop.conf` 与 `zc-classify` |
| `/dev/dri/card0` 缺失 | 主机节点不存在或容器 unit 未运行 | 主机 `mknod`，容器内检查 `xring-o3-card0.service` |

## 8. 换到其他设备

### 8.1 仍使用 Mali kbase + vendor Vulkan

需要改设备 profile，不改补丁：

| 项 | XRING-O3 当前值 | 其他设备要确认 |
| --- | --- | --- |
| GPU 节点 | `/dev/mali0` | 是否存在，字符设备号 |
| DRM 主节点 | `/dev/dri/card0` | 可能是 `card1` 或其它 |
| Anland socket | `Net/anland-<hash>.sock` | 实际 hash；用 `anland-link.sh` 生成稳定别名 |
| Vendor 库 | `/vendor/lib64/egl/libGLES_mali.so`、`/vendor/lib64/hw/vulkan.mali.so` | 路径可能不同；`verify-host.sh` 会按候选路径查找 |
| 容器名/rootfs | `archniri` | 修改 `host.env` |
| 预算 | 4096 / 2048 / 2048 / 60000 | 按设备内存调整 |

### 8.2 其他 Linux 发行版

可复用的部分：

| 组件 | 可复用性 | 前提 |
| --- | --- | --- |
| `mali-host` 主机侧 | 高 | 仍是 Android + bionic + vendor Mali |
| `mali-stack` 的 Mesa/ICD/shim | 中高 | glibc AArch64，且 bundle 内库的符号版本与发行版 glibc 兼容 |
| `zc-run` / `zc-sync` | 高 | 纯 shell，依赖 `/bin/sh`、`readlink`、`grep` |
| `mbctl` | 高 | 静态/少量依赖，连 `control.sock` |
| `mb-tray` | 中 | 依赖 GLib/GIO/DBus；目标发行版需安装对应库 |
| systemd unit | 高 | 目标发行版使用 systemd |
| preferences | 低 | 只适用于 Arch + niri + Noctalia |

不可直接复用：

- Anland APK 与 Droidspaces 本身是 Android 侧组件。
- `xring-o3` device profile 的节点名、socket 名、vendor 路径是设备特定的。
- Arch 的包名、镜像源、fcitx5/Rime 配置属于 preferences，不属于 Mali 栈。

## 9. 最小验收清单

- [ ] `verify-host.sh` 全部 PASS
- [ ] `mali.sock` 与 `control.sock` 同时存在
- [ ] niri renderer 为 `zink Vulkan ... Mali`
- [ ] Noctalia 有 wallpaper 与 bar 两个 layer surface
- [ ] Noctalia 的 memfd 为 0
- [ ] `mbctl status` 返回 4G 预算与客户端列表
- [ ] Chrome 打开 `chrome://gpu`，确认 GPU 进程使用 Vulkan/zink
- [ ] `dbx-dmabuf` 打开页面，确认没有 SHM 回退
- [ ] 重启容器后，上述检查仍通过
