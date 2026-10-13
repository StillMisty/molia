import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Linux / Windows 桌面：window_manager 实现。
///
/// 仅当 [isSupported] 为真时调用插件；其它 io 平台（Android / iOS / macOS）
/// 与 stub 等价，避免调用未注册的插件方法（MissingPluginException）。
class WindowChrome {
  WindowChrome._();

  static bool get isSupported => Platform.isLinux || Platform.isWindows;

  static final ValueNotifier<bool> _maximized = ValueNotifier<bool>(false);
  static final _MaximizedStateListener _listener = _MaximizedStateListener();

  /// 当前窗口是否最大化：窗口按钮用它切换「最大化 / 还原」图标。
  static ValueListenable<bool> get maximized => _maximized;

  /// 隐藏原生标题栏并在首帧前显示窗口；由 main 在 runApp 前调用一次。
  ///
  /// `titleBarStyle: hidden` 之后系统标题栏与系统按钮都不复存在，
  /// 窗口拖动全靠 UI 侧的 [WindowDragArea]，不要在别处再隐藏标题栏。
  static Future<void> ensureInitialized() async {
    if (!isSupported) return;
    await windowManager.ensureInitialized();
    windowManager.addListener(_listener);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(titleBarStyle: TitleBarStyle.hidden),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
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

  static Future<void> close() async {
    if (!isSupported) return;
    await windowManager.close();
  }

  /// 原生标题栏高度（仅诊断/测试用）：隐藏标题栏后必须为 0。
  @visibleForTesting
  static Future<int> debugTitleBarHeight() async {
    if (!isSupported) return 0;
    return windowManager.getTitleBarHeight();
  }
}

/// 原生窗口状态 → [WindowChrome.maximized]。
class _MaximizedStateListener extends WindowListener {
  @override
  void onWindowMaximize() => WindowChrome._maximized.value = true;

  @override
  void onWindowUnmaximize() => WindowChrome._maximized.value = false;

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
