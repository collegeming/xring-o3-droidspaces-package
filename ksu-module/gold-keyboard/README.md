# Gold Keyboard Remaps（本设备定制）

[Xiaomi Pad 9 Pro Max](https://www.mi.com/) 的物理键盘有两个 evdev 节点：

| 节点 | VID:PID | 名称 | 内容 |
|---|---|---|---|
| `event9` | `15d9:00a3` | Xiaomi Keyboard | 字母、F1–F12、SYSRQ |
| `event12` | `15d9:00a4` | Xiaomi Consumer | 亮度、音量、媒体键 |

Gold Keyboard Remaps（上游 [`Goldzxcbug/Gold_Keyboardremaps`](https://github.com/Goldzxcbug/Gold_Keyboardremaps)）
通过 `EVIOCGRAB` 拦截物理键盘、用 `/dev/uinput` 造一个虚拟设备转发（可改写）按键，
从而给键盘加上 Fn 组合键、启动器等能力。

## 为什么要本目录

上游把虚拟设备的 VID:PID 设成 `0xffff:0xffff`，刻意避开真实硬件。但 **MIUI 只为
原生键盘 `15d9:00a3` 启用系统级快捷键**——截图、音量、亮度、勿扰、小爱、锁屏。
ID 不匹配时 MIUI 直接跳过该设备，这些键全部失效。

因此需要一个常量级别的改写。本目录把它保存为 patch，构建时应用，不保存上游源码
副本（避免和上游分叉后长期失同步）。

```
patches/0001-xiaomi-15d9-00a3-identity.patch   虚拟设备身份改写（唯一改动）
config/config.conf                             默认映射：Fn+数字→F1–F12、启动器
```

## 构建

由 `.github/workflows/build-gold-keyboard-ksu.yml` 完成，不需要本地 NDK：

- checkout 上游固定 tag（`v1.1.1`，commit 做精确校验）
- 应用 `patches/*.patch`（应用前 `--check`，应用后校验两个常量）
- 调用上游自带的 `.github/workflows/manual-build.yml` 同款步骤：NDK clang 编
  `fn_remap.c`、javac+d8 编 `ColorOS.java`、打包模块 zip
- 上传 artifact（可选发布 Release）

本地手动构建也支持（需要 NDK r27c 或更新）：

```sh
GOLD_SRC=/path/to/Gold_Keyboardremaps \
  ksu-module/gold-keyboard/build-module.sh --ndk /path/to/android-ndk-r27c
```

## 安装

1. KernelSU Manager → 模块 → 从本地安装 → 选 zip
2. 重启
3. 验证身份（应显示 `15d9:00a3`）：
   ```sh
   adb shell getevent -pl | grep -A4 'Gold Keyboardremaps'
   ```

## 与 Anland 的配合

Anland 沉浸式模式要抓取按键转发给容器桌面。默认输入源 `direct_event_nodes` 会
直接 grab 物理 `event9`，与 Gold 争用同一节点（`EVIOCGRAB` 返回 `EBUSY`），
两者不能共存。

必须把 Anland 输入源切到 **`direct_plus_gold_keyboard`**：触摸/指针/手柄直连，
键盘经 Gold 的虚拟设备。切换后：

- Anland 进入沉浸式 → 写 `/data/adb/modules/Gold_Keyboardremaps/anland-profile`
  → Gold 每秒轮询到该文件 → 切到 Anland 配置（顶排 `F1`–`F12`，`Fn`+键出原键）
- 退出沉浸式 → 删除该文件 → Gold 回到默认直通，Android 原生快捷键恢复

## 已验证按键（伪装 `15d9:00a3` 后）

| 功能 | evdev key | 结果 |
|---|---:|---|
| 截图 | `99` SYSRQ | MIUI 原生截图 + 动画 |
| 音量 ± | `115` / `114` | 生效 |
| 亮度 ± | `225` / `224` | 生效 |
| 静音 | `113` | 生效 |
| 麦克风静音 | `190` F20 | 生效 |
| 勿扰 / 小爱 / 锁屏 | `191`–`194` | 生效 |

注意：`120` 是 `KEY_RECENTAPPS`（不是 SYSRQ），会打开最近任务。
`0xffff:0xffff` + `99` 完全无反应，是这套 patch 存在的直接证据。

## 依赖与风险

- 需要 `/dev/uinput`。KernelSU 模块在 `post-fs-data` 阶段准备节点，`service.sh`
  启动守护进程。若设备策略禁止模块创建该节点，需单独评估 sepolicy。
- 模块会 grab 物理键盘；守护进程异常退出时输入会中断，`service.sh` 带重试。
- 与其它 grab 键盘的模块（如旧版 Anland 输入直连）冲突，见上文切换说明。
