---
name: Molia 设备调试
description: 在 Android 模拟器或 Linux 桌面跑 Molia、热重载、截图、注入测试数据时使用。触发词：模拟器、emulator、真机、热重载、hot reload、截图、seed、UI 操作、看日志。
---

# Molia 设备调试

```bash
tool/agent/emu.sh start        # 启动模拟器（默认 headless，阻塞到 boot 完成；--window 经 WSLg 显示）
tool/agent/app.sh run          # 后台 flutter run（默认 Android；首次需 Gradle 构建）
tool/agent/app.sh run -d linux # Linux 桌面热重载（免模拟器；无 DISPLAY 自动 xvfb-run）
tool/agent/app.sh reload       # 热重载；restart 热重启；status 看 pid / 设备 / VM Service / 日志路径
tool/agent/shot.sh [name]      # 截图 → /tmp/opencode/molia/shots/*.png（可直接读图）
tool/agent/ui.sh layout|tap|swipe|text|key|launch|force-stop
tool/agent/seed.sh android|linux <cmd>  # 数据注入：favorites/covers/history/session/mock-source/status/clear/restore
tool/agent/emu.sh stop         # 停止模拟器（app.sh stop 只停 flutter run）
```

## 要点

- 热重载边界：UI / 简单方法 → hot reload；`initState`、全局静态状态、`main()` → hot restart；
  `test/**`、注释与空白不触发；
- `app.sh` 按设备记录会话（`-d linux` 的桌面会话不会误发给 adb，反之亦然）；
- 日志 / 截图 / pid 统一在 `/tmp/opencode/molia`；集成测试失败时脚本自动回显日志尾部；
- 视觉定位：`shot.sh --annotate` 生成带编号标注的截图，再 `ui.sh resolve 截图.png "#3"` 得到坐标；
  输入文本前确保输入框已聚焦；
- 模拟器默认 16 KB 页；镜像、AVD 与 WSL 限制等细节见 `docs/dev_environment.md`（权威出处）。
- 新 worktree / seed 的 WAL 与大数据量 / `covers` 封面 fixture / Android 内存采样：
  见 `molia-perf-tooling` skill。
- 停应用只用 `tool/agent/app.sh stop`；不要 `pkill -f <路径>`——它会把调用它的 shell
  一起匹配掉（本仓踩过两次）。

## Linux / WSLg

- Linux 桌面优先后台跑：`tool/agent/app.sh run -d linux`（setsid + pid-file，不占会话）；
  不要前台裸 `flutter run`。
- 窗口黑屏先看启动日志，不要先查 GPU：`tool/agent/app.sh log` 或
  `tool/agent/smoke.sh linux`。首帧前出现 `Unhandled Exception`（尤其
  `Tried to use Provider with a subtype`）说明 `main()` 在 `runApp` 前中断，
  窗口不会显示；`Provider` 暴露窄接口时改用 `InheritedProvider`。
- `shot.sh` 目前只支持 Android。Linux 截图用 Xvfb + `xdotool` + `ffmpeg x11grab`
  （`DISPLAY=:101`，`GDK_BACKEND=x11`，`LIBGL_ALWAYS_SOFTWARE=1`，窗口几何由
  `xdotool getwindowgeometry --shell` 取）；不要新增 Windows PowerShell 截图脚本。
- 详细命令与 WSLg 环境变量见 `docs/dev_environment.md` 的「WSL 桌面」一节。

## UI 视觉改动

改共享工具栏 / 选择器 / 弹层时，先渲染 **360 和 640** 两个宽度（`flutter-add-widget-preview`
或 app + 截图），确认：当前渠道名完整、弹层不只剩「前两个字 + 省略号」、chip 不把输入区挤窄、
选中 / 未选中行高稳定。评审或提交时附 compact + wide 两张图；只靠 `didExceedMaxLines`
发现不了视觉问题。
