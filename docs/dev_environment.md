# 本地开发环境

## Linux 桌面运行要求

- 本地播放需要 `libmpv`：`sudo pacman -S --needed mpv`（Debian/Ubuntu: `libmpv2`）。
- **桌面托盘（Linux/Windows）需要 X11 / Xi 开发文件**参与构建（nativeapi 的
  build hook 经 pkg-config 链接 `gtk+-3.0 x11 xi`；Arch 随 `libx11` / `libxi`
  提供，Debian/Ubuntu 需 `libx11-dev libxi-dev`）。运行期依赖这些系统库的
  常规共享版本（任何桌面都有）；无 StatusNotifier 宿主时图标不显示（GNOME
  需 AppIndicator 扩展），应用自动降级、不影响其余功能。
- **中文字体需要系统安装**（App 不内置 CJK 字体，保持包体精简）：
  `sudo pacman -S --needed wqy-microhei`（最小 1.7MB）或 `noto-fonts-cjk`（质量最好但 189MB）；
  否则中文界面显示为方块。
- 本地数据库（最近播放 / 资料库 / 听歌统计）走 drift：原生 SQLite 由
  `sqlite3` 的 Dart build hooks 提供（`flutter test` / 构建时自动生成，无需
  `sqlite3_flutter_libs`）；库文件在应用支持目录（Windows
  `%APPDATA%\top.stillmisty\molia`、Linux `~/.local/share/top.stillmisty.molia`）。
  改表结构必须写增量迁移：提 `schemaVersion` 后跑 `build_runner` +
  `drift_dev make-migrations`（schema 快照）并用 `stepByStep` 保留数据（ADR-0005）。
- **集成测试默认 headless**：`tool/agent/test.sh linux` 无条件套 `xvfb-run -a`
  （并强制 `GDK_BACKEND=x11`、去掉 `WAYLAND_DISPLAY`——只改 DISPLAY 挡不住 GTK 走 WSLg
  Wayland，窗口照样弹）；要肉眼观察加 `--window`。等价裸命令
  `flutter test integration_test/... -d linux` 必须有 DISPLAY（官方要求，无显示时 App 起不来）；
  缺 `xvfb-run` 时 `sudo pacman -S xorg-server-xvfb`。

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
tool/agent/seed.sh android favorites|history|session|mock-source|status|clear|restore
                           # 数据注入：收藏 / 最近播放 / 恢复会话 / mock 音源（见下）
tool/agent/test.sh android # 集成测试（官方 flutter test 路径；自动构建/安装 debug APK，跑完卸载）
tool/agent/emu.sh stop     # 停止模拟器（app.sh stop 只停 flutter run）
```

- `app.sh` 把运行设备记入 `/tmp/opencode/molia/flutter-run.device`，`reload`/`stop`/`status`
  均按它操作：`-d linux` 起的桌面会话不会误发给 adb，反之亦然。
- 模拟器默认 16 KB 页（`google_apis_ps16k` 镜像，`emu.sh status` 会打印页大小）；
  回 4 KB 需另建 AVD（`-k "system-images;android-37.0;google_apis;x86_64"`）并 `AVD_NAME=... emu.sh start`。
- 日志 / 截图 / pid 统一放在 `/tmp/opencode/molia`（临时目录，重启可清）；集成测试日志为
  `it-<platform>-<时间戳>.log`，失败时脚本自动回显尾部 40 行。Linux 集成测试默认跑在
  Xvfb 虚拟显示上（`test.sh linux --window` 才上真实显示，WSLg 下会弹窗）。
- Flutter semantics 节点可能不完整：视觉定位用 `shot.sh --annotate` 生成带编号标注的截图，
  再用 `ui.sh resolve 截图.png "#3"` 解析为 `tap X Y`。
- 输入文本前确保输入框已聚焦（`ui.sh text` 把空格转成 `%s`）。

### 数据注入（seed.sh）

`tool/agent/seed.sh <android|linux> <command>` 把「手工造数据」固化成可复用脚本
（bash + python3 + adb；写入前自动备份到 `/tmp/opencode/molia/seed-backup/latest`）：

```bash
tool/agent/seed.sh android favorites 3   # 注入 __favorites__ + 3 首固定样例（含超长标题）
tool/agent/seed.sh android history 5     # 注入最近播放 5 条
tool/agent/seed.sh android session       # 写恢复会话（3 首 mock 曲目 / 下标 1 / 进度 20s）
tool/agent/seed.sh android mock-source   # 生成 mock LX 脚本 + WAV，起宿主机 http 服务并激活音源
tool/agent/seed.sh android lang zh       # 切换应用语言（截图对照用；system = 跟随系统）
tool/agent/seed.sh android status        # 三份数据的位置与摘要
tool/agent/seed.sh android clear         # 清掉注入的收藏/历史/会话
tool/agent/seed.sh android restore       # 用最近一次备份还原（第一次注入前的状态）
```

- `mock-source` 的音频 URL 在 Android 上用 `127.0.0.1:<port>` + `adb reverse`
  （模拟器 NAT 的 `10.0.2.2` 在应用进程内实测会连接超时）、Linux 用 `127.0.0.1:<port>`；
  脚本直接写 `lx_sources.json` 并置 activeId（绕开应用内 Import from URL）。
- Android 写入前自动 `force-stop`（SharedPreferences 有内存缓存，运行中写入会被覆盖）；
  Linux 请先退出应用，且会改动 `~/.local/share/top.stillmisty.molia/` 下的真实数据。
- 数据位置：Android `/data/data/top.stillmisty.molia/{app_flutter/molia_database.sqlite,
  shared_prefs/FlutterSharedPreferences.xml, files/lx_sources.json}`；
  Linux `~/.local/share/top.stillmisty.molia/`（DB 同处）。

### Android 集成测试

`tool/agent/test.sh android` 走官方 `flutter test integration_test/...` 路径（不是截图点按）：

- 不需要先 `flutter build apk`：flutter test 自己构建 debug APK 并安装，跑完默认卸载
  （要保留安装态排查用 `--no-uninstall`）；失败时设备侧异常会被捕获并让退出码非零；
- 引擎导入/搜索/取链/歌词与设置页 UI 全覆盖；**播放用例在 Android 跳过**
  （模拟器音频不可靠，播放验证交给 Linux 桌面）；
- 默认墙钟超时 30min（首次 Gradle 构建），冷启动慢的机器可 `--timeout` 放宽；
- 等价裸命令：`flutter test integration_test/lx_engine_integration_test.dart -d emulator-5554`。
