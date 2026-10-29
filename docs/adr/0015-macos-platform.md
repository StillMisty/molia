# ADR-0015：macOS 桌面目标（原生标题栏 + 菜单栏托盘）与 iOS 18 基线

- 状态：已采纳
- 日期：2026-10-25
- 相关：`macos/`、`lib/services/window/**`、`lib/app/bootstrap/desktop_stack.dart`、
  `lib/playback/desktop_audio_init_io.dart`、`docs/media_kit_native_libs.md`、
  `.github/workflows/release.yml`、`ios/Podfile`、`ios/Runner.xcodeproj/project.pbxproj`

## 背景

仓库此前只有 Android / iOS / Linux / Windows 四个构建目标。代码里大量平台判断
（`isDesktopPlatform`、`window_manager` / `tray_manager` / `system_hotkeys` /
`flutter_media_session` / 另存为 / 更新安装器）早就把 macOS 算进桌面面，但
`WindowChrome` / `AppTray` / `SingleInstance` 仍是显式 stub（`docs/pitfalls.md` #41），
`macos/` 目录从未生成，发布流水线也没有 macOS 产物。

同时 iOS 最低版本停在 15.0（Flutter 3.47 模板默认值）。项目处于内部快速迭代，
15.0 只会留下额外的兼容面积（后台音频、睡眠定时原生通道、通知 / 权限分支都要
照顾更老的系统行为），并没有真实用户收益。

## 决策

1. **新增 `macos/` 目标（macOS 12+，Swift Package Manager）**，结构取 Flutter 3.47 官方模板
   （`packages/flutter_tools/templates/app/macos.tmpl`），只改品牌 / 标识 / entitlements：
   - `PRODUCT_NAME = Molia`、`PRODUCT_BUNDLE_IDENTIFIER = top.stillmisty.molia`；
   - AppIcon 由 Android 全彩源图生成（824 / 1024 内容网格）；
   - `Info.plist` 补 ATS（部分音源是 http 直链）、局域网用途说明、音乐分类；
   - Debug / Release entitlements 都开 `network.client`、`network.server`、
     `files.downloads.read-write`、`files.user-selected.read-write`。
2. **窗口用 macOS 原生标题栏**（红绿灯 + 系统标题），不做 Linux / Windows 那套自画
   三键。`window_manager` 在 macOS 只承担「关闭拦截 → 隐藏到托盘 / 退出」
   「几何 / 最大化记忆」「显示 / 聚焦 / 设置窗口标题」；窗口本身随 NIB 显示
   （隐藏窗口会停帧，不能在启动期先藏后显）。`WindowChrome` 新增
   `usesCustomTitleBar`（仅 Linux / Windows），`WindowControls` 按它挂载。
3. **托盘照常启用**：`AppTray.isSupported` 加 macOS，`detectHost()` 对 macOS 恒为真；
   菜单栏图标改用单色模板图（`adaptive_icon_monochrome.png` + `isIconTemplate`，
   18pt），右键菜单与 Linux / Windows 共用同一套 `TrayMenuLabels` 与动作。
4. **单实例与 Dock 恢复**：macOS 有窗口能力后一并启用 `SingleInstance`（锁文件 +
   loopback）；macOS 的进程存活探测走 `kill(pid, 0)`（`__error` 取 errno）。
   Dock 图标点击由 `AppDelegate.applicationShouldHandleReopen` 经窗口通道发
   `reopen` 回 Dart → `WindowChrome.show()`；不能只让 AppKit 显示窗口——托盘休眠
   期间界面是占位树，原生直接显示会是空窗。
5. **播放走 just_audio 原生 AVPlayer，不引 media_kit**：`just_audio` 的 darwin
   实现声明 macOS，`UriAudioSource` 通过 `AVURLAssetHTTPHeaderFieldsKey` 透传请求头
   （B 站直链的 Referer / UA 仍有效，见「Playback stream headers」不变量）。
   `desktop_audio_init_io` 只在 Windows / Linux 初始化 media_kit，因此不新增
   `media_kit_libs_macos_audio`，`docs/media_kit_native_libs.md` 的「按平台拆分」
   结论不变（macOS 仍是纯死重量）。曲末判定也不走 media_kit 的位置兜底。
6. **系统能力复用现有实现**：系统媒体会话走 `flutter_media_session` 的 macOS
   实现（与 iOS / Windows 同一后端），全局热键走 `system_hotkeys` 的
   `RegisterEventHotKey`，中文字体解析已有 macOS 分支。
7. **发布产物 = ad-hoc 签名、未公证的 zip**：`release.yml` 增加 macOS job，
   `flutter build macos --release` 后用 `ditto` 打包 `Molia.app` 为
   `molia-<version>-macos-<arch>-unsigned.zip`；文件名带 `unsigned`，按现有
   `gen_update_manifest.py` 规则**不进 `latest.json`**。应用内更新在 macOS 返回
   `InstallOutcome.unsupported`，设置页显示「从发布页手动下载」说明（新增
   `updateMacosHint`）。
8. **iOS 最低版本 15.0 → 18.0**：`ios/Podfile` 的 `platform :ios` 与 Runner 三份
   build configuration 的 `IPHONEOS_DEPLOYMENT_TARGET` 同步提升；README /
   架构文档里的 iOS 15+ 表述一起改。

## 取舍

- **不做自画标题栏**：macOS 用户预期红绿灯在左上、窗口菜单在系统层；自画三键
  （Windows 右侧布局）会违背平台习惯。代价是顶栏与原生标题栏上下并存，视觉上
  多一条系统栏。
- **不做应用内更新 / 公证**：没有 Apple Developer ID，自动替换 `.app` 还会与
  Gatekeeper、签名校验冲突；与 iOS 同一取舍（手动下载）。
- **不做 security-scoped bookmark**：自定义保存目录只在当次进程内有效，重启后
  可能失去授权（默认 `~/Downloads/Molia` 不受影响），见 pitfalls #89。
- **Cmd+Q 不走 `quitApp`**：macOS 的「退出」菜单直接 `terminate:`，不经
  `WindowChrome` 的关闭策略；播放会话只在动作（播放 / 暂停 / seek / 切歌 /
  曲末等）时提交，不做退出前强制提交与音频收尾（与 iOS 被系统杀掉同口径：
  最多丢最后一个动作之后的进度）。托盘菜单 / 关窗退出仍走完整 `quitApp`。
- **不做 macOS 桌面歌词**：仍等 Flutter 官方多窗口 API（同 `docs/lyrics_display.md`）。
- **局域网自动发现受 Apple multicast entitlement 限制**：与 iOS 同一约束
  （见 `docs/architecture.md` §同步），未申请时降级为手动填对端地址 / 扫码；
  macOS 15+ 首次访问局域网会弹系统授权（Info.plist 已加
  `NSLocalNetworkUsageDescription`）。
- **系统壁纸取色**：macOS 暂无稳定读取入口，回退系统强调色 / 封面取色（与现有
  其它平台回退同一路径）。
- **不做 Intel / Universal 双架构矩阵**：CI 的 `macos-latest` 产出什么架构就发
  什么架构（文件名带 `arm64` / `x64`）。

## 影响

- 新增 `macos/`（Runner / Podfile / entitlements / 图标 / 模板工程）与 ADR 本文；
- `WindowChrome` / `AppTray` / `SingleInstance` / `process_liveness` /
  `AppMemoryManager` 的 macOS 分支；`ShellChrome` 用 `usesCustomTitleBar` 判定
  窗口三键；`main.dart` 在 macOS 也预读窗口几何；
- `update_settings_page.dart` 的 macOS 分支与 `updateMacosHint`（zh / en）；
- `.metadata` 登记 macos 平台；`README.md` / `docs/dev_environment.md` /
  `docs/architecture.md` / `docs/pitfalls.md` / `docs/media_kit_native_libs.md` /
  `.agents/skills/molia-release/` 同步平台清单；
- 发布流水线新增 macOS job，`publish` 依赖它；`latest.json` 行为不变。

## 修订

- 2026-10-26：移除 `macos/Podfile`，改用 Swift Package Manager。首次发布 macOS job 时
  `pod install` 生成零依赖 Pods，`Check Pods Manifest.lock` 反而报
  「sandbox is not in sync」直接失败；macOS 插件（含 `quickjs_engine`、
  `window_manager` 等）都已提供 `Package.swift`，Flutter 也提示「All plugins found
  for macos are Swift Packages」，因此不再保留 CocoaPods 集成。
