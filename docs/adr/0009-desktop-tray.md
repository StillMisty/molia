# ADR-0009：桌面托盘（常驻图标 + 关闭到托盘 + 托盘菜单）

- 状态：已采纳
- 日期：2026-10-15
- 相关：`lib/services/window/app_tray.dart` / `app_tray_stub.dart` / `app_tray_io.dart`、
  `lib/services/window/tray_menu_labels.dart`、`lib/services/window/tray_settings.dart`、
  `lib/services/window/window_chrome.dart` / `window_chrome_io.dart` / `window_chrome_stub.dart`、
  `lib/pages/general_settings_page.dart`、`lib/main.dart`、`assets/icons/tray_icon.png`、
  `test/architecture/tray_import_test.dart`、`integration_test/lx_engine_integration_test.dart`、
  ADR-0004、`docs/pitfalls.md` #30 / #35

## 背景

Linux / Windows 桌面端此前只有「关掉窗口 = 进程退出」一条路径（顶栏关闭键与
系统关闭都归 `window_manager.close()`）：用户在听歌时误关窗口就断了播放，
也没有「后台运行 + 随时唤起」的入口。移动端有系统媒体通知承担同类角色，
桌面端需要托盘补上。

约束与事实：

- 仓库没有 macOS 工程（ADR-0004 同样不管 macOS），平台范围 = Linux + Windows；
- UI 不得直接 import 会毁掉 Web 构建的包（ADR-0004 决策 4 / pitfalls #30）：
  托盘包的 Dart 代码同样 import `dart:io` 与 `dart:ffi`；
- 更新安装（ADR-0006）依赖「点关闭 = 真的退出进程」来完成重启替换，
  关闭行为一旦可拦截，必须给安装器留出无视策略的退出口；
- 设备本地键不登记 `SettingsRegistry`（跨设备同步会同步到不支持托盘的
  移动端/Web，语义打架）。

## 决策

1. **选 `tray_manager ^0.8.0`**（2026-10-08 发布，nativeapi 重写版）。
   证据：要求 Flutter 3.47 / Dart 3.13，与本仓工具链一致；Linux 走 D-Bus
   StatusNotifierItem，**不需要** `libayatana-appindicator3-dev`（构建机只需
   GTK3 / X11 / Xi 开发文件）；Windows 同时接受 `.png` 与 `.ico`；底层
   `cnativeapi` 用 build hook 编译 C++ 核，本仓 `sqlite3` 已在跑同一机制。
   排除项：`tray_manager 0.5.3`（旧 API 官方标记弃用，未来仍要迁移）、
   `system_tray`（久未维护）、自写 SNI / `Shell_NotifyIcon`（维护成本不值）。
   若 0.8.0 实装遇阻，回退路径是 0.5.3 legacy API（代价：Linux 构建机需装
   libayatana-appindicator3-dev）。
2. **托盘图标常驻**（Linux / Windows），移动端 / Web / macOS 走 stub
   （`isSupported=false`，全空操作）；设置页据此隐藏入口。
3. **关闭请求拦截**：`WindowChrome.ensureInitialized()` 里
   `windowManager.setPreventClose(true)`，`WindowListener.onWindowClose`
   把控制权交回 Dart 策略（组合根注入）：设置开 **且有托盘宿主** → `hide()`；
   否则 → 退出。未注入策略时（如集成测试直接调 ensureInitialized）保持历史
   行为直接退出，避免「点了关闭没反应」。
   宿主判定见第 10 条：没有宿主（GNOME 未装扩展等）时隐藏窗口 = 藏进一个
   没有找回入口的状态，因此宁可退回直接退出。
4. **真正退出统一 `WindowChrome.quit()`**（先 `setPreventClose(false)` 再
   `destroy()`）：托盘「退出」与更新安装器的 `quitApp` 都走组合根的
   `quitApp()`——先 flush 播放会话与听歌统计（等价于进入后台的落盘），
   再强退。`quitApp` 是唯一允许无视关闭策略的出口。
5. **菜单**：显示主窗口 ｜ 播放/暂停（按播放态切换文案，无曲目禁用）｜
   上一首 ｜ 下一首 ｜ 收藏/取消收藏（按收藏态切换文案，无曲目禁用）｜ 退出。
   tooltip = 品牌名（可自定义）＋ 有曲目时附「曲名 - 歌手」。
   左键单击 / 双击图标唤起窗口（Windows 单击即 `TrayIconClickedEvent`；
   Linux 由宿主上报 `Activate`——KDE 计入单击、GNOME 扩展计入双击，
   两者都归到「唤起窗口」）。菜单状态只在值变化时下发原生调用；文案由
   组合根按当前语言解析（`TrayMenuLabels`）。
6. **架构约束与 window_chrome 同构**：`app_tray.dart` 条件导出 stub/io，
   全仓只有 `app_tray_io.dart` import `tray_manager` / `nativeapi`，
   由 `test/architecture/tray_import_test.dart` 扫描强制。
7. **托盘对象生命周期**：nativeapi 的 `TrayIcon` / `Menu` / `MenuItem` /
   `Image` 都挂 finalizer，对象被 GC 会释放原生句柄（图标/菜单无声消失）：
   创建过的一切由 `AppTray` 静态字段持有到 `dispose()`。
8. **Linux 必须显式设置菜单触发方式**：`setContextMenuTrigger(rightClicked)`。
   nativeapi 默认 `none`，此时 SNI 的菜单路径是 `/NO_DBUSMENU`，面板根本不
   显示菜单（不是「点不出来」而是没有任何菜单）。
9. **设置项**：「关闭时最小化到托盘」（默认**开**），设备本地键
   （`TraySettings`，不登记设置注册表），入口在 设置 › 通用 › 桌面；
   Linux 额外显示提示（GNOME 需 AppIndicator 扩展 / 无宿主时关闭即退出）。
10. **宿主探测与降级**：`AppTray.detectHost()`（结果缓存）——Windows 恒 true；
    Linux 用一次性 `dbus-send` 查询 `org.kde.StatusNotifierWatcher` /
    `com.canonical.StatusNotifierWatcher` 是否有持有者（不引入 D-Bus 客户端
    依赖），查询不确定（无工具 / 无 session bus）时按「有宿主」处理以保持
    设置原意，只有明确无持有者才判定无宿主。无宿主时关闭策略退回直接退出。
    D-Bus 不可用 / 无面板 / 图标资源缺失时 `AppTray.init` 静默降级（日志 +
    无托盘继续运行），不阻塞启动、不影响其余功能。

## 后果

- 桌面端关闭键语义变化：默认隐藏到托盘（播放不中断），用户在设置里可切回
  「关闭即退出」；**无托盘宿主时自动退回「关闭即退出」**（不会把窗口藏成
  没有找回入口的状态）；托盘「退出」与更新安装仍然真的退出进程；
- 托盘图标始终存在（播放控制、唤起窗口、退出都有入口）；
- Linux 上「看不到图标」是环境问题（无 StatusNotifier 宿主：GNOME 需扩展，
  KDE 等自带）：设置页有提示，图标不显示时关闭行为自动退回「直接退出」，
  其余功能不受影响；
- `flutter test`（Linux VM）里 `AppTray.isSupported` 为 true 属预期：单测只
  读静态属性 / 构造 stub 类型，不触原生调用；集成测试显式调用 init/dispose
  做冒烟（Xvfb 无面板环境下走降级分支也不得崩）；
- 构建机新增依赖：Linux 需要 GTK3 / X11 / Xi 开发文件
  （CI 的 integration / release Linux job 已补 `libx11-dev libxi-dev`）；
- 新增图标资产 `assets/icons/tray_icon.png`（由
  `assets/icons/molia_icon_full_bleed.svg` 经 rsvg-convert 生成 64×64，
  品牌瓦片形式，亮/暗面板都可辨识）。

## 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：全绿（含 `test/services/tray_settings_test.dart`、
  `test/architecture/tray_import_test.dart`、设置页桌面开关用例）；
- `tool/agent/test.sh linux`：集成用例全绿，含
  「桌面托盘：创建 / 更新 / 销毁冒烟」与窗口 hide → show 可见性往返
  （Xvfb 无面板环境不得崩）；
- `flutter build linux --release`：nativeapi build hook 在 Linux 上编译通过；
- `flutter build web --release`：stub 路径通过（无 `dart:io` / FFI 泄漏）；
- 运行时证据（真实应用 + `tool/agent/app.sh run -d linux`）：
  `molia.app_tray: 托盘已创建`；本机无 StatusNotifierWatcher 时
  `molia.app_tray: 未检测到托盘宿主…关闭到托盘将退回直接退出`（nativeapi 同时
  输出 `SNI: no StatusNotifierWatcher found`，与探测结论一致）；启动无异常，
  热重载正常。

## 未验证

- **本机（WSL2）看不到托盘图标**：session D-Bus 上没有 StatusNotifierWatcher，
  只能验证「原生链路可调用 + 无宿主时静默降级 + 关闭策略退回直接退出」；
  图标观感、菜单交互需在 KDE / GNOME（+AppIndicator 扩展）或 Windows 真机复核；
- **Windows**：本机只有 Linux（与 ADR-0004 相同的未验证项）——左键唤起、
  右键菜单、任务栏隐藏行为均未实机确认；
- 托盘菜单在 GNOME AppIndicator 扩展下的渲染细节（禁用项、分隔线）未实机确认。
