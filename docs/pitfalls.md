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
7. **（已解决 / 已移除）Web 平台**：项目不再构建 Web（音源引擎依赖 isolates 与原生库，
   播放 / 下载 / 同步也没有 Web 实现）。代码中不要重新引入 `kIsWeb` 分支或条件导入 stub。
8. **音源脚本是不可信代码**：不要在引擎里暴露文件系统/平台通道；网络只走 `lx.request` 桥。
   `currentScriptInfo` 必须原样透传（部分脚本有防篡改校验，校验失败会死循环）。
9. **ELECTRON 脚本兼容性**：脚本可能使用 `atob/btoa/TextEncoder/setTimeout/window/navigator`
   等 shim；扩展能力请加在 `lx_prelude.js` 而不是假设宿主提供。
10. **插件 JVM target 校验**：部分插件的 Java target(11) 与 Kotlin target(1.8) 不一致，
    AGP 9 默认按错误处理；已在 `android/gradle.properties` 设置
    `kotlin.jvm.target.validation.mode=warning`，不要删除。
11. **集成测试挂起保护（仅桌面）**：桌面端 LX 引擎 isolate / 原生平台通道未完全回收时，
    Flutter 测试进程会拒绝退出；`integration_test/lx_engine_integration_test.dart` 的
    `tearDownAll` 有 2s 上报窗口后 `exit(0)` 的看门狗（只在 Linux/Windows 注册），不要删除、
    也不要推广到 Android——Android 走官方 teardown（stopApp/uninstall）能干净退出，注册看门狗
    反而会抢在卸载/回收之前退出进程。
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
    未自定义「应用字体」时 Windows 读取系统 UI 字体
    （`HKCU\Control Panel\Desktop\WindowMetrics\MessageFont` 的 LOGFONTW
    face name，中文系统通常是 `Microsoft YaHei UI`；失败才回退引擎默认）。
    **不能**把 Flutter ThemeData 的 Windows 默认排版当作系统字体：它硬编码
    Segoe UI（Material Redmond 排版），中文靠 DirectWrite 逐字回退，Flutter
    官方明确不保证回退结果（flutter/flutter#103811），实测可能不是系统 UI
    字体。系统字体缺字时才用 `Segoe UI → Microsoft YaHei UI → Microsoft
    YaHei` 兜底；自定义「应用字体」优先，不追加这条链。其它平台不注入
    （引擎默认已是系统字体）。
    原生渲染面的跟随范围：Android 桌面歌词悬浮窗能跟（`OverlayConfig.fontFamily`
    → `Typeface.create`，解析不到回退系统默认）；通知 / 锁屏媒体歌词由系统
    （media3 / SystemUI）渲染、主屏小组件是 RemoteViews、托盘菜单与窗口标题栏
    归系统（GTK / Win32）——这四个改不了，别当 bug 修。
13. **发布体积**：新增资产前先评估体积；不要内置 CJK 字体（系统字体 + 用户安装）。
    Android 启动图标自 2026-10 起为手绘矢量（`drawable/ic_launcher_foreground.xml`，
    维护方式见 `icons_launcher.yaml` 头注释），该工具现在只生成 iOS 与 Windows 图标
    （Windows 的 `app_icon.ico` 同时是 exe/任务栏/安装器/快捷方式图标，不要手改）；
    `minSdk=35` 下传统 mipmap 密度图无意义，已全部移除，不要用工具再生成。
14. **省流模式的网络检测**：Android 8+ 后台不广播网络变化，`_MyThemedAppState` 在
    `resumed` 时调 `DataSaverService.refreshConnectivity()`，不要删除；
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
18. **通知 small icon 必须指向真实存在的 drawable**：Android 通知不支持自适应图标
    （`mipmap/launcher_icon`），资源 ID=0 时 `NotificationManager` 抛
    「Invalid notification (no valid small icon)」**直接崩溃进程**。
    下载通知在 `DownloadNotifications.kt` 显式引用 `drawable/ic_notification`
    （品牌矢量 + 16% inset）；系统媒体会话（Media3 / `flutter_media_session`）
    的 small icon 由插件内部提供，不依赖本仓库资源。
    换启动图标时同步维护 `ic_notification`。
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
    AGP 要求 ≥ 9.6（工具链表为 9.8.2）。构建前把
    `android/gradle/wrapper/gradle-wrapper.properties` 的 distributionUrl 改为
    `gradle-9.8.2-bin.zip`；另注意 JDK 27 + Gradle 9.3.1 会因 class file 71 直接
    失败（Gradle 9.8.2 + JDK 27 已验证可用）。
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
    `window_manager` 的 Dart 代码 import `dart:io`，散布进 UI 会把平台实现拖进
    其它平台的构建/测试；统一经 `window_chrome.dart` 收口
    （全仓库只有 `window_chrome_io.dart` 一处 import 该包，非桌面平台按不支持处理），
    同 `system_fonts_service.dart` 模式。
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
    启动期的**隐式写入**（`SyncProvider.init` 首次生成口令）是例外：写入失败
    在这里按「未设置」降级并继续（口令改为初始化即生成后，无钥匙串机器不再
    等到用户点开关才发现写不进去），用户主动重置口令时照旧抛给调用方。
32. **`build/linux/x64/debug/bundle` 可能是 `flutter test` 的产物，不是应用**：
    跑过 `flutter test integration_test/... -d linux` 之后，该目录里的可执行文件
    入口是测试 listener（VM Service `rootLib` 是 `flutter_test_listener.dart`），
    单独运行它不执行应用 `main()`——不渲染、窗口不出现，容易误判成「桌面端坏了」。
    手工验证桌面端用 `flutter run -d linux` 或先 `flutter build linux --debug`
    再跑 bundle（`tool/agent/test.sh linux` 会自行重建，不影响它）。

33. **桌面集成测试不再包含真实播放用例**：无头环境（Xvfb / CI runner）下
    media_kit/libmpv 偶发卡在 `playTracks` 装载，且 `Future.timeout` 无法打断
    （Dart isolate 被原生调用阻塞），会把整轮 CI / agent 测试吊死；失败后的
    teardown 还会在 `_engine.dispose()` 上二次挂起。`integration_test/
    lx_engine_integration_test.dart` 已删除播放与缓存写入用例，只保留引擎 /
    设置页 / 窗口 / 托盘 / 下载目录链路。播放服务由
    `test/playback/` 的单测与真机手动验证覆盖；若将来要恢复：
    - mock 音频时长留足（曾用 30s），慢 runner 上起播本身就要几秒；
    - Android/iOS 音频依赖模拟器设备，播放用例只能桌面跑；
    - 无头 runner 要给 libmpv 一个「按实时速率消费」的虚拟音频输出：
      PulseAudio + null sink（`pulseaudio -D --exit-idle-time=-1 --disable-shm`
      → `pactl load-module module-null-sink` → `pactl set-default-sink`，并
      export `XDG_RUNTIME_DIR`），否则 libmpv 打不开输出或不节流，症状都是
      「播放瞬间结束」→ 断言拿到下一首或「播放未开始」；
    - 装载与 teardown 都要有不可绕过的上限（或放到隔离进程/真机 job）。
34. **release 的 `shrinkResources` 会删掉「字符串引用」的资源，媒体通知直接不出现**：
    release 开了 `minifyEnabled + shrinkResources`，AAPT 只按静态引用判定资源存活；
    `ic_notification`（下载通知按字符串配置）与 `audio_service_*` 播放顺序图标
    （`flutter_media_session` 运行时 `getIdentifier`）在代码里看不到引用，发布包里
    会被整个删掉。后果不是「图标退化成默认」而是**通知完全发不出来**：
    Media3 / NotificationCompat 构建动作时 icon id=0 直接抛
    `IllegalArgumentException` → 通知构建中止、媒体会话状态停更——真机表现为
    通知栏没有播放卡片，而 debug 包（不压缩资源）一切正常，极易误判成 ROM
    （如 ColorOS）问题。修复：`android/app/src/main/res/raw/keep.xml` 用
    `tools:keep` 保留 `@drawable/ic_notification,@drawable/audio_service_*`；
    `release.yml` 加了产物校验。
    今后新增任何「字符串引用」的资源（自定义动作图标等）都要同步进 keep.xml。
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
36. **Android 17（API 37）局域网默认阻断，且「手动填 IP」救不了权限**：
    `targetSdk 37` 起访问局域网（UDP 单播·组播·广播的收发、对局域网地址的
    TCP 连接）需要运行时权限 `ACCESS_LOCAL_NETWORK`，未授予时 Dart socket
    直接抛 `SocketException`，而且**网关级阻断**——手动填对端 IP:端口同样失败。
    因此：权限被拒时只能引导授权（Android 自有 `top.stillmisty.molia/local_network`
    通道）或改用 WebDAV；「手动对端地址」只解决发现失败（AP 隔离 / 多网段 /
    防火墙 / VPN）。
    manifest 已声明该权限；LAN 传输启动前经 `LocalNetworkPermission` 过门，
    被拒时状态记为 `permission_denied`（UI 给「授予权限」入口 + 去系统设置），
    不再出现「开关打开但什么都没在跑」。Android 16 上该限制是 opt-in，
    所以「模拟器/老系统能跑」不能作为验收证据。
37. **iOS 的广播发现需要单独向 Apple 申请的 multicast entitlement**：
    `com.apple.developer.networking.multicast` 覆盖「发送 / 接收 IP 组播与广播」，
    必须申请获批（Multicast Networking Entitlement Request）；`Info.plist` 的
    `NSLocalNetworkUsageDescription` 只负责隐私提示，不解决广播权限。
    未获批 / 未接线时的正确姿态是**降级**（手动对端地址 / WebDAV），不是崩或死等。
    另：**模拟器不需要该 entitlement，真机才需要**——模拟器上的广播「看起来正常」
    不能作为验收证据；entitlements 文件与启用步骤见 `ios/Runner/Runner.entitlements`
    注释（获批前不要把 `CODE_SIGN_ENTITLEMENTS` 接上去，会让签名失败）。
38. **Linux 桌面集成是打包资产，不是运行期代码**：`.desktop` 与 hicolor 图标在
    `linux/packaging/`（`release.yml` 的 linux job 拷进 tarball，用户解压后跑
    `install.sh` 装到 `~/.local/share`）。`.desktop` 文件名必须与
    `linux/CMakeLists.txt` 的 `APPLICATION_ID` 一致（Wayland 靠 app_id ↔ 文件名
    匹配 dock 图标），`Icon=` 必须与 hicolor 文件名一致；不要手改那批 PNG，
    再生成命令见 `linux/packaging/README.md`；X11 的运行期窗口图标走
    `assets/icons/app_icon.png`（`WindowChrome` 调 window_manager 的 `setIcon`，
    与 hicolor 集合同源），Wayland 下该调用无效也不报错。契约由
    `test/packaging/linux_desktop_test.dart` 守住。

39. **桌面歌词位置样本不能按到达时刻重设基准**：位置样本经 Dart（≤4Hz）→ 通道 →
    原生主线程到达，投递延迟随宿主负载波动；旧实现每次采样都 `base = 样本;
    baseTime = now`，把这段抖动 1:1 变成可见回跳（忽快忽慢）。现在由
    `LyricClock` 承担时基：先按 `positionAtEpochMs`（Dart 侧「该位置生效的墙上
    时刻」，两端同设备壁钟相减即延迟，夹取上限防时钟调整）外推，再按相位误差
    分档收敛（≤100ms 10% / 100–300ms 20% / >300ms 落位）。两条不要改回去：
    ① 时基必须由宿主 `LyricsOverlayView` 持有（切行重建 `CurrentLineView` 不重锚）；
    ② 暂停 / seek / 换曲才允许硬落位；③ 暂停时**不做**延迟补偿（位置不推进，
    外推会把暂停样本凭空推后一个传输延迟，实测 188ms）。诊断：
    `adb shell setprop log.tag.MoliaLyrics DEBUG`（默认级别静默）后看
    `err=/transit=/snap=/frames=` 打点（`frames=0` 说明帧循环没跑）。
40. **不要只为单个运行时权限引入 `permission_handler`**：它的 Windows 实现
    （`permission_handler_windows`）在插件注册时就创建 `Geolocator` 并订阅
    `PositionChanged`（回调为空），Windows 因此把整个进程标记为「正在使用位置」——
    即使应用从未申请位置权限（上游 #1394，修复 PR #1568 长期未合并）。Molia 只用它
    申请 Android 17 的 `ACCESS_LOCAL_NETWORK`，现已改为自有通道
    （`android/.../sync/LocalNetworkPermissionChannelHandler.kt`）。依赖移除后，
    `windows/CMakeLists.txt` 里为 `permission_handler_windows` 加的 MSVC
    `/await` 消音宏（`_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`）
    也一并删除。若将来重新引入权限库，必须先在 Windows 上确认定位指示器不再常驻。
41. **桌面窗口「先建不显」与强制单实例是配套的，动其中一条要看另一条**：
    `WindowChrome.ensureInitialized()` 只建窗（隐藏标题栏 + 恢复几何）不 `show`，
    窗口由 `main()` 的首帧回调 `WindowChrome.show()` 亮出（runApp 前的装配有几百 ms，
    先显示会让用户盯空白窗），并挂 5s 超时兜底（装配异常时窗口也一定出现）。
    强制单实例（`lib/services/window/single_instance*.dart`）在窗口创建**之前**抢锁，
    第二实例连上主实例的 loopback 端口发 `show` 后 `exit(0)`——因此
    `SingleInstance.isSupported` 必须与 `WindowChrome.isSupported` 同一平台面：
    窗口能力缺失的平台（如 macOS 走 stub）上若仍拦第二实例，用户会「点了图标什么都不发生」。
    开发/测试实例用 `MOLIA_SINGLE_INSTANCE_DISABLED=1` 放行（`tool/agent/_common.sh`
    已默认导出），否则本机开着应用时 `flutter run` / 集成测试会被单实例逻辑静默退出。
42. **窗口几何记忆里「最大化」与「几何」必须分开读写**：最大化期间
    `getBounds()` 返回的是最大化矩形，写进 bounds 会丢掉还原尺寸，所以保存路径在
    最大化态只写 `window_maximized` 标记、不写几何；相应地恢复路径也不能
    「几何缺失就整体跳过」——「首次启动就最大化 → 退出」这类会话只有标记可读，
    跳过就等于最大化状态永远恢复不了（`WindowBoundsStore.loadMaximized()` 独立读取）。
43. **桌面歌词滚动组的 `translationX` 符号与行宽**：滚动组（当前行 + 翻译 / 罗马音）强制
    `Gravity.START`，对齐与横滚都在 `applyGroupScroll` 里用位移实现——`translationX`
    正 = 内容右移，与 `scrollX`（正 = 内容左移）相反。符号写反时：居中 / 右对齐把整行
    推到屏幕左外（首字被裁，短句如「我接着写」4 字会整句消失），长行滚动方向也反过来
    （越唱越往右、行尾永远露不出来）。未超宽时对齐取正位移、超宽后由 0 递减到 −溢出，
    两者共用 `x = alignedShift - scroll`；改动前先读 `docs/lyrics_display.md` §4 FR-3
    的符号约定。**行视图宽度必须取文本宽**（`scrollingRowWidth`，不是 `MATCH_PARENT`）：
    位移是「行视图连自己的裁切边界一起走」，行视图只有视口宽时，移出视口的部分是
    行视图自身边界裁掉的——行尾永远露不出来（表现为「长歌词滚动被截断」）；视口裁切
    由 `contentHolder.clipChildren` 承担，溢出/对齐都按裁剪盒内宽算，不能拿行视图
    `width` 当视口——拿行视图当视口时行尾会被它自己的边界裁掉。
44. **悬浮窗位置要按「可用区」算，不能用 `resources.displayMetrics`**：
    `TYPE_APPLICATION_OVERLAY` 默认按 system bars / 刘海 insets 收边（fitTypes），
    `LayoutParams.x` 从安全区左缘起算、`y` 从安全区底缘起算（`Gravity.BOTTOM`，
    正数向上）；edge-to-edge Activity 的 `displayMetrics`（≈整屏，模拟器实测 2400 vs
    悬浮窗实际可用 2274 + 63px 偏移）把状态栏高度算进可用空间，贴底摆放时被导航栏
    裁掉。可用区取 `WindowManager.currentWindowMetrics` 减
    `systemBars | displayCutout` insets，位置相关的几件事都收在
    `LyricsOverlayController`，别拆开：
    ① 比例写读同一套公式（历史上写 `y/(H−h)`、读 `H*yf`，每次重建窗口整体下移 ~7%，
    拖到底部后直接落到屏幕外）；② 纵向用**底缘**比例 + `Gravity.BOTTOM`：窗口高度
    要等首次布局才有，底缘锚定不依赖高度，高度变化时底边固定、向上生长；反过来用
    `Gravity.TOP` 先把 `y` 当顶缘占位、再在布局回调里减高度，会让第一帧先画在下面、
    下一帧再跳上去（单行歌词最明显，每次窗口重建 / 暂停恢复都复现）；
    ③ 窗口尺寸 / 可用区变化（行数、控制条弹出、旋转 / 字号）后重算宽度并夹取，
    底边不因内容高度变化而移动；
    ④ 旧键 `y_fraction` 语义与底缘比例不同，改名 `bottom_fraction` 让旧值自然失效
    （不迁移：旧值按老公式写，直接读会错得更偏）；
    ⑤ 布局回调也会被「纯移动」触发：只认尺寸真的变了（`maybeAnchorIntoArea`），
    且拖动中一律不落位（`isDragging`）——否则每帧 `updateViewLayout` 后立刻被比例
    拽回原位，表现为「悬浮窗拖不动」；
    ⑥ `Gravity.BOTTOM` 下 `LayoutParams.y` 是「可用区底缘到窗口底缘」的偏移：
    拖动写 `startTouchY − dy`、拖动结束按 `(area.y − y) / area.y` 换算比例；
    方向写反会拖不动或拖反，四个写入点（创建 / 落位 / 拖动 / 拖动结束）必须同口径。
45. **一次 Esc 会被多个作用域同时消费，`HardwareKeyboard` 的返回值裁决不了**：
    它的处理器**全部执行、返回值不短路**（SDK 原文：All registered handlers will be
    invoked in order regardless of their return value），壳层可配置快捷键（默认
    Esc = 收起播放页的队列视图）与页面级 / 弹层处理器（收藏页多选、音量弹层）会同时
    收到同一次按键；同时焦点分发也不会因处理器返回 true 而跳过。裁决统一走
    `lib/services/escape_claims.dart`：页面级 / 弹层登记「此刻的 Esc 归我」，壳层
    命中 Esc 命令前先让位（返回 false）。新增 Esc 消费方时先登记，且登记判定必须
    与自己的按键处理器**同源**、现算（隐藏页 / 已关弹层不残留占用）；不要在各自的
    处理器里「先到先得」，也不要用 `Focus.onKeyEvent` 接弹层 Esc——焦点被 Tab 移出
    弹层后收不到按键，登记又让壳层让位，按键被完全吞掉。注意登记只对壳层让位——
    两个非壳层消费方同时可见时（如收藏页多选 + 音量弹层）仍会各处理一次。
46. **Windows 宿主保留端口块：UDP 绑定 errno 10013 不该被当成传输启动失败**：
    WSL2 **mirrored 模式**下 Windows 宿主会把大段端口标记为系统保留（本机实测
    44620–48715），Dart / Winsock 绑定这些端口抛
    `SocketException ... errno = 10013`，而 `netsh excludedportrange show`
    **看不到**这些块（上游 microsoft/WSL#40169）——排查时不要只在 netsh 里找。
    处置：`LanSyncTransport` 的 UDP 绑定先试标准端口、失败只记警告并改绑系统
    分配端口（对端按探测包里自报的 `udpPort` 单播回来），HTTP 端点能起来时
    传输照常运行；只有 HTTP 也起不来才是 `start_failed`，UDP 不可用时给
    `probe_port_unavailable` + 「添加设备」手动地址直连。端口被普通进程占用
    抛的是 `errno = 10048`，症状 / 处置相同。
    IPv6 相邻坑：Windows 防火墙要**单独放行 IPv6**（IPv4 规则不覆盖）；组播
    源的地址必然是 link-local，必须带 zone 才能连（Dart 的 URI 用 `%25` 表达，
    `InternetAddress` 对象自带 zone）——所以探测包交换 `addrs` 可路由候选地址，
    不要拿观测到的源地址直接拼 HTTP；镜像模式下 WSL↔Windows 之间 IPv6 不通，
    两端都在 WSL 或都在 Windows 才能按 IPv6 直连。
47. **多网卡 / 虚拟网卡环境手动配对：地址列表里的地址不是每个都能用**：
    设置页「本机」列出全部可路由地址（接口名 + 地址），配对时要挑**两台设备
    真正互通的那条链路**：
    - 同一 Wi-Fi / 以太网：挑 `wlan0` / `eth0` / `en0` 上的私网地址
      （`192.168.x` / `10.x` / `172.16–31.x`）；`docker0` / `veth` / 虚拟机
      网卡（WSL `vEthernet`、Hyper-V `vEthernet (Default Switch)`、VirtualBox
      host-only）的地址对宿主之外不可达，别填；
    - Windows + WSL2：mirrored 模式下 WSL 内的 Molia 与 Windows 侧 Molia
      可以互相直连；NAT 模式下 WSL 只有 NAT 地址，跨 WSL↔Windows 请改用
      WebDAV，或把两端都放在同一侧跑。`lo` 上的 `10.255.255.254` 一类宿主
      地址只在 mirrored 模式有意义，不要当成通用兜底；
    - 跨 NAT / 不同子网：内网地址怎么填都不通，直接用 WebDAV。
    手动配对步骤：① 一端复制「分享配对信息」（或手抄地址 + 探测端口）；② 在
    另一端「添加设备」粘贴 / 填写，接触成功才关弹层（失败留在弹层内可改）；
    ③ 接触成功后名册出现设备行，点开可看端点端口 / 设备 id / 删除；④ 配对码
    里带多个地址时，未认领的条目在名册折叠成一行「候选地址 N 个」，点开可
    逐个查看与删除——「尚未接触」只是还没碰上，对端上线后会自动重试。
48. **扫码走 unbundled ML Kit：无 GMS 隐藏入口，模型下载失败给「改用粘贴」**：
    `mobile_scanner` 在 Android 上按 `android/gradle.properties` 的
    `dev.steenbakker.mobile_scanner.useUnbundled=true` 选
    `com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1`
    （AAR 0.5MB），而不是 bundled 的
    `com.google.mlkit:barcode-scanning:17.3.0`（AAR 9.9MB，arm64 `.so` 4.72MB）
    ——扫码只是可选的配对入口，不值得让所有安装包变胖；iOS 不受影响（darwin
    实现走系统 Vision/AVFoundation）。代价与处置：
    - **无 GMS 设备**（AOSP / 部分国产 ROM）不显示扫码入口：
      `PlayServicesAvailability` 经自有通道 `top.stillmisty.molia/play_services`
      （原生 `GoogleApiAvailability.isGooglePlayServicesAvailable == SUCCESS`）
      门控；探测中与不可用都不构建按钮（不给死胡同、也不做 loading 占位）。
      false **不缓存**（用户会话中装了 Play 服务，重开弹层应出现入口），
      true 会话内缓存；
    - **有 GMS 但模型首次下载失败**（无网络 / 访问不了 Google 服务）：扫码页
      按 `scanErrorKind` 识别为 `modelUnavailable`，给「重试 / 改用粘贴」；
    - 排查「没有扫码按钮」先查 GMS，再查平台判定（`SyncPairingScanner`）；
      改回 bundled 只需删掉那行 gradle 属性（包体 +9.4MB 量级）。
    另：`PlayServicesChannelHandler` 用的 `play-services-base` 由
    `play-services-mlkit-barcode-scanning` 传递带入；若某天 Gradle 解析不到
    `GoogleApiAvailability`，在 `android/app/build.gradle*` 显式补
    `implementation("com.google.android.gms:play-services-base:18.11.1")`。
49. **桌面歌词：横滚必须在切行前收尾，重建后要等整列布局完成再摆位**：
    两个同源缺陷都来自「滚动只看词轴、摆位只看主行」：
    ① 进度只看词轴：词轴越界（末词时间晚于下一行时间戳）时进度永远到不了 1，
    或末词恰好在切行时刻收尾——切行时行尾还没露出来，表现为「长歌词滚动被
    截断」。`CurrentLineView.playedFraction` 因此分两支：词轴能在行内收尾时按
    词轴推进、位置整体提前 300ms；词轴越界或没有词轴时按行时间轴线性推进并
    提前 300ms 收尾（夹进行长的 1/3）——行尾在切行前完整露出、留出可读时间。
    匀速模式的跨度也在 Dart 侧夹到 tracker 的行尾
    （`LyricsDisplayProvider._buildPresentation`）。行视图宽度与视口口径见第 43 条。
    ② 重建（换行 / 翻译开关）后主行的 `onSizeChanged` 先于扩展行布局触发：
    翻译 / 罗马音此时宽度还是 0，组偏移把它算到左缘（x=0），而**没有后续
    回调纠正**（暂停时没有帧循环）——表现为「切翻译时闪到左侧再恢复」。纠正
    挂在整列的 `addOnLayoutChangeListener`（ViewGroup 先 `onLayout()` 子视图、
    后回调），在同一帧绘制前用真实宽度重摆；`DesktopLyricsOutput.start` 同步
    按配置去重（`controls` 是每次现取的 unmodifiable map，按键值比较）——
    不去重时任何设置变化都会触发重建，会放大这个闪动。
50. **接线型缺陷：引擎漏接增量日志，测试全绿而生产跑了两年的全量模式**：
    `SyncEngine` 的 `journal` 是可空参数（未注入时仍正确，只是退化为「每轮全量
    快照」：全库指纹、整库加密推送、`serveJournal` 退化为全量、`compact` 从不
    执行因而 `sync_journal` 只写不裁）。组合根 `buildSyncStack` 从未传它，
    而引擎测试各自注入 journal（或不需要）、组合根冒烟测试又没覆盖
    `buildSyncStack`——缺陷因此长期不可见。教训与契约：
    - 「可选注入的降级路径」必须有**组合根级**断言（现由
      `SyncEngine.incrementalEnabled` + `test/app/bootstrap_smoke_test.dart`
      的 `syncStack` 用例守住），不能只靠单元测试；
    - 新增此类「注入了才走快路」的参数时，同步补一条组合根断言；
    - 症状排查入口：同步日志页每轮 `durationMs` 与 `bytesOut`（全量模式下
      任何本地变更都会重传整库）、`sync_journal` 表行数只增不减。
51. **派生状态（journal / known / 游标）允许重建，但重建后必须回退游标语义**：
    升级 / 迁移清空 `sync_journal` 后本机头部归零，而各对端记录的游标还是旧值
    （如 5000）：`serveJournal` 会给出空窗口，对端判成「没有缺口、无需拉取」，
    之后新增变更的 seq（1、2、3…）全部小于游标——**永久静默跳过**。修复在两侧：
    发送侧 `since > head` → 回全量快照（让对端重新引导）；接收侧全量快照把
    游标**落在快照覆盖位置**（不是取最大），且待提交游标允许回退。回归用例见
    `test/sync_pipeline_reset_test.dart`。任何将来「清日志 / 换载荷格式」的改动
    都要带上这条语义。
52. **游标 -1 与「seq 从 1 开始」：三处 off-by-one 都会让全新对端退化成 bootstrap**：
    日志 seq 从 1 开始、`cursorSeq = -1` 表示「尚未消费任何条目」，两者相减时
    `cursor + 1 = 0` 不是合法的第一条。按 `cursor + 1` 推算起点的地方都要把
    游标夹到 0（或把起点夹到 1）：
    ① 窗口完整性 `cursor < baseSeq`：`-1 < 0` 会把「正好从头开始」判成「窗口
    已被裁剪」→ 白做一次全量 bootstrap（快照还可能早于本次变更，白丢一窗）；
    ② 条目连续性 `expected = cursor + 1`：首条 seq 1 ≠ 0 → 判成「首条即空洞」
    → **增量窗口永远吃不下**；
    ③ 缺口判定 `windowEnd > cursor`：空窗口（`windowEnd = 0`，回执类载荷）
    在游标 -1 时被当成「窗口被截断」。
    这三处在旧布局下被掩盖：局域网 `serveJournal(since = -1)` 与单文件 WebDAV
    都会给全新对端**回全量快照**（`since < baseSeq(0)`），增量窗口根本到不了
    全新对端；改成分块文件后增量直接发给全新对端，才全部暴露。回归用例：
    `test/sync_engine_test.dart`（空窗口 / 截断）、`test/sync_webdav_e2e_test.dart`。

53. **统计曲目内容在 `play_tracks`，不在事件行（v5）**：`play_events` 只存
    事件自身字段（时间 / 进度 / 结束原因 / 版本 + `trackId`），曲目元数据与
    取链参数在 `play_tracks`（每曲一行，`UNIQUE (sourceKey, songId)`，`raw` 是
    **gzip 字节**）。为什么：事件是 append-only，逐行复制元数据 + 载荷在保留
    窗口（20k 行 / 365 天）下实测 18 MB（内置平台载荷 ~700 B/条）到 97 MB
    （LX 脚本原样透传平台对象 ~3.6 KB/条）——内容表 + gzip 后是 4.1 MB / 6.4 MB。
    改这块要同时守四条：
    ① **读取一律 join**：`sourceKey` / `songId` / `title` / `artist` / `album` /
       `coverUrl` / `durationMs` / `raw` 都不在事件表上；连表后 `_qualifiedPredicate`
       必须写 `pt.durationMs`（否则列名歧义 / 找不到列）；
    ② **写入口径是「内容时间取新」**：`_upsertTrack` 只在事件 `startedAt` 不早于
       内容行 `updatedAt` 时覆盖——远端补发的旧事件不许顶掉新内容；记录没带
       `raw` 时不覆盖载荷（`Value.absent()`）；
    ③ **载荷按 gzip 存**（`stats_payload_codec.dart`）：写入 `encodeStatsPayload`、
       读取 `decodeStatsPayload`，别再往库里塞明文 JSON（解码器对非 gzip 字节做了
       明文降级，只为迁移期兜底）；线上记录 / 日志条目必须在导出侧解码补齐，
       否则远端拿到的是二进制乱码；
    ④ **载荷预算**（`PlayStatisticsRepository.maxRetainedPayloadBytes`，默认
       16 MB）：超出按「最近播放」保留、其余清 `raw`（点播回退重新解析）——
       单条载荷大小由脚本决定，行数上限约束不了字节。
    迁移（v4 → v5）在 `from4To5`：内容行取每曲最新一行快照（SQLite 单 min/max
    聚合的裸列语义）+ Dart 侧 gzip 搬载荷 + `alterTable` 给事件加 `trackId`
    （先 `DROP INDEX idx_play_events_track`，否则 alterTable 会重建这个引用
    已删列的索引）。回归：`test/drift/molia/migration_test.dart` 的
    「from v4 to v5」数据用例、`test/play_statistics_repository_test.dart` 的
    「曲目内容表」组。

54. **横向滚动视图在桌面端「拖不动、滚轮不动」是两个独立成因**：
    ①鼠标拖动被 `ScrollBehavior.dragDevices` 挡掉——默认集合不含
      `PointerDeviceKind.mouse`，要 `ScrollConfiguration.of(context).copyWith(
      dragDevices: {…dragDevices, PointerDeviceKind.mouse})` 才放开（跟手拖动还要求
      内部是自由滚动档，如 `M3ECarousel.freeScroll`，否则仍是一步一张）；
    ②横向轴只吃 `scrollDelta.dx`，普通滚轮给的是 `dy`，到不了横向 `ScrollPosition`——
      要自己接 `Listener.onPointerSignal` 把 dy 攒成步进。自接信号时三个边界容易漏：
      消费要经 `GestureBinding.instance.pointerSignalResolver` 占住这次信号（否则同一次
      滚轮顺带把外层竖向页面带走，哪怕这一格还没攒够）、翻卡动画进行中与贴边方向不要
      消费（让给外层滚动）、按累计阈值 + 动画去重（一次惯性连翻好几张）。
    回归：`test/widgets/ai_dj_carousel_test.dart`（发现页卡片流两个平台形态都覆盖）。
55. **`M3EMenu` 只能贴锚点组件的矩形弹出，按鼠标落点弹要绕开 `M3EMenu.entries`**：
    `anchorBuilder` 锚定的是某个 widget 的矩形；行表面右键只拿到一个坐标，没有对应
    组件。按落点弹用 `showM3EMenu` + 零尺寸 `Rect.fromLTWH(x, y, 0, 0)` 作锚点
    （`bottomStart` 自落点向右下展开，贴屏幕边 / 空间不足由 M3E placer 夹取与上翻，
    不要再算第二套边界）。坐标系必须与 `showM3EMenu` 插入的 overlay 一致——它固定
    插进 **root overlay** 并按局部坐标摆位：`Overlay.of(context, rootOverlay: true)`
    取 overlay 的渲染对象（`RenderBox`）`globalToLocal` 换算 `globalPosition`；
    拿不到渲染对象时原样使用（根 overlay 无祖先变换，全局 = 局部）。唯一实现：
    `lib/widgets/track_actions_menu.dart::showTrackActionsMenuAtPointer`
    （触摸端 ⋮ 仍走 `M3EMenu.entries` 的组件锚点）。


56. **release 包才暴露：插件换 Pigeon JNI 后与 R8 混淆冲突（偏好读取直接炸）**：
    `shared_preferences_android 2.5.0` 把内部实现换成 Pigeon JNI，Dart 侧按**未混淆**的
    类名 / 方法签名查 Java 方法（生成的签名串里带 `kotlin/coroutines/Continuation`、
    `kotlin/jvm/internal/DefaultConstructorMarker`），而 `minifyEnabled true` 的 release
    构建下 R8 会把这些 Kotlin 类型改名（`Continuation` → `uw`）甚至整个删掉
    （`kotlin.coroutines.intrinsics.CoroutineSingletons`）——启动读偏好即抛
    `PlatformException(NoSuchMethodError / ClassNotFoundException)`，在 `main()` 的并行
    装配里外层表现为 `ParallelWaitError`；**debug 构建完全正常**，只有 release 复现。
    处置：钉 `shared_preferences_android: 2.4.28`（JNI 改造前最后一个版本，理由与复评
    条件写在 `pubspec.yaml` 注释里）。补 keep 规则试过——修完 `Continuation` 又缺
    `CoroutineSingletons`，是打地鼠且 APK +1.1MB，放弃；上游补 consumer-rules.pro 后再升。
    2026-10-20 复评：2.5.1 仍无 consumer-rules.pro，release 包启动仍在
    `SharedPreferencesApiRegistrar.getAll` 抛同样的 NoSuchMethodError。
    发现路径：Android release APK 装设备启动后 `adb logcat | grep -E
    "NoSuchMethodError|ClassNotFoundException"`；`tool/agent/startup.sh android`
    会构建并安装 release APK 跑采样，顺带当这道冒烟。

57. **M3E 搜索视图（`M3ESearchAnchor`）不适合「就地展开」的全屏遮罩**：包内 docked
    视图的目标矩形完全由锚点矩形推导（`_dockedRect` 的 x / y / 宽都取自 `begin`），
    锚点只要摆在搜索条静止位置，容器变换的位移就是 0——开合没有过渡动画（只剩一层
    容易被忽略的 scrim 淡入），且包内只在容器变换弹簧落定后才给输入框聚焦
    （`_tryFocusViewField` 挂在弹簧的 TickerFuture 上），Ctrl+F 之后立刻打字的按键
    会被吞掉（实测 5 个字符丢 2 个）。包内没有暴露动画 / 聚焦钩子，遮罩要动效与
    「打开即可输入」只能自建 route（出现 / 消失自己走 scrim 淡入 + 内容淡入轻微缩放，
    输入框首帧 autofocus）。回归：`test/app/desktop_shell_test.dart` 的
    「遮罩开合走淡入 + 缩放过渡」「打开后首帧即可输入」两条。

58. **局部 `DefaultTextStyle` / `AnimatedDefaultTextStyle` 是「替换」不是合并**：
    SDK 内部就是 `DefaultTextStyle(style: lerp(...))`（`implicit_animations.dart`），
    写字面量样式会把**字体族**（应用字体 / 平台默认）一并丢成引擎默认字体——症状是
    「设置里选了字体，只有这块内容不跟随」（歌词行曾整段中招）。局部样式必须从环境
    派生：`DefaultTextStyle.of(context).style.copyWith(…)`，只覆盖要改的属性；
    `Text(style:)` / `Text.rich` 是**合并**，本身安全，但在被替换过的环境样式下也会
    一起丢字体——先修替换点。回归：`test/widgets/lyrics_widget_test.dart` 的
    「歌词行跟随应用字体：主行 / 逐字 / 翻译 / 罗马音」。
59. **Windows 任务栏的图标与名字来自「应用身份」，不是现取 exe 资源**：任务栏上有
    三条取图路径，互不共享——按钮走窗口图标（类图标 / `WM_SETICON`）、悬浮预览
    头部与右键菜单头部走 shell 按 **AppUserModelID 解析后缓存**的图标。换过图标的
    旧构建会在 shell 里留下旧图，实际表现是「任务栏按钮是品牌图、右击菜单头部
    还是 Flutter 默认图」。修法（见 ADR-0012、`windows/runner/shell_identity.cpp`）：
    启动时写 `HKCU\Software\Classes\AppUserModelId\<AUMID>`（`DisplayName` +
    `IconUri` = exe 全路径），并给窗口类补 `hIconSm`、窗口补 `WM_SETICON`，
    不要让 shell 走「自己派生 / 回退缓存」的路径。
    同源事实（缩略图工具栏 `ThumbBarAddButtons`）：① **挂载时机有硬门槛**——任务栏
    按钮由 shell 异步创建，MSDN 的 ITaskbarList3 页面写明「收到
    `RegisterWindowMessage("TaskbarButtonCreated")` 之前不得调用任何 ITaskbarList3
    方法」；早了返回 `E_INVALIDARG`，而且按钮**永远不会**出现（构建、图标、文案全对
    也一样），真机表现就是「悬浮预览里一个按钮都没有」。实现里用一道「收到过该消息」
    的门闩把这条规则固化下来，重挂策略与 LX Music 桌面端（每次 show、每次播放状态
    变化都重下发按钮）等价：`TaskbarButtonCreated` → 复位后重挂；窗口重新显示 / Dart
    状态变化 → 已挂走 `ThumbBarUpdateButtons`、失败回落 `ThumbBarAddButtons`；挂载
    失败退避重试两次，耗尽后等下一次触发点自愈；② `explorer.exe` 重启会清空工具栏，
    靠 `TaskbarCreated` 广播**复位门闩**（不要拿它当「现在可以挂了」的信号——它和
    `TaskbarButtonCreated` 是两条不同消息，前者只是广播通知，后者才是新按钮就绪）；
    ③ 按钮图标必须是 **32 位、`SM_CXICON`×`SM_CYICON`** 的 HICON（100% 缩放 = 32，
    150% = 48，200% = 64），且任务栏**不随主题反色**——浅色任务栏要另备一套暗字形，
    按 `SystemUsesLightTheme` 切换；④ `/W4 /WX` 下结构体成员别在中间混放
    `bool` 与指针 / `std::wstring`（成员间填充会触发 C4820，警告即错误），标量放末尾。
    图标资源是生成物：改字形后跑 `python3 tool/gen_taskbar_icons.py`。
60. **Windows 安装器改快捷方式名必须显式删旧文件**：Inno 的 `[Icons]` 只负责创建，
    品牌名从「Molia 茉咏」改成「Molia」后旧 `.lnk` 不会自动消失，开始菜单 / 桌面会
    各留一个指向同一个 exe 的入口。改快捷方式名时同步补
    `[InstallDelete]`（`{autoprograms}` / `{autodesktop}` 两个位置，见 ADR-0011）。
61. **Android 媒体通知的按钮位置由「Media3 provider + 系统 UI」共同决定，Dart 侧改不动**：
    通知由 Media3 `DefaultMediaNotificationProvider` 构建，`getMediaButtons()` 固定先给
    `[上一首][播放/暂停][下一首]`，再把自定义动作（`lx.playMode` / `lx.favorite`）按 Dart
    传的顺序追加；`createNotification()` 还会先过滤掉所有非自定义
    （`COMMAND_CODE_CUSTOM`）按钮，所以 `setCustomLayout` / `setMediaButtonPreferences`
    里排的标准按钮顺序**一律被丢弃**。唯一的位置旋钮是 `CommandButton` extras 的
    `COMPACT_VIEW_INDEX`（折叠态 3 个槽），而 `flutter_media_session 3.0.9` 把
    `customExtras` 塞进 `SessionCommand` 的 extras、不是 `CommandButton` 的，够不到。
    真正决定位置的是**系统 UI**：ColorOS 17（Android 17）实测通知动作列表是
    `[上一首][播放][下一首][播放顺序]`，媒体卡片却画成 `[播放顺序][上一首][暂停][下一首]`
    （自定义动作贴左）。结论：新增自定义动作只能控制「自定义动作之间」的先后；要精确到
    「收藏最左 / 播放顺序最右」得 vendor 插件覆盖 provider，且系统仍可能重排（见 ADR-0013）。
62. **`SourceTrack` 的 `songId` 与 `id` 不是一个东西，读收藏 / 缓存 / 历史别拿 `id` 当 songId**：
    `songId` 是平台内歌曲 id（raw 取键 → 兜底 `标题-歌手`），`id` 是全局唯一包装
    `'$sourceKey:$songId'`（`lib/sources/source_track.dart`）。凡是要按
    `(sourceKey, songId)` 成对查的接口（`LibraryProvider.isFavorite`、缓存文件名、
    下载记录、播放历史）都必须传 `songId`：传 `id` 会算成 `wy:wy:186016`，查不到任何东西
    且**不报错**——真机表现是「点通知栏收藏没反应」（写路径经 `trackFromSourceTrack`
    是对的，所以数据其实写进曲库了，只是读不回来）。同类回归测试见
    `test/playback/local_audio_handler_test.dart` 的「接线后点收藏」。
63. **「播完当前歌曲」定时不能靠进度通道判断曲末**：`just_audio` 的
    `positionStream` 由 Dart `Timer.periodic` 驱动，熄屏 / 后台时可能被节流或整段
    停更；而播放器原生完成事件仍会到达并继续自动切歌。只靠 `_maxPosition` 会把
    自动切歌误判成手动切歌，把定时重新武装到下一首，表现为「息屏后永远不暂停、
    亮屏时下一首还在播」。现在 `LocalPlaybackService` 在
    `ProcessingState.completed` 时先发 `trackCompletions`，并由
    `stopAfterCurrentTrack` 一次性标志在自动切歌前停住；`SleepTimerController`
    优先消费完成事件，位置判定只作远程后端 / 测试的回退。回归用例见
    `test/playback/sleep_timer_test.dart` 的「熄屏后位置 tick 停在半途」。
64. **Android 模拟器的「第一个平台通道调用」有约 400ms 固定等待，别把它算到
    prefs / DB / 媒体会话头上**：release 冷启动时，Dart `main()` 开始后第一个
    `MethodChannel` 往返要等引擎 / 平台线程就绪（临时用现有 `updater` 通道的
    `supportedAbi` 做首调探针，9 次中位 396ms）。这段等待会落在**第一个 await
    平台通道的阶段**：改前表现为 prefs 或本地数据栈 400ms，改后表现为省流 prefs
    或媒体会话 400ms；整体首帧仍在 ~470ms。排查启动阶段前先看
    `docs/performance.md` §7.1 与 `startup_trace.dart` 的子阶段埋点，不要因为
    某个阶段偶尔 400ms 就继续挪它。
    试过并否证：排除 `androidx.window` 依赖（启动直接
    `ClassNotFoundException: WindowMetricsCalculator`，Flutter 的 `ViewUtils`
    必需）、移除 `androidx.window.extensions` / `sidecar` 的 uses-library
    （首调仍是 ~400ms）。也试过影子类 / 反射 / Unsafe 清空
    `WindowInfoTracker` 的 extension backend：能碰到这段耗时，但要 shadow
    Flutter 依赖的 AndroidX API，Flutter / AndroidX 一升级就会坏，**不采用**。
    按官方建议只后移非首帧初始化；真机上这段等待通常小得多，需以真机采样为准。
65. **托盘恢复的白闪是窗口原生底色，不是休眠占位色**：关闭到托盘前会先渲染一帧
    休眠占位再 `hide()`；恢复时 `WindowChrome.show()` 若先映射窗口，Windows 的
    `ShowWindow` / GTK 会先把上一张表面或原生白底显示出来，而
    `TrayDormantGate` 的重建要等下一帧——表现就是白闪一下再出现界面。隐藏期
    Flutter 帧是停的，**不能**在 `show()` 前 `await endOfFrame`（会等到超时）。
    现在的做法：Windows runner 收到 `showAfterFirstFrame` 后先
    `DwmSetWindowAttribute(DWMWA_CLOAK)` 再 `ShowWindow(SW_SHOW)`，首帧光栅化
    回调里 uncloak（300ms 定时器兜底）；Linux 用 `setOpacity(0)` → show → 等两帧
    → `setOpacity(1)`。启动首帧路径窗口已由 runner 显示，不再 cloak / 透明。
    Windows 的 cloak 必须由窗口所属进程调用：跨进程
    `DwmSetWindowAttribute` 会返回 `E_ACCESSDENIED`。改 `show()` 顺序前先看
    `lib/services/window/window_chrome_io.dart` 与
    `windows/runner/flutter_window.cpp`。
    **启动首帧绝不能走这条**：Windows runner 在 `OnCreate` 已经挂了 next-frame
    `Show`；Dart 首帧回调再调 `showAfterFirstFrame` 会覆盖它，beta.15 实测首帧后
    崩在 ucrtbase 0xc0000409。现在只有 `AppPresence.isTrayHidden`（真正的托盘恢复）
    才走 cloak / 透明度；启动 reveal 继续用 `windowManager.show()`。
66. **局域网同步已硬断代：旧包静默、旧状态不读、旧文件是幽灵**：
    内部迭代期显式不兼容历史数据，四层命名空间一起切开——状态
    `sync_state_v2` / 身份 `sync_device_id_v2` / 口令 `sync_passphrase_v2` /
    WebDAV 密码 `sync_webdav_password_v2`，配对码 `molia-pair:2:`，局域网 HTTP
    `/molia-sync/v2/*`，WebDAV 文件名 `<deviceId>.p2.*.msync`。旧 key 不读、
    不删、不迁移：新 key 缺失就按全新安装处理（新设备 id / 新口令 / 传输开关
    为空），升级后必须重新开启同步并重新配对。首次用新 key 初始化会清空
    派生状态 `sync_journal` / `sync_journal_state` / `sync_known`，只有两者都
    reset 成功才写 `sync_derived_reset_v2`（中途被杀下次重试）；**用户数据表
    与墓碑不动**，所以歌单 / 历史 / 统计不丢，但各对端首轮只能收全量
    bootstrap。旧 JSON 探测包（首字节 `{`）与旧 HTTP 路径分别被 `Msd1.decode`
    静默丢弃、返回 404；旧配对码解析失败；旧 WebDAV 文件不被
    `PeerJournalNames.parse` 识别，**不列出、不读取、也不被 `deleteRemote`
    删除**（云端会一直留着）。不要为了「兼容」补迁移 / 双协议分支：混版本
    本来就不互相发现，补一条旧路径反而会把旧数据重新放进新协议的语义里。
    回归：`test/sync_state_store_test.dart`、`test/sync_pairing_code_test.dart`、
    `test/lan_sync_transport_test.dart` 的旧码 / 旧路径 / 旧状态用例。
67. **`MSD/1` 发现认证有固定顺序：先来源限流 → 验 MAC → 再解析 JSON**：
    `LanDiscovery._onDatagram` 的顺序是安全边界，不能为了「先看看包内容」调换：
    ① 先按来源 IP 记限流（每来源 20 包/10s、全局 100 包/10s，来源记账表上限
    64、淘汰最久未活动）；② 再用 discovery key 验截断 HMAC（头部去掉 mac 后
    连同 bodyLen 与 body 一起认证）；③ 通过后才 `jsonDecode` 并检查
    deviceId / nonce / boot / 端口。未通过 MAC 的字节是**未知字节**，不是错误：
    直接丢，不计数、不写 warning（逐包打日志会在公共网络里被扫描流量刷爆，
    也会把「有人乱发 UDP」误报成同步故障）；能力类失败（组播加入失败、端口
    降级）才记 warning。重复 `(deviceId, nonce)` 30 秒内只产生一次 sighting，
    自身 deviceId、`httpPort <= 0`、非法 body 同样静默丢弃。排查时在发现层看
    sighting / presence 计数，不要打开逐包日志。
68. **挂起恢复 / 换网会静默回收 UDP 与 HTTP socket，必须重绑并探活**：
    移动端挂起、Wi-Fi 重连、DHCP 续租都可能让旧 socket 变成「还在绑定但收发
    已死」；换网时 IP 甚至可能不变，**不能以「地址没变」为前提跳过重绑**。
    现在的契约：回前台隐藏 ≥15s 时 `LanSyncTransport.onAppResumed()` 先用
    loopback TCP connect 探活 HTTP（500ms），失败重绑同一端口，再失败退随机
    端口并持久化；仍失败就把传输置为未运行 + `start_failed`（只留 `_running
    = true` 会让 `unavailableReason` 为空，UI 看不到故障），然后重绑 UDP 并发
    公告 burst；隐藏不足 15s 只刷新地址 / 公告。connectivity 事件走
    `LanDiscovery.onNetworkChanged()`，**无条件重绑 UDP**；只有接口指纹变化时
    才清 presence / nonce（旧端点仍可先试）。`discover()` 每 60s 节流重扫本机
    接口，指纹变化时在发包前重绑；`stop()` 清空进程内发现状态。
    验证方式：挂起 / 恢复、Wi-Fi ⇄ 蜂窝切换后看同步日志与
    `lanDiscoveryPorts`，不要只看「开关还开着」。
69. **`lanEndpoints` 只收「MAC + HTTP 解密都成功」的端点**：
    `SyncStateStore.rememberLanEndpoint` 的写入条件是发现报文 MAC 验证通过
    **且** 对端 HTTP 载荷能用本机口令解密成功（`onPeerVerified`）；只听见 UDP
    公告、HTTP 连不上或口令不同的对端一律不写。端点的 deviceId 以**解密载荷**
    为准：DHCP 复用 / 旧记录可能让候选端点的 id 与数据主人不同，写回旧 id 会
    让下一轮继续找错设备。表项要求 `verifiedAt > 0`（否则永远命中不了淘汰），
    上限 32 条（超出按 `verifiedAt` 淘汰最旧），180 天未再验证随名册淘汰，
    `removePeer` 同时清理该设备的条目。只有端点身份（host / httpPort /
    probePort）变化或首次出现才立即落盘；仅验证时间前进只改内存，随轮末
    `save()` 持久化（否则多对端一轮会反复写大 JSON）。对端分两类：手动地址与
    **本轮听到的** presence 是「预期对端」，失败要计数、可把整轮打成
    `partial`；只有持久化端点的是「试探性对端」，连不上是常态，失败不计数。
    不要把「公告里自报的地址」直接当已验证端点，也不要把试探性失败算进
    失败对端数。
70. **多网卡 / VPN 下广播只走默认路由，零应答不等于对端离线**：
    `LanDiscovery` 只有 v4 / v6 两个 wildcard `RawDatagramSocket`，没有按
    接口绑定，也没有固定 `multicastInterface`——广播 / 组播从哪块网卡出去由
    系统路由表决定。多网卡（以太网 + Wi-Fi）、全隧道 VPN、WSL / 虚拟网卡
    场景下，默认路由可能指向 VPN 或一块与对端不通的接口：本机地址列表里
    有 `192.168.x`，广播却从 VPN 发出，表现为「两边都在线、广播零应答」。
    **不能用 `255.255.255.255` 推断所有接口都收到了**，也不要因为广播 /
    组播零应答就判定对端离线。排查顺序：
    ① 先看已同步设备的 `lanEndpoints` 单播是否成功（HTTP 拉取 / 解密成功
    才算接触），再看配对码 / 手动地址能否直连；
    ② 用 `LocalEndpointsService` 的 `ifname|address` 指纹确认换网检测到的
    是预期接口，看同步日志与 `lanDiscoveryPorts`；
    ③ 再查 VPN 是否全隧道、接口 metric / 绑定顺序、防火墙是否只放行默认
    接口。配对码里的地址候选与探测端口是当前最可靠的跨接口入口。
    另：UDP 端口降级到系统分配端口后，发往固定 47825 的广播同样到不了它
    （见 #46），此时只能靠配对码 / 手动地址 / 已有端点单播；不要把这当成
    「发现协议坏了」。若将来要真正按接口发现，需要为每个接口绑定 socket
    或切换 `multicastInterface`，并处理接口上下线。
71. **移动端息屏 / 后台不要写 `AppPresence` 来省电**：`AppPresence` 是桌面
    窗口可见性的事实源，`PlaybackObserver` / `ImagePreloadManager` /
    `ArtworkThemeSync` 据此停产封面预取、下一首歌词预取与取色。移动端退后台
    **仍要保留**这些工作（桌面歌词悬浮窗的歌词 / 颜色 / 下一首体验靠它们），
    后台节拍由 `PlaybackPowerPolicy`（位置采样 / 会话落盘 / 媒体会话更新）
    单独承担。两者混用会静默停掉预取与取色，表现为息屏后桌面歌词「歌词不
    换行、颜色不跟封面」，且 `AppPresence` 的托盘语义还会被移动端生命周期
    污染。
