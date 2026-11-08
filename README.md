# XRING-O3 Droidspaces / Mali 复刻包

面向 Xiaomi Pad 9 Pro Max（XRING-O3，Mali-G2-Ultra-NX）的 Droidspaces + Arch + niri + Noctalia GPU 复刻资料。

仓库集中存放设备相关补丁、Android 主机侧脚本、打包工具和复刻文档。目标是把“到处翻补丁、手工拷文件、逐台改配置”收敛成可校验的资产：补丁在一个仓库、主机侧一个安装包、rootfs 一个 Mali 栈包、镜像由 builder 生成。

## 复刻需要什么

| 资产 | 作用 | 当前状态 |
| --- | --- | --- |
| `mali-host-<version>.tar.zst` | Android 主机侧：`vkbridge-server`、supervisor、启动/停止、Anland 别名、验证脚本 | 本地已生成并校验，未发布 |
| `mali-stack-<version>.tar.zst` | 容器侧：Mesa、MaliBridge ICD、wl-gone shim、libgbm、libdrmfake、zc-run、mbctl、mb-tray、budget.conf | 本地 v2 已生成并校验，未发布 |
| `niri-anland` 包 | 带 Touch seat 与 Smithay AFBC 补丁的 niri | 补丁已在本仓库；包尚未构建 |
| rootfs 镜像 | 由 `collegeming/Droidspaces-Arch-Niri-rootfs-builder` 的 `xring-o3-mali` 分支构建 | 分支已推送，Mali 时代镜像未发布 |
| Droidspaces 7.1.0 APK | 容器运行时 | 上游发布 |
| Anland APK | 显示 daemon 与 consumer | 上游发布 |

## 目录

| 路径 | 内容 |
| --- | --- |
| `patches/anland/` | Anland 后端补丁：Touch seat |
| `patches/smithay/` | Smithay 补丁：AFBC 线性尺寸校验 |
| `patches/mesa/` | Mesa dt-retire / kopper-retire 补丁脚本 |
| `patches/malibridge/` | MaliBridge 服务端/客户端补丁、wl-gone shim、AFBC 导出元数据补丁 |
| `host/` | Android 主机侧脚本（server 安装、supervisor、Anland 别名、验证） |
| `src/libgbm-shim/` | 38 符号 `libgbm` 垫片源码 |
| `src/libdrmfake/` | `libdrmfake` 源码 |
| `src/mbctl/` | 内存预算控制 CLI 源码 |
| `src/mb-tray/` | SNI 托盘源码 |
| `src/zc-run/` | 按工具包注入 GPU 环境的启动器 |
| `scripts/` | `mali-host` / `mali-stack` 打包与校验脚本 |
| `docs/` | 架构、复刻步骤、整合分析 |

## 文档

- [架构与组件清单](docs/00-architecture.md)
- [复刻步骤](docs/01-reproduce.md)
- [整合与复用分析](docs/02-consolidation.md)

## 补丁应用顺序

Anland/Smithay：

```sh
git clone https://github.com/SuperTurtleDev/anland.git
git -C anland checkout legacy
git -C anland apply patches/anland/0001-touch-seat.patch
git -C anland apply patches/smithay/0001-afbc-linear-size-check.patch
```

第二个补丁修改的是 Anland 仓库内的 `producers/niri/Arch_v5/smithay.patch`，不是 Smithay 源码本身。构建时由 PKGBUILD 把它应用到固定版本的 Smithay。

MaliBridge 与 Mesa 补丁是 Python 脚本，按脚本头部记录的固定 commit 运行；具体用法见 `patches/README.md`。

## 状态说明

- `mali-stack` 与 `mali-host` 的 SHA-256、文件清单和校验结果记录在 `docs/00-architecture.md`。
- 发布前先用 `scripts/verify-mali-stack.sh` 和 `scripts/make-host-bundle.sh` 校验本地包。
- `collegeming/mesa-cross` 保持现状，不在本仓库改动；新的 Mesa/MaliBridge 构建流程在本仓库的 `patches/` 和后续 workflow 中维护。
