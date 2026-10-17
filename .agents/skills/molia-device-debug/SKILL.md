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
tool/agent/seed.sh android|linux <cmd>  # 数据注入：favorites/history/session/mock-source/status/clear/restore
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
