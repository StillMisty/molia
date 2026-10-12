# 本地开发环境

## Linux 桌面运行要求

- 本地播放需要 `libmpv`：`sudo pacman -S --needed mpv`（Debian/Ubuntu: `libmpv2`）。
- **中文字体需要系统安装**（App 不内置 CJK 字体，保持包体精简）：
  `sudo pacman -S --needed wqy-microhei`（最小 1.7MB）或 `noto-fonts-cjk`（质量最好但 189MB）；
  否则中文界面显示为方块。
- 本地数据库（最近播放）依赖 sqflite FFI：`lib/data/database_factory_init*.dart` 已在
  Linux/Windows 自动 `sqfliteFfiInit`（Linux 用系统 libsqlite3）；缺 `xdg-user-dirs` 时
  `database_helper` 会回退到应用支持目录。
- **集成测试需要显示环境**：跑 `flutter test integration_test/... -d linux` 必须有 DISPLAY
  （官方要求，无显示时 App 起不来）；CI/无头环境用 `xvfb-run -a` 包装
  （`tool/agent/test.sh linux` 会自动检测并套上）。

## WSL 安卓调试（模拟器 / 热重载 / 截图）

Android 侧调试全部在 WSL 内完成（KVM 原生模拟器，不依赖 Windows / Android Studio）：

```bash
tool/agent/setup.sh        # 一次性：装 emulator + API 37 镜像 + 建 AVD（幂等）
tool/agent/emu.sh start    # 启动模拟器（默认 headless，阻塞到 boot 完成；--window 经 WSLg 显示）
tool/agent/app.sh run      # 后台 flutter run（默认 Android 模拟器；首次需 Gradle 构建）
tool/agent/app.sh run -d linux   # Linux 桌面热重载（免模拟器；无 DISPLAY 自动 xvfb-run）
tool/agent/app.sh reload   # 热重载；restart = 热重启（无 TTY 走 --pid-file + SIGUSR1/2）
tool/agent/app.sh status   # pid / 设备 / VM Service / 日志路径
tool/agent/shot.sh [name]  # 截图 → /tmp/opencode/molia/shots/*.png（供 agent 直接读图）
tool/agent/ui.sh layout|tap|swipe|text|key|launch|force-stop
tool/agent/test.sh android # 集成测试（官方 flutter test 路径；自动构建/安装 debug APK，跑完卸载）
tool/agent/emu.sh stop     # 停止模拟器（app.sh stop 只停 flutter run）
```

- `app.sh` 把运行设备记入 `/tmp/opencode/molia/flutter-run.device`，`reload`/`stop`/`status`
  均按它操作：`-d linux` 起的桌面会话不会误发给 adb，反之亦然。
- 模拟器默认 16 KB 页（`google_apis_ps16k` 镜像，`emu.sh status` 会打印页大小）；
  回 4 KB 需另建 AVD（`-k "system-images;android-37.0;google_apis;x86_64"`）并 `AVD_NAME=... emu.sh start`。
- 日志 / 截图 / pid 统一放在 `/tmp/opencode/molia`（临时目录，重启可清）；集成测试日志为
  `it-<platform>-<时间戳>.log`，失败时脚本自动回显尾部 40 行。
- Flutter semantics 节点可能不完整：视觉定位用 `shot.sh --annotate` 生成带编号标注的截图，
  再用 `ui.sh resolve 截图.png "#3"` 解析为 `tap X Y`。
- 输入文本前确保输入框已聚焦（`ui.sh text` 把空格转成 `%s`）。

### Android 集成测试

`tool/agent/test.sh android` 走官方 `flutter test integration_test/...` 路径（不是截图点按）：

- 不需要先 `flutter build apk`：flutter test 自己构建 debug APK 并安装，跑完默认卸载
  （要保留安装态排查用 `--no-uninstall`）；失败时设备侧异常会被捕获并让退出码非零；
- 引擎导入/搜索/取链/歌词与设置页 UI 全覆盖；**播放用例在 Android 跳过**
  （模拟器音频不可靠，播放验证交给 Linux 桌面）；
- 默认墙钟超时 30min（首次 Gradle 构建），冷启动慢的机器可 `--timeout` 放宽；
- 等价裸命令：`flutter test integration_test/lx_engine_integration_test.dart -d emulator-5554`。
