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
13. **发布体积**：新增资产前先评估体积；不要内置 CJK 字体（系统字体 + 用户安装）。
    Android 启动图标自 2026-10 起为手绘矢量（`drawable/ic_launcher_foreground.xml`，
    维护方式见 `icons_launcher.yaml` 头注释），该工具现在只生成 iOS 与 Windows 图标
    （Windows 的 `app_icon.ico` 同时是 exe/任务栏/安装器/快捷方式图标，不要手改）；
    `minSdk=37` 下传统 mipmap 密度图无意义，已全部移除，不要用工具再生成。
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
43. **桌面歌词滚动组的 `translationX` 符号**：滚动组（当前行 + 翻译 / 罗马音）强制
    `Gravity.START`，对齐与横滚都在 `applyGroupScroll` 里用位移实现——`translationX`
    正 = 内容右移，与 `scrollX`（正 = 内容左移）相反。符号写反时：居中 / 右对齐把整行
    推到屏幕左外（首字被裁，短句如「我接着写」4 字会整句消失），长行滚动方向也反过来
    （越唱越往右、行尾永远露不出来）。未超宽时对齐取正位移、超宽后由 0 递减到 −溢出，
    两者共用 `x = alignedShift - scroll`；改动前先读 `docs/lyrics_display.md` §4 FR-3
    的符号约定。
44. **悬浮窗位置要按「可用区」算，不能用 `resources.displayMetrics`**：
    `TYPE_APPLICATION_OVERLAY` 默认按 system bars / 刘海 insets 收边（fitTypes），
    `LayoutParams.x/y` 是安全区左上角起的偏移；edge-to-edge Activity 的
    `displayMetrics`（≈整屏，模拟器实测 2400 vs 悬浮窗实际可用 2274 + 63px 偏移）
    把状态栏高度算进可用空间，贴底摆放时被导航栏裁掉。可用区取
    `WindowManager.currentWindowMetrics` 减 `systemBars | displayCutout` insets，
    位置相关的四件事都收在 `LyricsOverlayController`，别拆开：
    ① 比例写读同一套公式（历史上写 `y/(H−h)`、读 `H*yf`，每次重建窗口整体下移 ~7%，
    拖到底部后直接落到屏幕外）；② 纵向用**底缘**比例（窗口高度要等首次布局才有，
    底缘换算不需要高度），高度变化时底缘固定、向上生长；
    ③ 内容高度 / 可用区变化（行数、控制条弹出、旋转 / 字号）后按比例重新落位并夹取；
    ④ 旧键 `y_fraction` 语义与底缘比例不同，改名 `bottom_fraction` 让旧值自然失效
    （不迁移：旧值按老公式写，直接读会错得更偏）；
    ⑤ 布局回调也会被「纯移动」触发：只认尺寸真的变了（`maybeAnchorIntoArea`），
    且拖动中一律不落位（`isDragging`）——否则每帧 `updateViewLayout` 后立刻被比例
    拽回原位，表现为「悬浮窗拖不动」。
45. **一次 Esc 会被多个作用域同时消费，`HardwareKeyboard` 的返回值裁决不了**：
    它的处理器**全部执行、返回值不短路**（SDK 原文：All registered handlers will be
    invoked in order regardless of their return value），壳层可配置快捷键（默认
    Esc = 关队列面板）与页面级 / 弹层处理器（收藏页多选、音量弹层）会同时
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
