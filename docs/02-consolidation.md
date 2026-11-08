# 整合与复用分析

本文说明当前 XRING-O3 Mali 方案的碎片化来源、可以合并的部分、跨发行版复用的边界，以及建议的仓库与发布结构。

## 1. 当前内容分布

| 位置 | 内容 | 问题 |
| --- | --- | --- |
| `collegeming/Droidspaces-Arch-Niri-rootfs-builder` | 设备 profile、Mali 栈安装器、card0/Anland unit、偏好阶段、host 包脚本 | 构建逻辑与设备补丁混在一起；补丁更新要改 builder |
| `collegeming/mesa-cross` | Mesa 候选、MaliBridge patch 的 CI | 与 builder 分离；补丁脚本和执行环境在另一处 |
| `Goldzxcbug/anland` | Anland 上游 fork；niri/Smithay patch、overlay、PKGBUILD | 我们只依赖其中两个补丁，但 fork 带 HUD 等无关改动 |
| `Goldzxcbug/droidspaces-package` | Anland/niri 包的 CI 与 Release | 包构建依赖该仓库；我们无法控制默认 tag/runner |
| 设备 `/opt` | 多个实验候选（Mesa、ICD、niri touch、mb-*） | 实验室状态；不是安装器布局，不能直接复刻 |
| 本机 `.tmp` | `mali-stack`/`mali-host` 归档、补丁、源码 | 未发布；换机器会丢失 |
| 设备 `/data/local/tmp` | host server、supervisor、Anland 别名 | 只存在于单台设备；没有安装包 |

结果：复刻者需要同时理解 builder 分支、两个 Goldzxcbug 仓库、设备上的实验目录和本机临时文件，才能拼出一台可用设备。

## 2. 目标结构

```text
上游基线（不 fork）
  SuperTurtleDev/anland                  Anland daemon/consumer/producer/niri backend
  lfdevs/mesa-for-android-container      Mesa 容器基线
  niri-wm/niri + Smithay/smithay         官方源码，构建时打补丁

本仓库（xring-o3-droidspaces-package）
  patches/                               Anland、Smithay、Mesa、MaliBridge 补丁
  host/                                  Android 主机侧脚本（mali-host 的源）
  src/                                   libgbm shim、libdrmfake、mbctl、mb-tray、zc-run
  scripts/                               mali-stack / mali-host 打包与校验
  docs/                                  架构、复刻、整合
  Releases                               mali-stack、mali-host

collegeming/Droidspaces-Arch-Niri-rootfs-builder
  xring-o3-mali                          镜像构建；消费本仓库的 Release 资产

niri 包仓库（建议 xring-o3-niri-package 或本仓库 workflow）
  发布 anland-niri-packages              Touch + AFBC 的 niri 包
```

## 3. 合并去向

| 内容 | 现在 | 建议归属 |
| --- | --- | --- |
| Anland Touch 补丁 | 本仓库 `patches/anland/` | 本仓库 |
| Smithay AFBC 补丁 | 本仓库 `patches/smithay/` | 本仓库 |
| Mesa dt-retire/kopper-retire 补丁脚本 | 本仓库 `patches/mesa/` | 本仓库 |
| MaliBridge 服务端/客户端补丁 | 本仓库 `patches/malibridge/` | 本仓库 |
| libgbm shim / libdrmfake / mbctl / mb-tray / zc-run 源码 | 本仓库 `src/` | 本仓库 |
| Android host 脚本 | 本仓库 `host/` | 本仓库；`xring-o3-mali-host` 由这里打包 |
| `mali-stack` 安装器、card0/anland unit、preferences | 本仓库 `rootfs/device/xring-o3/`；builder 按固定 commit 拉取 | 本仓库 |
| rootfs 镜像构建 | builder | builder |
| niri 包构建/发布 | Goldzxcbug/droidspaces-package | 建议新建 `xring-o3-niri-package` 或本仓库 workflow |

## 4. 跨发行版复用

### 4.1 可复用的层

| 层 | 复用范围 | 条件 |
| --- | --- | --- |
| Android 主机侧 | 所有 Android + Mali kbase 设备 | vendor Vulkan 与 `/dev/mali0` 存在；socket 路径可配 |
| Mali stack 的 Mesa/ICD/shim | glibc AArch64 发行版 | bundle 内库的符号版本与目标 glibc 兼容；目标使用 systemd 或手工启动 |
| zc-run / zc-sync | 任意 Linux | 纯 shell |
| mbctl | 任意 Linux | 能连 Unix socket |
| mb-tray | 有 GLib/GIO/DBus 的桌面 | 目标发行版需安装依赖，或改为静态构建 |
| systemd unit | systemd 发行版 | 不需要修改 |
| preferences | 仅 Arch + niri + Noctalia | 包含 pacman、Arch 镜像源、fcitx5/Rime |

### 4.2 设备差异

同一个 Mali stack 可以用于其他 Mali 设备，前提是改设备 profile：

| 项 | 作用 |
| --- | --- |
| GPU 节点 | `/dev/mali0` 或厂商节点 |
| DRM 主节点 | `card0` / `card1`，用于 EGL 与 Xwayland |
| Anland socket | 真实 `Net/anland-<hash>.sock`，由别名脚本解析 |
| Vendor 库路径 | `/vendor/lib64/egl/...` 或 `/vendor/lib64/...` |
| 容器名/rootfs | `host.env` 与 Droidspaces 配置 |
| 预算 | 按设备内存调整 `budget.conf` |

如果设备没有 `/dev/mali0`、没有 vendor Vulkan，或者只有 DRM render node，这套方案不适用；需要另做 PanVK/DRM 路径。

## 5. 打包与发布建议

### 5.1 四个发布物

| 发布物 | 内容 | 消费方 |
| --- | --- | --- |
| `xring-o3-mali-stack-<ver>.tar.zst` | 容器侧 Mesa/ICD/shim/工具/budget | rootfs 镜像构建 |
| `xring-o3-mali-host-<ver>.tar.zst` | Android 主机侧 server/脚本 | 设备安装 |
| `anland-niri-packages` | niri-anland 包 + xorg-xwayland + manifest | rootfs 镜像构建 |
| rootfs 镜像 | Arch + niri + Noctalia | 设备导入 |

### 5.2 一个引导脚本

建议在本仓库增加 `bootstrap`：

```text
bootstrap --serial <sn> --stack-version <ver> --host-version <ver>
  1. 检查设备：root、/dev/mali0、card0、Droidspaces、Anland
  2. 下载 mali-host，校验 SHA256，安装
  3. 启动 bridge，建立 Anland 别名，运行 verify-host
  4. 提示下一步：构建/导入 rootfs 镜像
```

这个脚本只做主机侧；rootfs 镜像仍由 builder 生成。目的不是把所有步骤自动化，而是消除“手工拷贝 + 改配置”的重复劳动。

### 5.3 版本锁定

所有发布物在 `manifest.env` 中记录：

```text
MALI_STACK_VERSION=
MALI_HOST_VERSION=
MALI_STACK_MESA_RUN=
MALI_STACK_VKBRIDGE_RUN=
MALI_STACK_VKBRIDGE_PATCHES=
```

镜像构建、host 安装、复刻文档都引用同一组版本，避免“设备上是 A、文档写 B”。

## 6. 建议的整合顺序

| 优先级 | 动作 | 收益 |
| --- | --- | --- |
| P0 | 在本仓库发布 `mali-stack` 与 `mali-host` | 复刻不再依赖本机 `.tmp` |
| P0 | 用本仓库 workflow 构建带 Touch/AFBC 的 niri 包 | 触摸与 Zen 零拷贝进入镜像 |
| P1 | 设备脚本已迁移到本仓库 `rootfs/device/xring-o3/`，builder 按固定 commit 拉取 | 设备脚本只有一个 review 入口 |
| P1 | 增加 `bootstrap` 主机侧脚本 | 减少手工步骤 |
| P2 | 把 `mb-tray` 改为静态或自带依赖 | 跨发行版可用 |
| P2 | 设备 profile 从 `xring-o3` 泛化为 `mali-device` 文件 | 其他 Mali 设备复用 |
| P2 | 每周上游同步 workflow：检查 niri/Smithay/lfdevs/MaliBridge 更新，套补丁并构建 | 跟上游而不是手工 bump |

## 7. 一个仓库还是两个

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| 一个仓库（本仓库） | 补丁、host、源码、包 CI 在一处；复刻只翻一个仓库 | 发布 workflow 与构建 workflow 共享写权限 |
| 两个仓库（本仓库 + `xring-o3-niri-package`） | 发布仓库权限更窄；niri 包可以独立 tag/回滚 | 跨仓库 checkout 与版本锁定 |

当前建议：**先用一个仓库**。当 niri 包需要独立发布节奏，或 Mesa/MaliBridge workflow 要被第二个项目复用时，再拆出包仓库。

## 8. 与 fork 方式的关系

| 方式 | 适合 | 不适合 |
| --- | --- | --- |
| patch 系列（本仓库） | 小范围修改：Touch 11 行、AFBC 42 行、Mesa/MaliBridge 补丁 | 大段新增代码、需要自动 merge 上游 |
| overlay（Anland 后端） | 新增模块，且属于上游项目 | 修改上游内部文件 |
| fork（Anland/Mesa 基线） | 需要持续 merge 上游、承载大量改动 | 只改几行却要背整个 fork |

当前选择：

- niri/Smithay：patch，不 fork。
- Anland：使用 `SuperTurtleDev/anland` 上游；我们的 Touch 补丁作为 patch。
- Mesa：使用 `lfdevs/mesa-for-android-container` 基线；我们的两个补丁作为脚本。
- MaliBridge：上游源码 + patch 脚本。
