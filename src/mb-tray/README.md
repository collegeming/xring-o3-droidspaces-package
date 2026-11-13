# mb-tray（已废弃）

`mb-tray` 是早期的 StatusNotifierItem 托盘，用来显示/调整 MaliBridge 内存预算。
它的功能已经由 Noctalia 插件 `collegeming/mali-gpu` 接管：

- 顶栏图标悬浮显示 GPU 频率/温度、MaliBridge 预算与占用、MemAvailable、客户端占用、FPS
- 点击图标打开预算面板：总预算/单客户端/下限预设、立即应用、应用并保存、打开报告/日志

镜像构建不再安装或自启动 `mb-tray`。本目录只保留源码作为历史参考，不保证与镜像
同步；新功能请改 `src/noctalia-mali-gpu/`。
