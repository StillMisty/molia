# 已知坑（改代码前务必阅读）

本清单收录本仓库实际踩过、且只读代码不易发现的坑。

> **编号被源码注释直接引用**（如 `ic_notification.xml` / `molia_mark.dart` 中的「见已知坑 18/19」），
> 请勿重排；新增条目追加在末尾。

1. **JS 运行时（QuickJS）原生库必须在 Linux bundle 里**（flutter_js 时代的历史坑，已解决）：
   flutter_js 的上游 Linux CMake 把 bundled libraries 变量命名为
   `flutter_qjs_bundled_libraries`（Flutter 只识别 `flutter_js_bundled_libraries`），
   QuickJS 桥接库不会被打进 bundle，曾需仓库在 `linux/CMakeLists.txt` 显式补装。
   可迁移经验：再遇「上游 CMake 不打包 .so」，先核对其变量名是否为
   `flutter_<包名>_bundled_libraries`。
   现用 quickjs_engine：包内 CMake 会把 `libquickjs_c_bridge_plugin.so` 正确打进 bundle，
   但它 0.1.6 的 Linux 插件头（`linux/include/quickjs_engine/quickjs_engine_plugin.h`）
   漏了 Flutter 官方模板里的 `#ifdef FLUTTER_PLUGIN_IMPL` 导出宏块，
   `FLUTTER_PLUGIN_EXPORT` 未定义 → Linux 直接编译失败（上游 CI 无 Linux 任务，故未暴露）。
   `linux/CMakeLists.txt` 末端按官方模板补了同一个宏、只作用于该插件目标；上游修好后删掉。
2. **引擎不启用内置 fetch**：脚本的网络请求必须统一走 `lx.request` 桥接（安全边界，见 #8）。
   quickjs_engine 的 `getJavascriptRuntime()` 其 `xhr` 默认 true、会装 fetch/XHR，
   所以本引擎不调它，直接建 `QuickJsRuntime2`——`console` / `setTimeout` / `sendMessage`
   由 `JavascriptRuntime.init()` 装好，够用。不要改回 `getJavascriptRuntime()`，
   也不要在 isolate 里再开一条绕过桥接的网络通道。
3. **`material_color_utilities` 被 Flutter SDK 固定为 0.13.0**，不要升级为 0.13.1（版本求解会失败）。
4. **`encrypt` 已移除**：pointycastle 4.x 与其冲突；AES/RSA 统一走 `lx_native_utils.dart`。
5. **maven.google.com 在部分网络不可达**：`android/app/build.gradle` 仓库显式使用
   `https://dl.google.com/dl/android/maven2`，不要改回 `maven.google.com`。
6. **share_plus 13**：使用 `SharePlus.instance.share(ShareParams(files: ..., text: ...))`，
   `Share.shareXFiles` 已不存在。
7. **Web 不支持音源**：`kIsWeb` 时 `SourceManager` 不激活引擎；不要移除条件导入
   （`lx_engine.dart` / `desktop_audio_init.dart` 的 stub 分支）。数据库无需处理：
   `drift_flutter` 自身按平台条件导出，Web 运行时不初始化数据库即可。
8. **音源脚本是不可信代码**：不要在引擎里暴露文件系统/平台通道；网络只走 `lx.request` 桥。
   `currentScriptInfo` 必须原样透传（部分脚本有防篡改校验，校验失败会死循环）。
9. **ELECTRON 脚本兼容性**：脚本可能使用 `atob/btoa/TextEncoder/setTimeout/window/navigator`
   等 shim；扩展能力请加在 `lx_prelude.js` 而不是假设宿主提供。
10. **插件 JVM target 校验**：部分插件的 Java target(11) 与 Kotlin target(1.8) 不一致，
    AGP 9 默认按错误处理；已在 `android/gradle.properties` 设置
    `kotlin.jvm.target.validation.mode=warning`，不要删除。
11. **集成测试挂起保护（仅桌面）**：桌面端 media_kit（libmpv）的原生事件循环会阻止测试进程
    退出；`integration_test/lx_engine_integration_test.dart` 的 `tearDownAll` 有 2s 上报窗口后
    `exit(0)` 的看门狗（只在 Linux/Windows 注册），不要删除、也不要推广到 Android——Android
    走官方 teardown（stopApp/uninstall）能干净退出，注册看门狗反而会抢在卸载/回收之前退出进程。
    Android 若遇跑完不退出，是上游 adb teardown 无超时（flutter/flutter#187785 / #187984，
    3.47.6 已修 DDS 路径），先看 `tool/agent/test.sh` 的日志尾部再判断。
    另：Linux 集成测试默认套 `xvfb-run`（脚本无条件处理，WSLg 下也不会弹窗），否则无显示环境
    会报「Error waiting for a debug connection」；要肉眼观察用 `test.sh linux --window`。
12. **不内置字体资产**：界面与海报统一使用设备字体，用户可在设置中切换「应用字体」
    （枚举实现见 `lib/services/system_fonts_service*.dart`：Android 解析系统
    `fonts.xml`、iOS 走 `UIFont.familyNames` 通道、Linux 调 `fc-list`、Windows
    扫系统/用户字体目录 + 注册表后解析字体 `name` 表取家族名——注册表值名带样式
    后缀（`Arial Bold`），不能直接当家族名），海报页可
    独立覆盖（`PosterFontStore`）。不要再向 `pubspec.yaml` 的 `fonts:` 或
    `assets/fonts/` 添加字体，保持包体精简。
13. **发布体积**：新增资产前先评估体积；不要内置 CJK 字体（系统字体 + 用户安装）。
    Android 启动图标自 2026-10 起为手绘矢量（`drawable/ic_launcher_foreground.xml`，
    维护方式见 `icons_launcher.yaml` 头注释），该工具现在只生成 iOS 图标；
    `minSdk=37` 下传统 mipmap 密度图无意义，已全部移除，不要用工具再生成。
14. **省流模式的网络检测**：Android 8+ 后台不广播网络变化，`_MyThemedAppState` 在
    `resumed` 时调 `DataSaverService.refreshConnectivity()`，不要删除；Web 的
    connectivity_plus 拿不到「蜂窝」类型（只会返回 wifi/none），省流在 Web 不会自动生效；
    检测失败时保守按「未生效」处理（`detectionAvailable=false`）。
15. **`--no-pub` 会跳过插件注册文件再生成**：`flutter build ... --no-pub` 不重写
    `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`。
    若该文件缺失，构建**不会报错**但产物没有插件注册（R8 会把插件类全部裁掉，
    表现为通知/播放等原生插件全失效；若文件来自 debug/集成测试还会残留
    `integration_test` 引用，导致 release 编译失败。发布构建不要加 `--no-pub`，
    它只适合本地快速迭代。
16. **桌面歌词悬浮窗**：`SYSTEM_ALERT_WINDOW` 是特殊权限（需用户去系统设置授权），
    窗口类型 `TYPE_APPLICATION_OVERLAY`；`MainActivity.onResume` 复查并收窗的逻辑
    不要删除。`LyricsChannel` 同名通道只能有一个方法调用处理器（原生事件单点分发），
    新增原生事件必须走 `LyricsChannel.events`，不要再次 `setMethodCallHandler`。
17. **歌词展示策略全在 Dart**：行定位 / 偏移 / 翻译拼装 / 暂停与无歌词回退 / 元数据
    格式 / 蓝牙门控都在 `LyricsDisplayProvider` 与输出映射层完成，原生只渲染与上报
    交互；新增输出实现 `LyricsOutput` 接口即可（桌面平台输出等 Flutter windowing
    进入 stable 后再接，见 `docs/lyrics_display.md` §11）。
18. **audio_service 通知小图标必须指向真实存在的 drawable**：媒体通知 small icon 在
    `local_audio_handler.dart` 显式指定 `drawable/ic_notification`（品牌矢量 + 16% inset）。
    audio_service 默认值是 `mipmap/ic_launcher`，本项目已随传统密度图一起移除；通知
    不支持自适应图标（`mipmap/launcher_icon`），资源 ID=0 时 `NotificationManager`
    抛「Invalid notification (no valid small icon)」**直接崩溃进程**（首次播放即崩）。
    换启动图标时同步维护该 drawable。
19. **Impeller 下不要用 `Image.color` 着色**：GLES 后端（模拟器/部分真机）会给图片
    绘制矩形的四条边加 1px 半透明色线（Skia 无此问题，属引擎边缘采样伪影）。
    品牌图标统一走 `ColorFiltered` + `BlendMode.srcIn` 着色（见 `molia_mark.dart` /
    `app_shell.dart` 顶栏标志），新增图标位照此实现。
20. **`M3EListRowSurface` 的圆角无视传入值**：`M3EListItemTheme.radiusFor` 在 hover/press/
    focus/选中时一律返回 `BorderRadius.circular(selectedRadius)`（16dp）、忽略调用方传入的
    静止圆角，且以 `animationDuration: Duration.zero` 瞬间切换——方角行一 hover 就突兀地
    跳成圆角卡片（规范值是 hover 12dp，且应有 shape morph）。`TrackRow` 因此改用底层
    `M3ECard` 自绘表面（静止内 4dp/首末外侧 16dp、hover 12dp、press/选中 16dp，弹簧 morph），
    不要改回 `M3EListItem` / `M3EListRowSurface`。
21. **motor 弹簧的 `isAnimating` 有容差拖尾**：`SingleMotionController` 在视觉落定后
    仍会 `isAnimating == true` 约 0.3-0.4s（距离/速度双容差），直接拿它当「过渡进行中」
    会踩两类坑：新切歌动画被「续走」分支饿死（进度≈1 时 animateTo(1) 一步到位）、
    新手势/新动画被挡在门外。要按**进度阈值**判定（如 `isAnimating && value < 0.99`，
    见 `player_cover_deck.dart::_coverSwapMidFlight`）；落定状态（completed/dismissed）
    永远取决于**目标值 vs `initialValue`**，需要用状态回调时要显式传 `initialValue`
    （如迷你⇄完整展开传 0 再 `value = 1`）。另外 `animateTo` 的 `withVelocity` 单位是
    **值域/秒**，手势速度要按进度换算（如 `-pxVelocity / range`）。
22. **弹层内容里再套 `Navigator` 会遮蔽 M3E 的滚动联动**：M3E 底部弹层把
    `M3EBottomSheetScrollController` 经 `PrimaryScrollController` 下发给内容，靠它实现
    「列表滑到顶再下滑 = 收缩/关闭」。而 Flutter 的 `ModalRoute` 会给每条路由装一个
    自己的 `PrimaryScrollController`（`widgets/routes.dart`），路由内的滚动视图因此
    挂到路由控制器上——弹层再也收不到拖拽（只有 48dp 拖拽把手能动）。
    设置弹层（首屏套了一层内部 `Navigator`）踩的正是这个坑：显式把
    `M3EBottomSheet.scrollControllerOf(context)`（在内部 Navigator 之上取）传给首屏
    滚动视图即可；子页保持自管控制器（与「子页打开时 guard 挡下关闭」语义一致）。
23. **M3E carousel 的文字必须走原生槽位**：`M3ECarouselItem.image` 的内容按「最大槽位
    尺寸布局 + 按当前槽位裁剪」，把封面 + 歌名/歌手/理由整块塞进 `image` 时，非首卡会
    把底部文字裁掉（首卡正常、其余卡只剩半张封面）。文字一律用 `title` / `subtitle`
    （`applyDynamicTextContentTransform: false` 常显），需要压暗用
    `M3ECarouselScrim.gradient()`。
24. **Android 集成测试里 `tester.drag` 不产生滚动**：live binding 下（模拟器/真机）
    `drag` 的位移不进 `ScrollPosition`（实测 `pixels` 恒为 0），而 `fling` 正常。因此
    `tester.scrollUntilVisible`（内部逐次 drag，50 次后抛 `Bad state: No element`）在
    Android 上必挂；桌面因窗口宽、卡片不换行、目标常在已构建范围内而不暴露。
    集成测试滚动一律走 `integration_test/lx_engine_integration_test.dart` 的 `scrollTo`
    助手（fling 版）或 `ensureVisible`，不要用 `scrollUntilVisible`。
25. **M3E 分段按钮与下拉菜单的两个暗坑**（设置页行组件已收口）：
    `M3ESegmentedButton` 内部是 `Stack + Positioned.fill + Row(mainAxisSize.min)`，
    放松约束的父级（`Align` / `Row` 尾位）会塌成零宽并溢出，必须给显式/紧约束宽度
    （用 `SettingsChoiceRow`；回归见 `test/widgets/settings_choice_row_test.dart`）。
    `M3EDropdownMenu` 单选必须设 `fieldStyle.hintText`，否则未选中时显示包内英文兜底
    `Select`（用 `SettingsDropdownRow`，它统一填标题提示）。
26. **新 worktree 的 Android 构建先对齐 Gradle wrapper**：`/android/gradle/` 被
    .gitignore 排除，新 worktree 里 Flutter 会按 SDK 模板生成 Gradle 9.3.1，而本项目
    AGP 要求 ≥ 9.6（工具链表为 9.8.1）。构建前把
    `android/gradle/wrapper/gradle-wrapper.properties` 的 distributionUrl 改为
    `gradle-9.8.1-bin.zip`；另注意 JDK 27 + Gradle 9.3.1 会因 class file 71 直接
    失败（Gradle 9.8.1 + JDK 27 已验证可用）。
27. **16 KB 页对齐是发布硬条件，而且属于「依赖带进来的属性」**：Android 15+ 的 16 KB
    内核设备要求 64 位 .so 的 ELF 段按 16 KB 对齐（Google Play 自 2027-02 起强制）。
    构建侧已满足（AGP ≥ 8.5.1 管 zip 页对齐、NDK r28+ 默认 16 KB 段对齐），但本项目没有
    自己的 native 代码，对齐完全由依赖决定（quickjs_engine 的 QuickJS-NG 由本仓库 NDK
    从源码编译、shared_preferences 带的 androidx.datastore、sqlite3 经 Dart hooks
    打的 libsqlite3 等；`libquickjs_c_bridge_plugin.so` 与 libsqlite3 均已实测 LOAD 段
    Align=0x4000），升级后可能被换回 4 KB 库。
    本地默认模拟器就是 16 KB 页，集成测试（`tool/agent/test.sh android`）会当场暴露
    加载失败；必要时用官方 `check_elf_alignment.sh` 或 `zipalign -c -P 16 <apk>` 复查。
28. **Android 打包不要剔除本地库的 `libsqlite3.so`**：drift 在所有平台都使用
    `sqlite3` 经 Dart hooks 打进 APK 的 `libsqlite3.so`；`android/app/build.gradle`
    的 `packaging.jniLibs.excludes` 曾按 sqflite 时代的口径（Android 走系统 SQLite）
    剔除它，后果是运行期 `dlopen("libsqlite3.so")` 失败、开库直接抛错
    （`Invalid argument(s): Couldn't resolve native function ...`）。新增 native asset
    的剔除规则前先确认运行期确实不需要它。
29. **`flutter test` 里实例化 quickjs_engine 需要可加载的原生库**：单测运行在 Dart VM，
    没有打包好的插件库；`FLUTTER_TEST=true` 时包先读环境变量 `LIBQUICKJSC_TEST_PATH`，
    再找 `packages/quickjs_engine/native/build/` 等候选路径，全部失败则退回系统库名
    `libquickjs_c_bridge_plugin.so`（Linux 应用模式另读 `LIBQUICKJSC_PATH`）。
    本仓库单测只 import 引擎抽象类型、不实例化（用例用 `_FakeLxEngine`），不受影响；
    集成测试先构建应用，bundle 内原生库自然可用。若未来单测要真跑引擎，先构建一次
    （如 `flutter build linux --debug`）再以
    `LIBQUICKJSC_TEST_PATH=<abs>/libquickjs_c_bridge_plugin.so flutter test ...` 运行。
30. **桌面窗口 chrome 只在 `lib/services/window/` 里碰 window_manager**：
    `window_manager` 的 Dart 代码 import `dart:io`，任何会参与 Web 编译的代码
    直接 import 它都会让 `flutter build web` 失败；统一经
    `window_chrome.dart` 的条件导出（stub/io，同 `system_fonts_service.dart` 模式），
    全仓库只有 `window_chrome_io.dart` 一处 import 该包。
    `TitleBarStyle.hidden` 之后系统标题栏与系统按钮都不复存在，窗口拖动只能靠
     UI 侧的 `WindowDragArea`（已包在壳层顶栏外层）——不要在别处再隐藏标题栏，
     也不要把顶栏的拖动区摘掉，否则窗口再也拖不动。
    另：`flutter test` 跑在 Linux VM，`WindowChrome.isSupported` 为 true 属预期
    （单测里顶栏会构建出三个窗口按钮，但按钮本身不发起插件调用）；除
    `ensureInitialized()`（仅 `main()` 与集成测试调用）外，任何构建期/测试期路径
    都不得调用插件 API，否则撞 `MissingPluginException`。
31. **Linux 无系统钥匙串时 `flutter_secure_storage` 会抛异常，读取必须容错**：
    WSLg / 容器 / 无 keyring 的最小桌面没有 `org.freedesktop.secrets`，
    libsecret 抛 `PlatformException(Libsecret error, ... is not activatable)`。
    `SyncProvider.init()`（`runApp` 之前）读同步口令时会直接撞上：
    未捕获 → `main()` 在 `runApp` 前终止 → **窗口已由 window_manager 显示、
    但没有首帧，表现为永久黑窗（进程还活着）**。现在的契约：
    `SecureSettingsSecretStore.read` 把读取失败降级为「未设置」（返回 null +
    只记一次日志），`main.dart` 再兜一层包住 `syncProvider.init()`。
    新增任何「读安全存储」的路径都要遵守这条：可选子系统的故障不能阻断启动；
    写入/删除仍保持抛出（用户主动操作要知道失败）。
32. **`build/linux/x64/debug/bundle` 可能是 `flutter test` 的产物，不是应用**：
    跑过 `flutter test integration_test/... -d linux` 之后，该目录里的可执行文件
    入口是测试 listener（VM Service `rootLib` 是 `flutter_test_listener.dart`），
    单独运行它不执行应用 `main()`——不渲染、窗口不出现，容易误判成「桌面端坏了」。
    手工验证桌面端用 `flutter run -d linux` 或先 `flutter build linux --debug`
    再跑 bundle（`tool/agent/test.sh linux` 会自行重建，不影响它）。

33. **无头 CI 跑桌面集成测试要给 libmpv 一个「按实时速率消费」的虚拟音频输出**：
    runner 无声卡时 libmpv 有两种失败形态，症状都不是「没声音」而是**播放瞬间结束**——
    (a) 打不开音频输出（`Could not open/initialize audio device`）；
    (b) 输出能打开但不节流（如 ALSA 的 `type null` PCM）。
    两者都会让媒体流立即进入 `ProcessingState.completed`，`LocalPlaybackService`
    随即自动切歌：表现为断言拿到下一首（`Hello LX` vs `Second Song`）或
    「等待超时: 播放未开始」（`isPlaying` 从未为 true）。
    正确做法是 PulseAudio + null sink（按实时速率消费数据），见
    `.github/workflows/integration.yml` 的「集成测试」步骤：
    `pulseaudio -D --exit-idle-time=-1 --disable-shm` →
    `pactl load-module module-null-sink` → `pactl set-default-sink`，
    并在同一步 export `XDG_RUNTIME_DIR`（daemon 与客户端的 socket 都靠它）。
    另：mock 音频时长要留足（现为 30s），别用 3s——慢 runner 上起播本身就要几秒。
34. **release 的 `shrinkResources` 会删掉「字符串引用」的资源，媒体通知直接不出现**：
    release 开了 `minifyEnabled + shrinkResources`，AAPT 只按静态引用判定资源存活；
    `ic_notification`（Dart 侧 `androidNotificationIcon` 按字符串引用）与
    `audio_service_*` 七个动作图标（audio_service 运行时 `getIdentifier`）在代码里
    看不到引用，发布包里会被整个删掉。后果不是「图标退化成默认」而是**通知完全发不出来**：
    Android 13+ 构建「停止」CustomAction 时 icon id=0 →
    `IllegalArgumentException: You must specify an icon resource id to build a CustomAction`
    → 通知构建中途中止、媒体会话状态停更——真机表现为通知栏完全没有播放卡片，
    而 debug 包（不压缩资源）一切正常，极易误判成 ROM（如 ColorOS）问题。
    修复：`android/app/src/main/res/raw/keep.xml` 用 `tools:keep` 保留
    `@drawable/ic_notification,@drawable/audio_service_*`；`release.yml` 加了产物校验。
    今后新增任何「字符串引用」的资源（自定义 MediaControl 图标等）都要同步进 keep.xml。
35. **托盘对象必须长期持有（nativeapi finalizer），且 Linux 必须显式设置菜单触发方式**：
    `tray_manager 0.8` 的 `TrayIcon` / `Menu` / `MenuItem` / `Image` 都挂 nativeapi
    的 finalizer，对象被 GC 时会释放原生句柄——托盘图标或菜单会从系统里
    「无声消失」（不是崩溃）。所有创建出来的对象都要持有到 `dispose()`
    （`AppTray` 用静态字段 + `_itemListeners` 列表），不要只留局部变量。
    另一条同源事实：Linux 上必须
    `setContextMenuTrigger(ContextMenuTrigger.rightClicked)`——nativeapi 默认是
    `none`，此时 SNI 的菜单路径为 `/NO_DBUSMENU`，面板**完全没有菜单**
    （不是点不出来）。最后：Linux 图标是 StatusNotifierItem，需要有宿主
    （KDE / GNOME + AppIndicator 扩展）；无宿主的 Xvfb / WSLg 环境里图标不出现
    属预期，`AppTray` 会静默降级（只记日志），不要据此判定托盘实现坏了；
    组合根的关闭策略经 `AppTray.detectHost()` 判定宿主，无宿主时自动退回
    「关闭即退出」，不会把窗口藏成没有找回入口的状态。
