# Noctalia Mali GPU widget (`collegeming/mali-gpu`)

Noctalia 5.x 的 Luau 插件。默认只在顶栏显示一个小图标，不显示数字；鼠标悬浮时显示合并后的信息：

- GPU 型号、当前/最大频率、温度
- MaliBridge 已用/总预算
- MemAvailable、客户端数量、前 3 个客户端的 PID/占用
- 当前预算（总预算 / 单客户端 / 可用内存下限）
- 每应用 FPS（`/opt/mb-sock/malibridge-report.json` 的 `fps_p50`）
- 用量超过总预算时给出 WARN 行

这些内容合并了旧 `mb-tray` SNI 悬浮提示的预算信息。插件运行期间会刷新
`/run/user/1000/mb-budget-ui.plugin` 心跳；`mb-tray` 检测到心跳后自动撤下自己的
托盘项，避免两个图标重复。插件停止时 `onExit` 删除心跳，`mb-tray` 在超时后接管，
作为没有 Noctalia 插件时的兜底。

插件只读本机 sysfs/procfs 和 MaliBridge 本地 socket，不联网。

## 预算面板（原 mb-tray 菜单）

点击顶栏图标打开 `collegeming/mali-gpu:budget` 面板，复刻 mb-tray 的 SNI 菜单能力：

- 总预算 2/3/4/6/8 G、单客户端 1/2/3/4 G、MemAvailable 下限 1.5/2/2.5/3 G
- 立即应用、应用并保存（`mbctl set ... --persist`）
- 打开报告 / 打开日志

面板写入仍然走 `mbctl` 和同一个 control socket；Noctalia 插件不可用时会回退到
mb-tray 的托盘菜单。



## 为什么没有“GPU 占用率”

Mali kbase 的 debugfs `mali0/dvfs_utilization` 在本机是冻结/下溢的计数（渲染负载下也不变化），
kbase 也没有 `utilization` 节点。插件因此不伪造百分比，只显示频率、温度、内存和 FPS。
如果后续内核/驱动提供可用的 busy 计数，可在 `widget.luau` 里加一项。

## 安装

```sh
mkdir -p ~/.local/share/noctalia/plugins
cp -a mali-gpu ~/.local/share/noctalia/plugins/
```

在 `~/.local/state/noctalia/settings.toml` 启用并添加实例：

```toml
[plugins]
enabled = [ "collegeming/mali-gpu" ]

[bar.default]
center = [ "workspaces", "taskbar", "gpu" ]

[widget.gpu]
type = "collegeming/mali-gpu:status"
```

重启 Noctalia 或在 设置 → 插件 中启用。

## 数据源

| 指标 | 路径 |
| --- | --- |
| 型号 | `/sys/class/misc/mali0/device/gpuinfo` |
| 频率 | `/sys/class/devfreq/gpufreq_core/{cur_freq,max_freq}` |
| 温度 | `/sys/class/thermal/thermal_zone*/temp`（`type` 含 `gpu`，优先 `gpu-ss-max`） |
| 桥接显存 | `mbctl status --json`（`/opt/mali-stack/current/bin/mbctl`） |
| 每应用 FPS | `/opt/mb-sock/malibridge-report.json` |

## 兼容性

- `plugin_api = 3`，只使用 `readFile`/`listDir`/`runAsync`/`json`/`setUpdateInterval`/`setText`/`setTooltip`。
- 适用于 Noctalia 5.4.1（archniri24）验证；无 Noctalia 时不影响其它桌面。
