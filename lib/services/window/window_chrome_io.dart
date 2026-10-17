import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'single_instance.dart';
import 'window_bounds.dart';
import 'window_bounds_store.dart';
import 'window_settings.dart';

/// Linux / Windows 桌面：window_manager 实现。
///
/// 插件方法只在 [isSupported] 为真时调用：其余平台（Android / iOS / macOS）
/// 没有注册插件实现，触达插件 API 会撞 MissingPluginException。
class WindowChrome {
  WindowChrome._();

  static bool get isSupported => Platform.isLinux || Platform.isWindows;

  static final Logger _logger = Logger('molia.window_chrome');

  static final ValueNotifier<bool> _maximized = ValueNotifier<bool>(false);
  static final _MaximizedStateListener _listener = _MaximizedStateListener();

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

  /// 隐藏原生标题栏并在首帧前显示窗口；由 main 在 runApp 前调用一次。
  ///
  /// `titleBarStyle: hidden` 之后系统标题栏与系统按钮都不复存在，
  /// 窗口拖动全靠 UI 侧的 [WindowDragArea]，不要在别处再隐藏标题栏。
  ///
  /// 同时打开 `preventClose`：原生关闭不再销毁窗口，而是转到
  /// [WindowListener.onWindowClose]，由注入的策略决定「隐藏到托盘」还是
  /// 「退出」。真正退出走 [quit]（先解除拦截再销毁）。
  ///
  /// show / focus 显式 await（不放进 `waitUntilReadyToShow` 的 callback）：
  /// callback 是同步签名，内部的异步链会让「就绪即显示」晚于调用方后续操作
  /// （集成测试里表现为 hide() 后又被 show() 拉回），这里保证返回时窗口已显示。
  static Future<void> ensureInitialized() async {
    if (!isSupported) return;
    await windowManager.ensureInitialized();
    windowManager.addListener(_listener);
    await windowManager.setPreventClose(true);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        titleBarStyle: TitleBarStyle.hidden,
        // 最小尺寸与桌面骨架的折叠阈值配套：再窄时侧栏 + 播放器列 + 队列
        // 面板会把内容区挤成破版式，直接在原生层拦住（初始 1280×800 见
        // 原生 runner 默认值）。
        minimumSize: Size(900, 600),
      ),
    );
    // 显示前先摆好位置：show() 后再 setBounds 会肉眼可见地跳一下。
    await _restoreSavedGeometry();
    await windowManager.show();
    await windowManager.focus();
    if (_restoreMaximized) {
      _restoreMaximized = false;
      await windowManager.maximize();
    }
    await _applyLinuxWindowIcon();
  }

  /// 恢复上次关闭时的窗口几何。
  ///
  /// 开关关闭 / 没有保存值 / 拿不到显示器列表时保持系统默认位置：
  /// 拿不到显示器就无从校验，宁可用默认位置也不赌保存值可见。
  ///
  /// 最大化单独在 show() 之后补：`getBounds` 在最大化态返回最大化矩形，
  /// 存进去会丢还原尺寸，因此恢复路径也分两步（先还原几何，再最大化）。
  static Future<void> _restoreSavedGeometry() async {
    _restoreMaximized = false;
    if (!WindowSettings.rememberBounds) return;
    try {
      final saved = await _boundsStore.load();
      if (saved == null) return;
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return;
      final visibleAreas = [
        for (final display in displays) _visibleAreaOf(display),
      ];
      Rect primaryArea;
      try {
        primaryArea = _visibleAreaOf(await screenRetriever.getPrimaryDisplay());
      } catch (_) {
        // 主显示器查询失败（个别平台只实现枚举）：用列表首项居中兜底。
        primaryArea = visibleAreas.first;
      }
      await windowManager.setBounds(
        resolveRestoredBounds(
          saved: saved.bounds,
          displayVisibleAreas: visibleAreas,
          primaryVisibleArea: primaryArea,
        ),
      );
      _restoreMaximized = saved.maximized;
    } catch (error) {
      // 恢复失败不阻断启动：窗口按系统默认位置显示。
      _logger.warning('窗口几何恢复失败：$error');
    }
  }

  /// 显示器可见区（Dock / 任务栏之外的部分）；字段缺失时退回整屏矩形。
  static Rect _visibleAreaOf(Display display) =>
      (display.visiblePosition ?? Offset.zero) &
      (display.visibleSize ?? display.size);

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
      // 最大化态不覆盖 bounds（getBounds 返回最大化矩形，存了会丢还原尺寸）；
      // 最大化标记由 maximize 事件即时保存。
      if (await windowManager.isMaximized()) return;
      await _boundsStore.saveBounds(await windowManager.getBounds());
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
  /// window_manager 的 Dart 侧把参数前缀到 `data/flutter_assets/`（发布包与
  /// 调试 bundle 都存在该路径）；插件文档标着 windows 专用，但 Linux 实现
  /// 走 `gtk_window_set_icon_from_file`，此处按实现使用。
  static Future<void> _applyLinuxWindowIcon() async {
    if (!Platform.isLinux) return;
    try {
      await windowManager.setIcon('assets/icons/app_icon.png');
    } catch (_) {
      // 图标失败不影响窗口本身：忽略（Wayland / 资产缺失时不致命）。
    }
  }

  static Future<void> minimize() async {
    if (!isSupported) return;
    await windowManager.minimize();
  }

  /// 最大化 ⇄ 还原：以原生 `isMaximized()` 为准，不读 [maximized] 缓存
  /// （窗口管理器的手势/快捷键也能改变状态，缓存可能滞后一帧）。
  static Future<void> toggleMaximize() async {
    if (!isSupported) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// 发起关闭请求（顶栏关闭键）：与系统关闭按钮同一条路径，
  /// 由注入的关闭策略决定实际行为（隐藏到托盘 / 退出）。
  static Future<void> close() async {
    if (!isSupported) return;
    await windowManager.close();
  }

  /// 隐藏窗口（「关闭时最小化到托盘」）：进程与播放继续，任务栏/Tab 列表里
  /// 不再出现窗口；从托盘「显示主窗口」或单击图标恢复。
  static Future<void> hide() async {
    if (!isSupported) return;
    await windowManager.hide();
  }

  /// 显示并聚焦窗口（托盘「显示主窗口」/ 图标单击）。
  static Future<void> show() async {
    if (!isSupported) return;
    await windowManager.show();
    await windowManager.focus();
  }

  /// 无视关闭策略真正退出（托盘「退出」/ 更新安装后的重启替换）：
  /// 先释放单实例锁、解除关闭拦截，再销毁窗口；退出前的落盘由调用方负责。
  static Future<void> quit() async {
    if (!isSupported) return;
    // 正常退出路径顺带释放锁：下次启动能直接抢到（强杀残留由陈旧锁清理兜底）。
    await SingleInstance.release();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  /// 窗口当前是否可见（仅诊断/测试用）。
  @visibleForTesting
  static Future<bool> isVisible() async {
    if (!isSupported) return false;
    return windowManager.isVisible();
  }

  /// 原生标题栏高度（仅诊断/测试用）：隐藏标题栏后必须为 0。
  @visibleForTesting
  static Future<int> debugTitleBarHeight() async {
    if (!isSupported) return 0;
    return windowManager.getTitleBarHeight();
  }
}

/// 原生窗口状态 → [WindowChrome.maximized]；几何变更 → 防抖落盘；
/// 关闭请求 → 组合根策略。
class _MaximizedStateListener extends WindowListener {
  @override
  void onWindowMaximize() {
    WindowChrome._maximized.value = true;
    // 最大化时 getBounds 是最大化矩形：只记标记，不覆盖还原尺寸。
    WindowChrome._persistMaximized(true);
  }

  @override
  void onWindowUnmaximize() {
    WindowChrome._maximized.value = false;
    WindowChrome._persistMaximized(false);
    // 还原几何在事件后已生效，按正常保存路径重新记一次。
    WindowChrome._scheduleBoundsSave();
  }

  @override
  void onWindowMove() => WindowChrome._scheduleBoundsSave();

  @override
  void onWindowResize() => WindowChrome._scheduleBoundsSave();

  /// 关闭请求：`preventClose` 打开后原生关闭不会销毁窗口，这里把控制权交回
  /// Dart 策略；未注入策略（如集成测试直接调 ensureInitialized）时保持
  /// 历史行为——直接退出，避免窗口关闭键变成「点了没反应」。
  @override
  void onWindowClose() {
    final handler = WindowChrome._onCloseRequested;
    if (handler == null) {
      unawaited(WindowChrome.quit());
    } else {
      unawaited(Future.sync(handler));
    }
  }

  /// 从最小化恢复不代表退出最大化（最大化的窗口最小化后再恢复仍是最大化），
  /// 因此重新查询真实状态而不是直接置 false。
  @override
  void onWindowRestore() {
    if (!WindowChrome.isSupported) return;
    unawaited(
      windowManager.isMaximized().then((maximized) {
        WindowChrome._maximized.value = maximized;
      }),
    );
  }
}

/// 窗口拖动区：隐藏标题栏后按住空白处拖动窗口。
///
/// 语义同 window_manager 的 `DragToMoveArea`：pan 起始即交给原生
/// `startDragging()`（translucent 让顶栏的空白区域也能命中拖动，
/// 按钮/标题自身的点击手势不受影响——pan 与 tap 在手势竞技场按位移区分）。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
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
