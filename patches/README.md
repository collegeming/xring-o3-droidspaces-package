# 补丁索引

| 目录 | 目标源码 | 固定基线 | 应用方式 |
| --- | --- | --- | --- |
| `anland/0001-touch-seat.patch` | `SuperTurtleDev/anland` 的 `producers/niri/anland_backend` | `legacy` @ `a23ccd8`（或其后继） | `git apply` 到 Anland 仓库 |
| `smithay/0001-afbc-linear-size-check.patch` | Anland 仓库内的 `producers/niri/Arch_v5/smithay.patch` 与 `sources.json` | 同左 | `git apply` 到 Anland 仓库 |
| `mesa/mesa-dt-retire-patch.py` | `taowen/mesa` / `lfdevs/mesa-for-android-container` | `98f3d6229d61452cef80f8563af7c56ae599dc14` | 按脚本头部说明运行 |
| `mesa/mesa-kopper-lifecycle-patch.py` | 同上 | 同上 | kopper-retire 的前置补丁，先运行 |
| `mesa/mesa-kopper-retire-patch.py` | 同上 | 同上 | 按脚本头部说明运行 |
| `malibridge/malibridge-*.py` | `ASEbrahim/MaliBridge` | 各脚本头部记录的 commit | 按脚本头部说明运行 |
| `malibridge/afbc/0001-afbc-export-metadata.patch` | `ASEbrahim/MaliBridge` | `3cd7a2b` | `git am` 或 `git apply` |

## Anland / Smithay

两个补丁按顺序应用到 Anland 仓库：

```sh
git clone https://github.com/SuperTurtleDev/anland.git
git -C anland checkout legacy
git -C anland apply patches/anland/0001-touch-seat.patch
git -C anland apply patches/smithay/0001-afbc-linear-size-check.patch
```

第二个补丁修改的是 Anland 的 `smithay.patch` 文件，不是 Smithay 源码。`producers/niri/Arch_v5/PKGBUILD` 在构建时把该文件应用到固定版本的 Smithay，因此 Smithay 源码本身不需要 fork。

`git apply` 可能对 `smithay.patch` 的上下文行报 trailing whitespace；这是 unified diff 的单空格上下文标记，不是内容错误。

## Mesa

两个脚本分别生成 dt-retire 与 kopper-retire 的 Mesa 补丁。脚本会校验固定 commit，不匹配时拒绝执行。

`mesa-kopper-retire-patch.py` 校验的是打过生命周期诊断后的源码，因此必须先运行
`mesa-kopper-lifecycle-patch.py`；顺序相反时脚本会以源码哈希不匹配直接失败。

## MaliBridge

- `malibridge-mem-budget-patch.py`：服务端内存预算与 control socket。
- `malibridge-wsi-lifecycle-patch.py`：Wayland WSI 生命周期。
- `malibridge-wl-gone-patch.py`：wl_surface 销毁补偿，配合 `malibridge-wl-gone-shim.c`。
- `malibridge-format-capacity-patch.py`：dmabuf 格式容量 256 → 2048。
- `malibridge-hook2-patch.py`：去掉 teardown 时的无条件 `attach(NULL)+commit`。
- `afbc/0001-afbc-export-metadata.patch`：服务端按导出修饰符匹配导入，保留 AFBC 布局。

`malibridge-wl-gone-shim.c` 编译为 `libvkb_wl_gone.so`，由 Noctalia 包装器 `LD_PRELOAD`。
