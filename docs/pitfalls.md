# 已知坑（改代码前务必阅读）

本清单收录本仓库实际踩过、且只读代码不易发现的坑。

> **编号被源码注释直接引用**（如 `ic_notification.xml` / `molia_mark.dart` 中的「见已知坑 18/19」），
> 请勿重排；新增条目追加在末尾。

1. **flutter_js 在 Linux 的 QuickJS 桥接库不会自动打包**（上游 CMake 变量名错误）。
   已在 `linux/CMakeLists.txt` 显式 `install(FILES ... libquickjs_c_bridge_plugin.so)`，不要删除。
2. **`getJavascriptRuntime()` 必须传 `xhr: false`**。默认开启的 fetch 会在后台 isolate 调用
   `rootBundle`（依赖平台通道），产生未处理异常并**终止 isolate**，表现为引擎初始化成功但所有请求超时。
3. **`material_color_utilities` 被 Flutter SDK 固定为 0.13.0**，不要升级为 0.13.1（版本求解会失败）。
4. **`encrypt` 已移除**：pointycastle 4.x 与其冲突；AES/RSA 统一走 `lx_native_utils.dart`。
5. **maven.google.com 在部分网络不可达**：`android/app/build.gradle` 仓库显式使用
   `https://dl.google.com/dl/android/maven2`，不要改回 `maven.google.com`。
6. **share_plus 13**：使用 `SharePlus.instance.share(ShareParams(files: ..., text: ...))`，
   `Share.shareXFiles` 已不存在。
7. **Web 不支持音源**：`kIsWeb` 时 `SourceManager` 不激活引擎；不要移除条件导入
   （`lx_engine.dart` / `desktop_audio_init.dart` / `database_factory_init.dart` 的 stub 分支）。
8. **音源脚本是不可信代码**：不要在引擎里暴露文件系统/平台通道；网络只走 `lx.request` 桥。
   `currentScriptInfo` 必须原样透传（部分脚本有防篡改校验，校验失败会死循环）。
9. **ELECTRON 脚本兼容性**：脚本可能使用 `atob/btoa/TextEncoder/setTimeout/window/navigator`
   等 shim；扩展能力请加在 `lx_prelude.js` 而不是假设宿主提供。
10. **插件 JVM target 校验**：`flutter_js` 等插件 Java target(11) 与 Kotlin target(1.8) 不一致，
    AGP 9 默认按错误处理；已在 `android/gradle.properties` 设置
    `kotlin.jvm.target.validation.mode=warning`，不要删除。
11. **集成测试挂起保护（仅桌面）**：桌面端 media_kit（libmpv）的原生事件循环会阻止测试进程
    退出；`integration_test/lx_engine_integration_test.dart` 的 `tearDownAll` 有 2s 上报窗口后
    `exit(0)` 的看门狗（只在 Linux/Windows 注册），不要删除、也不要推广到 Android——Android
    走官方 teardown（stopApp/uninstall）能干净退出，注册看门狗反而会抢在卸载/回收之前退出进程。
    Android 若遇跑完不退出，是上游 adb teardown 无超时（flutter/flutter#187785 / #187984，
    3.47.6 已修 DDS 路径），先看 `tool/agent/test.sh` 的日志尾部再判断。
    另：无显示环境跑 Linux 集成测试必须套 `xvfb-run`（脚本自动处理），否则报
    「Error waiting for a debug connection」。
12. **不内置字体资产**：界面与海报统一使用设备字体，用户可在设置中切换「应用字体」
    （枚举实现见 `lib/services/system_fonts_service*.dart`：Android 解析系统
    `fonts.xml`、iOS 走 `UIFont.familyNames` 通道、Linux 调 `fc-list`），海报页可
    独立覆盖（`PosterFontStore`）。不要再向 `pubspec.yaml` 的 `fonts:` 或
    `assets/fonts/` 添加字体，保持包体精简。
13. **发布体积**：新增资产前先评估体积；不要内置 CJK 字体（系统字体 + 用户安装）。
    Android 启动图标自 2026-10 起为手绘矢量（`drawable/ic_launcher_foreground.xml`，
    维护方式见 `flutter_launcher_icons.yaml` 头注释），该工具现在只生成 iOS 图标；
    `minSdk=37` 下传统 mipmap 密度图无意义，已全部移除，不要用工具再生成。
14. **省流模式的网络检测**：Android 8+ 后台不广播网络变化，`_MyThemedAppState` 在
    `resumed` 时调 `DataSaverService.refreshConnectivity()`，不要删除；Web 的
    connectivity_plus 拿不到「蜂窝」类型（只会返回 wifi/none），省流在 Web 不会自动生效；
    检测失败时保守按「未生效」处理（`detectionAvailable=false`）。
15. **`--no-pub` 会跳过插件注册文件再生成**：`flutter build ... --no-pub` 不重写
    `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`。
    若该文件缺失，构建**不会报错**但产物没有插件注册（R8 会把插件类全部裁掉，
    表现为通知/播放/数据库全失效）；若文件来自 debug/集成测试还会残留
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
