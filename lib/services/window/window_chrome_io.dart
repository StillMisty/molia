import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:nativeapi/nativeapi.dart'
    show
        Application,
        TitleBarStyle,
        Window,
        WindowCloseRequestedEvent,
        WindowEvent,
        WindowManager,
        WindowMaximizedEvent,
        WindowMinimizedEvent,
        WindowMovedEvent,
        WindowResizedEvent,
        WindowRestoredEvent;
import 'package:nativeapi_flutter/nativeapi_flutter.dart'
    show RectToNative, RectangleToRect, SizeToNative;

import '../app_presence.dart';
import 'display_areas_io.dart';
import 'single_instance.dart';
import 'window_bounds.dart';
import 'window_bounds_store.dart';
import 'window_settings.dart';

/// 桌面（Linux / Windows / macOS）：nativeapi 窗口实现。
///
/// 原生 API 只在 [isSupported] 为真时调用：其余平台（Android / iOS）没有桌面
/// 窗口，[WindowChrome] 的初始化与窗口监听都是空操作。
///
/// 标题栏口径按平台分开：Linux / Windows 隐藏原生标题栏、由 UI 自画窗口按钮
/// （[usesCustomTitleBar]）；macOS 保留原生标题栏与红绿灯（系统习惯），窗口
/// chrome 只负责几何记忆 / 隐藏 / 恢复 / 退出。
class WindowChrome {
  WindowChrome._();

  static bool get isSupported =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// 是否由 UI 自画标题栏与窗口按钮（Linux / Windows）。
  ///
  /// macOS 走原生标题栏：`WindowControls` 只在 [usesCustomTitleBar] 为真时
  /// 挂载，避免与系统红绿灯重复。
  static bool get usesCustomTitleBar => Platform.isLinux || Platform.isWindows;

  static final Logger _logger = Logger('molia.window_chrome');

  static final ValueNotifier<bool> _maximized = ValueNotifier<bool>(false);

  /// 当前主窗口的原生句柄；[ensureInitialized] 解析后一直复用。
  static Window? _window;

  /// 是否拦截原生关闭请求（窗口关闭键 / 系统关闭按钮）。
  static bool _preventClose = false;

  /// 正在执行 [quit]：跳过关闭回调，避免 `close()` 递归。
  static bool _destroying = false;

  /// 原生状态镜像：nativeapi 用同一个 [WindowRestoredEvent] 表示「退出最大化」
  /// 和「从最小化恢复」，需要知道事件前处于哪种状态。
  static bool _windowMaximized = false;
  static bool _windowMinimized = false;

  /// 窗口几何持久化（设备本地键，键名只出现在 store 文件里）。
  static final WindowBoundsStore _boundsStore = WindowBoundsStore();

  /// 拖动/缩放落定后的落盘防抖：拖动过程中几何每帧都在变，实时落盘没有意义。
  static const Duration _boundsSaveDebounce = Duration(milliseconds: 600);

  static Timer? _boundsSaveTimer;

  /// 启动恢复：显示后是否补 `maximize()`（见 [_restoreSavedGeometry]）。
  static bool _restoreMaximized = false;

  /// 关闭请求策略（顶栏关闭键 / 系统关闭按钮）：由组合根注入
  /// （最小化到托盘 / 真正退出）。未注入时保持历史行为——直接退出。
  static FutureOr<void> Function()? _onCloseRequested;

  /// 当前窗口是否最大化：窗口按钮用它切换「最大化 / 还原」图标。
  static ValueListenable<bool> get maximized => _maximized;

  /// 注入关闭策略（组合根调用一次）。
  static void setCloseHandler(FutureOr<void> Function() handler) {
    _onCloseRequested = handler;
  }

  /// 初始化窗口（Linux / Windows 隐藏原生标题栏；macOS 保留原生标题栏）
  /// 并恢复几何。
  ///
  /// 窗口由原生 runner 在 Dart 启动前创建，这里直接取当前窗口设置属性。
  /// Linux / Windows 在首帧回调前不显示，首帧后再由 [show] 亮出来；macOS 的
  /// 窗口随 NIB 显示（隐藏窗口会停帧），[show] 在那里是幂等的重复调用。
  ///
  /// Linux / Windows 的 `TitleBarStyle.hidden` 之后系统标题栏与系统按钮都不
  /// 复存在，窗口拖动全靠 UI 侧的 [WindowDragArea]，不要在别处再隐藏标题栏。
  /// macOS 走 `normal`：红绿灯与标题由系统绘制，UI 只保留拖动区（不显示
  /// [usesCustomTitleBar] 的三键）。
  ///
  /// 关闭请求不再交给插件的 preventClose：监听
  /// [WindowCloseRequestedEvent] 并 cancel，由注入的策略决定「隐藏到托盘」
  /// 还是「退出」。真正退出走 [quit]（先解除拦截再 close）。
  ///
  /// **为什么显示推迟到首帧**：runApp 之前要装完整套子系统（数据库 / 播放 /
  /// 主题预解析，几百 ms 起），先显示窗口会让用户盯着一块空白窗等待
  /// （用户反馈的「启动迟缓」主要来自这段观感）；先建窗不显示、首帧回调里
  /// 再 [show]，窗口出现时内容已经画好。组合根同时挂一个超时兜底，
  /// 启动异常时窗口也一定会出现。
  static Future<void> ensureInitialized() async {
    if (!isSupported) return;
    final window = _resolveWindow();
    if (window == null) {
      _logger.warning('桌面窗口尚未就绪，跳过窗口初始化');
      return;
    }
    _window = window;
    try {
      // 与 0.5.x 的 waitUntilReadyToShow 对齐：先把窗口从全屏 / 最大化 /
      // 最小化态拉回普通态，再套用本次启动的尺寸与几何。
      if (window.isFullScreen) window.isFullScreen = false;
      if (window.isMaximized) window.unmaximize();
      if (window.isMinimized) window.restore();
      _windowMaximized = false;
      _windowMinimized = false;
      _maximized.value = false;
      window.titleBarStyle = usesCustomTitleBar
          ? TitleBarStyle.hidden
          : TitleBarStyle.normal;
      // 最小尺寸与桌面骨架的折叠阈值配套：再窄时侧栏 + 播放器列 + 队列
      // 面板会把内容区挤成破版式，直接在原生层拦住（初始 1280×800 见
      // 原生 runner 默认值）。
      window.minimumSize = kMinimumWindowSize.toNative();
      // 先打开关闭拦截再挂监听：nativeapi 只有在窗口有监听者时才会投递
      // WindowCloseRequestedEvent。
      _preventClose = true;
      window.addListener(_onWindowEvent);
    } catch (error) {
      // 窗口初始化失败不阻断启动：runner 仍会显示默认窗口。
      _logger.warning('窗口初始化失败：$error');
    }
    if (Platform.isMacOS) _installReopenHandler();
    // 显示前先摆好位置：show() 后再设置 bounds 会肉眼可见地跳一下。
    await _restoreSavedGeometry();
    await _applyLinuxWindowIcon();
  }

  /// 取 runner 创建的主窗口：正常情况下 `getCurrent()` 直接命中；极端情况下
  /// 退回应用主窗口。两者都没有时返回 null，由调用方降级。
  static Window? _resolveWindow() {
    try {
      return WindowManager.instance.getCurrent() ??
          Application.instance.getPrimaryWindow();
    } catch (error) {
      _logger.warning('读取桌面窗口失败：$error');
      return null;
    }
  }

  /// 恢复上次关闭时的窗口几何与最大化状态。
  ///
  /// 开关关闭时什么都不恢复。几何与最大化**分开读**：最大化期间不写几何
  /// （`bounds` 在最大化态返回最大化矩形，存进去会丢还原尺寸），所以
  /// 「首启就最大化 → 退出」这种会话只有标记可读，不能因为几何缺失就跳过
  /// 最大化恢复。
  ///
  /// 没有保存几何 / 拿不到显示器列表时保持系统默认位置：拿不到显示器就
  /// 无从校验，宁可用默认位置也不赌保存值可见。
  static Future<void> _restoreSavedGeometry() async {
    _restoreMaximized = false;
    if (!WindowSettings.rememberBounds) return;
    try {
      _restoreMaximized = await _boundsStore.loadMaximized();
      final saved = await _boundsStore.load();
      if (saved == null) return;
      final window = _window;
      if (window == null) return;
      final areas = DesktopDisplayAreas.read();
      if (areas == null) return;
      window.bounds = resolveRestoredBounds(
        saved: saved.bounds,
        displayVisibleAreas: areas.visibleAreas,
        primaryVisibleArea: areas.primary,
      ).toNative();
    } catch (error) {
      // 恢复失败不阻断启动：窗口按系统默认位置显示。
      _logger.warning('窗口几何恢复失败：$error');
    }
  }

  /// 拖动 / 缩放落定后延迟落盘；重复事件重置计时（防抖）。
  static void _scheduleBoundsSave() {
    if (!isSupported || !WindowSettings.rememberBounds) return;
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = Timer(_boundsSaveDebounce, () {
      _boundsSaveTimer = null;
      unawaited(_saveBoundsNow());
    });
  }

  static Future<void> _saveBoundsNow() async {
    try {
      final window = _window;
      if (window == null) return;
      // 最大化态不覆盖 bounds（bounds 返回最大化矩形，存了会丢还原尺寸）；
      // 最大化标记由 maximize 事件即时保存。
      if (window.isMaximized) return;
      await _boundsStore.saveBounds(window.bounds.toRect());
    } catch (error) {
      _logger.warning('窗口几何保存失败：$error');
    }
  }

  /// 最大化 ⇄ 还原标记：即时落盘（不防抖），并取消在途的几何保存，
  /// 避免把最大化过程中的矩形写进 bounds。
  static void _persistMaximized(bool maximized) {
    if (!isSupported || !WindowSettings.rememberBounds) return;
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = null;
    unawaited(_saveMaximizedNow(maximized));
  }

  static Future<void> _saveMaximizedNow(bool maximized) async {
    try {
      await _boundsStore.saveMaximized(maximized);
    } catch (error) {
      _logger.warning('窗口最大化状态保存失败：$error');
    }
  }

  /// Linux 运行期窗口图标（X11 的 WM_HINTS；Wayland 没有窗口图标协议，
  /// dock 图标靠随包安装的 .desktop，见 `linux/packaging/README.md`）。
  ///
  /// nativeapi 的 `Application.setIcon` 需要 bundle 内绝对路径：发布包与调试
  /// bundle 都把资产放在 `<exe>/data/flutter_assets/`。
  static Future<void> _applyLinuxWindowIcon() async {
    if (!Platform.isLinux) return;
    try {
      final executableDirectory = File(Platform.resolvedExecutable).parent.path;
      final assetPath = [
        executableDirectory,
        'data',
        'flutter_assets',
        'assets/icons/app_icon.png',
      ].join(Platform.pathSeparator);
      Application.instance.setIcon(assetPath);
    } catch (_) {
      // 图标失败不影响窗口本身：忽略（Wayland / 资产缺失时不致命）。
    }
  }

  static Future<void> minimize() async {
    if (!isSupported) return;
    _window?.minimize();
  }

  /// 最大化 ⇄ 还原：以原生 `isMaximized` 为准，不读 [maximized] 缓存
  /// （窗口管理器的手势/快捷键也能改变状态，缓存可能滞后一帧）。
  static Future<void> toggleMaximize() async {
    if (!isSupported) return;
    final window = _window;
    if (window == null) return;
    if (window.isMaximized) {
      window.unmaximize();
    } else {
      window.maximize();
    }
  }

  /// 发起关闭请求（顶栏关闭键）：与系统关闭按钮同一条路径，
  /// 由注入的关闭策略决定实际行为（隐藏到托盘 / 退出）。
  static Future<void> close() async {
    if (!isSupported) return;
    _window?.close();
  }

  /// 隐藏窗口（「关闭时最小化到托盘」）：进程与播放继续，任务栏/Tab 列表里
  /// 不再出现窗口；从托盘「显示主窗口」或单击图标恢复。
  ///
  /// 置「托盘隐藏」存在态在原生调用**之前**：组合根在隐藏前还要抢一帧把
  /// 界面卸下来（帧只在窗口可见时开），先置位才能保证那一帧建的是休眠树。
  static Future<void> hide() async {
    if (!isSupported) return;
    AppPresence.instance.markTrayHidden();
    _window?.hide();
  }

  /// 设置窗口标题（任务栏 / 窗口列表 / Alt-Tab 显示）。
  ///
  /// Linux / Windows 隐藏原生标题栏后 UI 里看不到标题，但系统仍以它标识
  /// 窗口：显示当前曲目让用户在任务栏一眼认出「哪个窗口在放什么」。macOS
  /// 的原生标题栏同样跟随这个值。非桌面平台空操作。
  static Future<void> setTitle(String title) async {
    if (!isSupported || title.isEmpty) return;
    try {
      _window?.title = title;
    } catch (error) {
      // 标题只是锦上添花：失败不影响任何功能。
      _logger.fine('设置窗口标题失败：$error');
    }
  }

  /// 显示并聚焦窗口（首帧后 reveal / 托盘「显示主窗口」/ 单实例请求）。
  ///
  /// 幂等：重复调用只是再次 show + focus；恢复的最大化状态在这里补一次
  /// （见 [_restoreSavedGeometry]——`bounds` 在最大化态返回最大化矩形，
  /// 所以几何与最大化分两步恢复）。
  ///
  /// **托盘恢复的白闪**：隐藏期间帧是停的，`AppPresence.markVisible()` 只把
  /// 休眠门标脏，重建要等下一帧；若先映射窗口，DWM / GTK 会先显示窗口的
  /// 空白底色（实测 Windows 是白色）。因此桌面端先让窗口「可见但不可见」：
  /// Windows 用 DWM cloak，Linux 用窗口透明度；等重建首帧落定后再显示 / 恢复
  /// 不透明。启动首帧路径窗口已经由 runner 显示，不走这条。
  static const MethodChannel _windowChannel = MethodChannel(
    'top.stillmisty.molia/window',
  );

  /// 是否已接管 macOS 的 Dock「重新打开」回调（进程内只需一次）。
  static bool _reopenHandlerInstalled = false;

  /// macOS：Dock 图标点击时 AppKit 只负责把应用带到前台；窗口在托盘休眠态
  /// 下是 `orderOut` 的，直接显示会是一扇停在休眠占位的空窗。原生
  /// `AppDelegate.applicationShouldHandleReopen` 经这条通道回到 Dart，统一走
  /// [show]（markVisible + 重建界面 + 恢复最大化）。
  ///
  /// 与 Windows 的 Dart → 原生 `showAfterFirstFrame` 共用通道名，但方向相反
  /// （这是原生 → Dart），互不冲突。
  static void _installReopenHandler() {
    if (_reopenHandlerInstalled) return;
    _reopenHandlerInstalled = true;
    _windowChannel.setMethodCallHandler((call) async {
      if (call.method != 'reopen') return null;
      try {
        await show();
      } catch (error) {
        // 恢复失败不影响进程：用户还能从菜单栏托盘再次恢复。
        _logger.warning('Dock 恢复窗口失败：$error');
      }
      return null;
    });
  }

  static Future<void> show() async {
    if (!isSupported) return;
    final window = _window;
    if (window == null) return;
    // 只有「关闭到托盘后的恢复」才走首帧后显示。启动首帧时 runner 已经挂了
    // 自己的 next-frame callback（Show），这里再设一次会覆盖它——Windows 上
    // 实测会在首帧后崩（ucrtbase 0xc0000409）。
    final fromTray = AppPresence.instance.isTrayHidden;
    AppPresence.instance.markVisible();
    // Dock 点击恢复时窗口可能在最小化态：先还原再显示（macOS 的
    // `makeKeyAndOrderFront` 不会自动把窗口从 Dock 里拉回来）。
    if (window.isMinimized) window.restore();
    if (fromTray && Platform.isWindows) {
      await _showWindowsAfterFirstFrame();
    } else if (fromTray && Platform.isLinux) {
      await _showLinuxWithOpacity();
    } else {
      window.show();
    }
    window.focus();
    if (_restoreMaximized) {
      _restoreMaximized = false;
      window.maximize();
    }
  }

  static void _showWindow() {
    _window?.show();
  }

  /// Windows：原生侧 cloak → ShowWindow → 首帧回调 uncloak。
  ///
  /// cloak 期间窗口已映射、引擎正常出帧，但 DWM 不绘制；重建首帧光栅化后
  /// 再解除，用户第一次看到的就是新界面。原生异常时退回普通 show。
  static Future<void> _showWindowsAfterFirstFrame() async {
    try {
      await _windowChannel
          .invokeMethod<void>('showAfterFirstFrame')
          .timeout(const Duration(milliseconds: 800));
    } on MissingPluginException {
      _showWindow();
    } on PlatformException {
      _showWindow();
    } on TimeoutException {
      _showWindow();
    }
  }

  /// Linux：GTK 没有 DWM cloak，用窗口透明度覆盖「映射到首帧」之间。
  ///
  /// 隐藏期帧停，`show()` 之后才会重新出帧；等两帧落定再恢复不透明。
  /// 合成器不支持透明度时保持原行为（直接可见），不阻塞恢复。
  static Future<void> _showLinuxWithOpacity() async {
    final window = _window;
    if (window == null) return;
    var opacitySet = false;
    try {
      window.opacity = 0;
      opacitySet = true;
    } catch (_) {
      // 平台 / 合成器不支持：按原路径直接显示。
    }
    try {
      window.show();
      if (opacitySet) {
        await _waitFrame();
        await _waitFrame();
      }
    } finally {
      if (opacitySet) {
        try {
          window.opacity = 1;
        } catch (_) {
          // 恢复失败不影响窗口可用性；下一轮 show 会再设置。
        }
      }
    }
  }

  static Future<void> _waitFrame() => WidgetsBinding.instance.endOfFrame
      .timeout(const Duration(milliseconds: 500), onTimeout: () {});

  /// 无视关闭策略真正退出（托盘「退出」/ 更新安装后的重启替换）：
  /// 先释放单实例锁、解除关闭拦截，再关闭窗口；退出前的落盘由调用方负责。
  static Future<void> quit() async {
    if (!isSupported) return;
    // 正常退出路径顺带释放锁：下次启动能直接抢到（强杀残留由陈旧锁清理兜底）。
    await SingleInstance.release();
    _destroying = true;
    _preventClose = false;
    final window = _window;
    if (window != null && Window.isCloseSupported() && window.close()) {
      return;
    }
    // 原生 close 不可用 / 被拒绝时退回应用级退出。
    try {
      Application.instance.quit(0);
    } catch (error) {
      _logger.warning('退出应用失败：$error');
    }
  }

  /// 原生窗口事件 → 最大化标记 / 几何落盘 / 关闭策略。
  ///
  /// nativeapi 用同一个 [WindowRestoredEvent] 表示「退出最大化」和「从最小化
  /// 恢复」，只能靠事件前的状态区分（与 0.5.x 兼容层同一口径）。
  static void _onWindowEvent(WindowEvent event) {
    switch (event) {
      case WindowCloseRequestedEvent():
        // 先同步 cancel，再交给异步策略：事件返回后 nativeapi 才会决定
        // 是否真正关闭窗口。
        if (_preventClose) event.request.cancel();
        if (_destroying) return;
        final handler = _onCloseRequested;
        if (handler == null) {
          unawaited(quit());
        } else {
          unawaited(Future.sync(handler));
        }
      case WindowMaximizedEvent():
        _windowMaximized = true;
        _maximized.value = true;
        // 最大化时 bounds 是最大化矩形：只记标记，不覆盖还原尺寸。
        _persistMaximized(true);
      case WindowRestoredEvent():
        if (_windowMinimized) {
          _windowMinimized = false;
          // 从最小化恢复不代表退出最大化（最大化的窗口最小化后再恢复仍是
          // 最大化），因此重新查询真实状态而不是直接置 false。
          AppPresence.instance.markVisible();
          final maximized = _window?.isMaximized ?? false;
          _windowMaximized = maximized;
          _maximized.value = maximized;
          return;
        }
        if (!_windowMaximized) return;
        _windowMaximized = false;
        _maximized.value = false;
        _persistMaximized(false);
        // 还原几何在事件后已生效，按正常保存路径重新记一次。
        _scheduleBoundsSave();
      case WindowMinimizedEvent():
        _windowMinimized = true;
        // 最小化只置「最小化」态：界面状态保留（内存守卫只停后台解码类工作，
        // 不清缓存，保证最小化↔恢复跟手）。
        //
        // 已是托盘隐藏时不降级：个别平台在原生隐藏时也会补一个最小化事件，
        // 若覆盖成「最小化」，托盘休眠与缓存清理就会被跳过。
        if (!AppPresence.instance.isVisible) return;
        AppPresence.instance.markMinimized();
      case WindowMovedEvent():
      case WindowResizedEvent():
        _scheduleBoundsSave();
      default:
        break;
    }
  }

  /// 窗口当前是否可见（仅诊断/测试用）。
  @visibleForTesting
  static Future<bool> isVisible() async {
    if (!isSupported) return false;
    return _window?.isVisible ?? false;
  }

  /// 原生标题栏高度（仅诊断/测试用）：隐藏标题栏后必须为 0。
  @visibleForTesting
  static Future<int> debugTitleBarHeight() async {
    if (!isSupported) return 0;
    final window = _window;
    if (window == null) return 0;
    final height = window.contentBounds.y - window.bounds.y;
    return height < 0 ? 0 : height.round();
  }
}

/// 窗口拖动区：隐藏标题栏后按住空白处拖动窗口。
///
/// 语义同 nativeapi_flutter 的 `DragToMoveArea`：pan 起始即交给原生
/// `startDragging()`（translucent 让顶栏的空白区域也能命中拖动，
/// 按钮/标题自身的点击手势不受影响——pan 与 tap 在手势竞技场按位移区分）。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => WindowChrome._window?.startDragging(),
      child: child,
    );
  }
}

/// 拖动区的双击区（拖动手感项：双击标题栏最大化 / 还原）。
///
/// **为什么不用 `GestureDetector(onDoubleTap:)`**：双击识别器要等第二个
/// 点击超时才让出竞技场，会把同一个区域里的单击一起拖到 300ms 后（实测
/// 子按钮的 onTap 在 doubleTap 存在时也会延迟）。这里用被动 [Listener]
/// 自己数点击：不参与手势竞技场，单击、拖动、按钮点击全部保持原时序；
/// 双击判定窗口内第二次「原地抬起」时触发 [onDoubleTap]。
///
/// 只挂在顶栏的非按钮区域（标题/封面条）：按钮区不参与，避免双击按钮
/// 顺带最大化窗口。
class WindowDoubleTapMaximize extends StatefulWidget {
  const WindowDoubleTapMaximize({
    super.key,
    required this.child,
    this.onDoubleTap,
  });

  final Widget child;

  /// 测试注入；缺省调用 [WindowChrome.toggleMaximize]。
  final VoidCallback? onDoubleTap;

  @override
  State<WindowDoubleTapMaximize> createState() =>
      _WindowDoubleTapMaximizeState();
}

class _WindowDoubleTapMaximizeState extends State<WindowDoubleTapMaximize> {
  /// 双击判定窗口（与 Flutter `kDoubleTapTimeout` 一致）。
  static const Duration _doubleTapWindow = Duration(milliseconds: 300);

  /// 允许的位移：超过视为拖动 / 滑动，不算点击。
  static const double _slop = 12;

  int? _downPointer;
  Offset? _downPosition;
  Duration? _lastTapAt;
  Offset? _lastTapPosition;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (PointerDownEvent event) {
        _downPointer = event.pointer;
        _downPosition = event.position;
      },
      onPointerUp: _onPointerUp,
      child: widget.child,
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _downPointer) return;
    final down = _downPosition;
    _downPointer = null;
    _downPosition = null;
    // 拖动 / 滑动（含窗口拖动）：不构成点击，并打断双击序列。
    if (down == null || (event.position - down).distance > _slop) {
      _lastTapAt = null;
      _lastTapPosition = null;
      return;
    }
    final lastAt = _lastTapAt;
    final lastPosition = _lastTapPosition;
    if (lastAt != null &&
        lastPosition != null &&
        event.timeStamp - lastAt <= _doubleTapWindow &&
        (event.position - lastPosition).distance <= _slop) {
      _lastTapAt = null;
      _lastTapPosition = null;
      final handler = widget.onDoubleTap;
      if (handler != null) {
        handler();
      } else {
        unawaited(WindowChrome.toggleMaximize());
      }
      return;
    }
    _lastTapAt = event.timeStamp;
    _lastTapPosition = event.position;
  }
}
