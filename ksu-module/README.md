# KernelSU 模块

本目录下每个子目录是一个独立的 KernelSU 模块，各有自己的 `module.prop`、
构建脚本和 README。它们互相独立安装，也可以同时装。

| 子目录 | 模块 id | 作用 | 是否必需 |
|---|---|---|---|
| `mali-host/` | `xring_o3_mali_host` | MaliBridge host 侧 payload（`vkbridge-server` + host 脚本），GPU 桌面必需；**默认开机自启**（`AUTOSTART=1`，置 0 可关） | 是 |
| `gold-keyboard/` | `Gold_Keyboardremaps` | 键盘重映射（上游 Gold Keyboard Remaps），把虚拟键盘伪装成原生 `15d9:00a3`，让 MIUI 截图/音量/亮度快捷键可用 | 可选 |

## 构建

两个模块都由本仓库的 GitHub workflow 构建，不需要本地 NDK：

| 模块 | workflow | 产物 |
|---|---|---|
| mali-host | `.github/workflows/build-malibridge.yml`（`server` + `publish` 输入） | `xring-o3-mali-host-ksu-<V>.zip` |
| gold-keyboard | `.github/workflows/build-gold-keyboard-ksu.yml` | `Gold_Keyboardremaps-<V>-yingtian.zip` |

本地手动构建仍可行，见各自 README（需要 Android NDK；宿主 gcc 产出的二进制
在 Android 上无法运行——glibc vs bionic）。

## 安装顺序

1. `mali-host`（GPU 桌面依赖它，装完重启即自启）
2. `gold-keyboard`（可选，需要原生快捷键/键盘 Fn 映射时）

两者都通过 KernelSU Manager → 模块 → 从本地安装 → 重启生效。

## 与 Anland 输入源的配合

`gold-keyboard` 会 `EVIOCGRAB` 物理键盘（`event9`），而 Anland 默认输入源
`direct_event_nodes` 也直接 grab 同一节点，两者互斥（`EBUSY`）。同时使用时
必须把 Anland 输入源切成 `direct_plus_gold_keyboard`，详见
[`gold-keyboard/README.md`](gold-keyboard/README.md)。
