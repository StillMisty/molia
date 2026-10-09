# 本地开发环境

## Linux 桌面运行要求

- 本地播放需要 `libmpv`：`sudo pacman -S --needed mpv`（Debian/Ubuntu: `libmpv2`）。
- **中文字体需要系统安装**（App 不内置 CJK 字体，保持包体精简）：
  `sudo pacman -S --needed wqy-microhei`（最小 1.7MB）或 `noto-fonts-cjk`（质量最好但 189MB）；
  否则中文界面显示为方块。
- 本地数据库（最近播放）依赖 sqflite FFI：`lib/data/database_factory_init*.dart` 已在
  Linux/Windows 自动 `sqfliteFfiInit`（Linux 用系统 libsqlite3）；缺 `xdg-user-dirs` 时
  `database_helper` 会回退到应用支持目录。

## WSL 安卓调试（模拟器 / 热重载 / 截图）

Android 侧调试全部在 WSL 内完成（KVM 原生模拟器，不依赖 Windows / Android Studio）：

```bash
tool/agent/setup.sh        # 一次性：装 emulator + API 37 镜像 + 建 AVD（幂等）
tool/agent/emu.sh start    # 启动模拟器（默认 headless，阻塞到 boot 完成；--window 经 WSLg 显示）
tool/agent/app.sh run      # 后台 flutter run（首次需 Gradle 构建）
tool/agent/app.sh reload   # 热重载；restart = 热重启（无 TTY 走 --pid-file + SIGUSR1/2）
tool/agent/shot.sh [name]  # 截图 → /tmp/opencode/molia/shots/*.png（供 agent 直接读图）
tool/agent/ui.sh layout|tap|swipe|text|key|launch|force-stop
tool/agent/emu.sh stop     # 停止模拟器（app.sh stop 只停 flutter run）
```

- 日志 / 截图 / pid 统一放在 `/tmp/opencode/molia`（临时目录，重启可清）。
- Flutter semantics 节点可能不完整：视觉定位用 `shot.sh --annotate` 生成带编号标注的截图，
  再用 `ui.sh resolve 截图.png "#3"` 解析为 `tap X Y`。
- 输入文本前确保输入框已聚焦（`ui.sh text` 把空格转成 `%s`）。
