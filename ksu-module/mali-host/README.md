# XRING-O3 MaliBridge 主机侧 KernelSU 模块

把 Android 主机侧的 `vkbridge-server` 与主机脚本打包成 KernelSU/Magisk 模块 zip。安装时由 `customize.sh` 写入 `/data/local/tmp/xring-o3-host/`；开机时默认自动启动 bridge，可在配置文件里关闭。

> ⚠️ 这是 **userspace** 模块，不是内核模块（LKM）。它不加载内核驱动、不修改 boot 镜像、不改 init 脚本、不改 SELinux，也不申请 root。

## 范围与边界

| 本模块负责 | 本模块不负责 |
| --- | --- |
| `vkbridge-server`（bionic AArch64）与主机脚本的安装 | 容器 rootfs 镜像；由 `collegeming/Droidspaces-Arch-Niri-rootfs-builder` 的 `xring-o3-mali` 分支构建 |
| 安装清单、权限、`host.env` 首次生成与保留 | 容器内 Mesa、MaliBridge ICD、libgbm、`zc-run` 等；由 `xring-o3-mali-stack-<version>.tar.zst` 提供 |
| bridge 开机自启（默认开启，可配置关闭） | Droidspaces 容器创建、Anland 绑定挂载、APK 安装 |

主机侧与容器侧必须分开安装：`vkbridge-server` 依赖 `/dev/mali0` 与 vendor Mali 驱动，只能运行在 Android 主机；容器内的图形栈由 rootfs 包提供。本模块不使用 `.tar.zst` 主机包，因为 Android toybox 没有 `zstd`，直接把文件和二进制放进 zip。

## 包内文件

| 路径 | 作用 |
| --- | --- |
| `module.prop` | 模块元数据（id `xring_o3_mali_host`，版本 `2026.11.08`） |
| `customize.sh` | 安装钩子：复制 payload、设置权限、生成或保留 `host.env`、写 `.install-manifest`、写默认 `config.env`、禁用旧 `malibridge` 模块；不启动任何进程 |
| `service.sh` | 开机钩子：默认等待 `/dev/mali0` 与 rootfs，刷新 Anland 别名并启动 bridge；`AUTOSTART=0` 时跳过 |
| `uninstall.sh` | 卸载钩子：停止 bridge 后删除 `/data/local/tmp/xring-o3-host` |
| `payload/*.sh` | `start-bridge.sh`、`stop-bridge.sh`、`bridge-supervisor.sh`、`anland-link.sh`、`verify-host.sh`、`install-host.sh`；`install-host.sh` 是原主机脚本安装器，随包保留，模块安装不调用它 |
| `payload/host.env.example` | 配置模板；安装时据此生成 `host.env` |
| `payload/mbsrv/vkbridge-server` | bionic AArch64 服务端 |

## 安装

KernelSU 应用：**模块 → 从本地安装 → 选择 zip**。Magisk 应用的入口相同。

命令行安装（zip 已在设备上）：

```sh
su -c 'ksud module install /data/local/tmp/xring-o3-mali-host-ksu-2026.11.08.zip'
```

`customize.sh` 在安装过程中即以 root 执行，安装完成后 payload 已可用，无需等待下次开机。安装阶段不启动 server，也不需要网络。

### 安装后的目录

| 路径 | 说明 |
| --- | --- |
| `/data/local/tmp/xring-o3-host/*.sh` | 0755，覆盖安装 |
| `/data/local/tmp/xring-o3-host/mbsrv/vkbridge-server` | 0755，每次覆盖 |
| `/data/local/tmp/xring-o3-host/host.env` | 首次安装生成，之后保留本地修改 |
| `/data/local/tmp/xring-o3-host/host.env.example` | 每次覆盖 |
| `/data/local/tmp/xring-o3-host/.install-manifest` | 已安装文件清单，每行一个相对路径 |

## 开机自启

默认开启，与 `droidspaces`、`anland-daemon`、`anland-awl`、旧 `malibridge` 模块的行为一致：安装后无需再手工创建标记。

配置在模块目录之外，升级不会重置：

```sh
# 关闭（AUTOSTART 改为 0）
su -c 'sed -i "s/^AUTOSTART=.*/AUTOSTART=0/" /data/adb/xring-o3-host/config.env'

# 重新开启
su -c 'sed -i "s/^AUTOSTART=.*/AUTOSTART=1/" /data/adb/xring-o3-host/config.env'
```

`config.env` 默认值：

```text
AUTOSTART=1
WAIT_MALI_SECONDS=60
WAIT_ROOTFS_SECONDS=60
```

开机执行顺序：等待 `/dev/mali0`（最多 60 秒）→ 等待容器 rootfs（最多 60 秒）→ 启动 bridge → 后台重试 `anland-link.sh`（最多 120 秒）。输出追加到 `/data/local/tmp/xring-o3-host/boot.log`。

旧 `malibridge` 模块会在 `customize.sh` 安装时被写入 `disable` 标记，避免两个模块对同一个 socket 各起一个 server。删除 `/data/adb/modules/malibridge/disable` 可恢复旧模块。

时序限制：容器的绑定挂载在创建时解析 `ANLAND_LINK`。如果 Droidspaces 在 `service.sh` 之前启动容器，容器可能挂到旧 socket 或挂载失败；此时重新运行 `anland-link.sh` 并重启容器。

## 验证

```sh
su -c '/data/local/tmp/xring-o3-host/verify-host.sh'
su -c '/data/local/tmp/xring-o3-host/anland-link.sh --check'
```

`verify-host.sh` 只读，全部 PASS 返回 0。其中 `budget.conf` 检查需要容器内已安装 `xring-o3-mali-stack-*`，容器未运行时容器检查也会 FAIL；这两项与主机侧安装无关。

开机启动失败时先看：

```sh
su -c 'tail -n 40 /data/local/tmp/xring-o3-host/boot.log'
su -c 'tail -n 40 /data/local/Droidspaces/Containers/archniri/rootfs/opt/mb-sock/server.log'
```

## 卸载

在 KernelSU 应用中移除模块，系统会以 root 执行 `uninstall.sh`：先调用 `stop-bridge.sh`，再删除 `/data/local/tmp/xring-o3-host`（含 `.install-manifest` 与 `boot.log`）。

以下内容有意保留，需要时手动清理。表中 `<ROOTFS>` 指 `host.env` 的 `ROOTFS`，默认 `/data/local/Droidspaces/Containers/archniri/rootfs`。

| 保留项 | 位置 | 原因 |
| --- | --- | --- |
| server 日志 | `<ROOTFS>/opt/mb-sock/server.log`、`stdout.log` | 排障证据；位于容器 rootfs，不属于模块 |
| Anland 别名 | `/data/local/tmp/archniri-display.sock`（默认 `CTR=archniri`） | 容器绑定挂载可能仍引用该路径 |

## 构建（维护者）

```sh
bash ksu-module/mali-host/build-module.sh \
     --server /path/to/vkbridge-server \
     --out dist
```

产物：`dist/xring-o3-mali-host-ksu-2026.11.08.zip` 与同名 `.sha256`（`sha256sum` 原始格式）。

构建固定条目顺序、时间戳 `2026-11-08 00:00:00`、权限（脚本与 server 为 0755，其余 0644）与压缩级别；文本文件统一转为 LF。输入 server 需为 AArch64 bionic 可执行文件，本版本使用的二进制 sha256 为 `729aa213798b29478cc12d475fc5b6eb5a2c9507c4cde6b5a7e075cc73bf480d`。

## 已知限制

- 自启默认开启；关闭用 `/data/adb/xring-o3-host/config.env` 的 `AUTOSTART=0`。
- 安装时自动禁用旧 `malibridge` 模块；卸载时如果该标记由本模块创建，会自动恢复。
- `service.sh` 只负责 bridge 与别名，不启动容器；Droidspaces 模块负责容器。
- `boot.log` 每次开机追加，不轮转。
- 本模块不改变 SELinux 策略；进程以 KernelSU root 上下文运行。
