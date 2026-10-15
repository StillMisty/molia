# ADR-0004：桌面窗口 chrome（隐藏标题栏 + 顶栏拖动区 + 三按钮）

- 状态：已采纳
- 日期：2026-10-13
- 相关：`lib/services/window/window_chrome.dart`、`lib/services/window/window_chrome_io.dart`、
  `lib/services/window/window_chrome_stub.dart`、`lib/app/app_shell.dart`、`lib/main.dart`、
  `integration_test/lx_engine_integration_test.dart`、`docs/pitfalls.md` #30

## 背景

Linux/Windows 桌面端此前保留系统标题栏：窗口最小化/最大化/关闭只能点系统按钮，
而应用自己又有一条顶栏（`app_shell.dart` 的 AppBar），两条栏视觉上重复占高、
风格也不统一（系统标题栏不吃应用主题）。移动端/Web 没有原生标题栏，
不需要任何处理。

## 决策

1. **选 `window_manager ^0.5.2`**。证据：pub 160/160 分、GitHub 849★、
   调研时 2 天内仍有推送；本机硬验证：Flutter 3.47.x 下可编译可运行，
   默认（Wayland）与 `GDK_BACKEND=x11` 两条路径下 `getTitleBarHeight() == 0`。
2. **排除项**：
   - `nativeapi_flutter`：WIP，Linux 拖动未实现；
   - `window_manager 0.6.0`：只有 git 渠道，未发布到 pub；
   - `bitsdojo_window`：约 34 个月停更；
   - `titlebar_buttons`：约 56 个月停更；
   - Flutter 官方 windowing API：实验性、只在 main 渠道、官方注明不得用于生产。
3. **范围**：隐藏标题栏 + 顶栏拖动区（含双击最大化 / 还原）+ 三个窗口按钮
   （最小化 / 最大化-还原 / 关闭，关闭键 hover/按下走危险色）。
   不做设置开关（默认即最终形态）、不做 macOS（保留原生标题栏）、
   移动端与 Web 行为零变化（按钮整组不构建、拖动区/双击区纯透传）。
   （2026-10-15 修订：关闭键行为见 ADR-0009「桌面托盘」——默认改为隐藏到
   托盘，并由设备本地设置控制；chrome 本身规格不变。）
4. **架构：UI 不得 import `window_manager`**。该包的 Dart 代码 import `dart:io`，
   被 UI 直接引用会让 `flutter build web` 直接失败；统一经
   `lib/services/window/` 条件导出（stub/io，与 `system_fonts_service.dart` 同一模式），
   全仓库只有 `window_chrome_io.dart` 一处 import 该包。
5. **实现要点**：
   - `main()` 在 `WidgetsFlutterBinding.ensureInitialized()` 之后、`runApp` 之前
     `await WindowChrome.ensureInitialized()`（Web/移动端是空操作）：
     `windowManager.ensureInitialized()` → `waitUntilReadyToShow(
     WindowOptions(titleBarStyle: TitleBarStyle.hidden), show + focus)`，
     首帧渲染时标题栏已是隐藏态，不会闪一下系统标题栏；
   - 最大化状态由 `WindowListener`（maximize / unmaximize / restore）写入
     `ValueListenable<bool> maximized`，顶栏用它切换「最大化 ⇄ 还原」图标；
     `restore`（从最小化恢复）重新查询原生状态——最大化的窗口最小化后再恢复
     仍是最大化，直接置 false 会让图标错成「还原」；
   - `WindowDragArea` 是 UI 唯一可用的拖动入口（stub 直接返回 child），
     语义同 window_manager 的 `DragToMoveArea`：pan 起始交给原生
     `startDragging()`；
   - **双击最大化 / 还原**（`WindowDoubleTapMaximize`，包住顶栏标题区）：
     不用 `GestureDetector(onDoubleTap)`——双击识别器会把同一区域的单击
     延迟到双击判定结束（实测子按钮 onTap 也延迟约 300ms）；改用被动
     `Listener` 自己数点击（不参与手势竞技场）：300ms 内两次「原地抬起」
     （位移 ≤12dp）触发 `toggleMaximize`，单击 / 拖动 / 按钮点击时序不变；
     只包标题/封面区，按钮区不参与（双击按钮不改变窗口状态）；
   - **关闭键危险色**：hover / 按下时底色 `errorContainer`、字形
     `onErrorContainer`（`M3EIconButtonDecoration.overlayColor` 覆盖中性的
     state layer；字形色由外层 `MouseRegion` 给出——decoration 的
     `foregroundColor` 不带 hover 状态）。其余按钮保持中性；
   - **窗口三键规格**：M3E `sm` 档（24 图标 / 40 视觉格 / 48 触控目标），
     与应用图标按钮同规格；字形用 `Icons.remove_rounded`（居中横线）而不是
     `Icons.minimize_rounded`（Material 的下沉横线，笔画中心低 6/24），
     最大化字形 20 档 ≈13dp 与关闭的 12dp 对齐；与应用操作之间以短竖线
     （`M3EDivider`）分界；
   - 顶栏总高度不变：AppBar 外层包 `PreferredSize`，高度取
     `AppBar.preferredHeightFor(context, appBar.preferredSize)`
     （当前 = 56 工具栏 + 10 波浪进度），与 Scaffold 原本的算法一致。

## 后果

- Linux/Windows：系统标题栏消失，顶栏右侧多出三个窗口按钮（最小化 /
  最大化-还原 / 关闭，tooltip 走 l10n），顶栏空白处可拖动窗口；
- 其余平台：`WindowChrome.isSupported` 为 false，按钮不构建、拖动区透传，
  布局与改动前逐像素一致；
- `flutter test` 跑在 Linux VM 上：`isSupported` 为 true 属预期（顶栏会构建出
  三个按钮，但按钮自身不发起插件调用）；除 `ensureInitialized()`（仅 `main()`
  与集成测试调用）外，任何构建期/测试期路径都不调用插件 API，
  不会撞 `MissingPluginException`；
- 隐藏标题栏后窗口拖动/双击最大化/边缘缩放全由原生窗口管理器负责，
  属人工手感项（见下）。

## 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：全绿；
- `tool/agent/test.sh linux`：集成用例全绿，含常驻断言
  「隐藏标题栏后系统标题栏高度为 0」（`WindowChrome.isSupported` 守卫，
  Android 上直接通过）；
- `flutter build web --release`：通过（stub 路径，UI 无 `dart:io` 泄漏）；
- 运行时证据：Linux 真实应用 `getTitleBarHeight() == 0`。

## 未验证

- **Windows**：本机只有 Linux，未实机验证（代码路径与 Linux 共用同一
  Dart 实现，但 Windows 的原生插件行为、按钮观感未确认）；
- **人工手感项**：拖动跟手程度、边缘缩放、隐藏标题栏后的窗口阴影/圆角、
  最小化/关闭的动画（双击最大化已实现，见上）。
- **X11 路径**：`GDK_BACKEND=x11` 下在本机（WSLg 的 X11 显示）跑端到端集成测试
  不稳定——播放用例在 libmpv 起播后卡死、后续用例 `did not complete`；
  已用基线（`main`，无 window_manager）复现同一现象，与本次改动无关。
  该路径下 `getTitleBarHeight() == 0` 的结论来自调研阶段的独立验证，未在本次
  提交的自动化里覆盖；X11 用户的实际表现需在真机确认。
