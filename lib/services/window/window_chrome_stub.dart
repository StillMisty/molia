import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Web / 移动端 / macOS：无窗口 chrome。
///
/// 除 [isSupported] 恒为 false 外全部是空操作；[maximized] 是常量 false 的
/// [ValueListenable]，UI 可无条件监听而不触碰任何插件 API。
class WindowChrome {
  WindowChrome._();

  static bool get isSupported => false;

  static Future<void> ensureInitialized() async {}

  static Future<void> minimize() async {}

  static Future<void> toggleMaximize() async {}

  static Future<void> close() async {}

  static final ValueNotifier<bool> _maximized = ValueNotifier<bool>(false);

  /// 当前窗口是否最大化（本平台恒为 false）。
  static ValueListenable<bool> get maximized => _maximized;

  /// 原生标题栏高度（仅诊断/测试用）：本平台无窗口 chrome，恒为 0。
  @visibleForTesting
  static Future<int> debugTitleBarHeight() async => 0;
}

/// 窗口拖动区（本平台为纯透传：没有可拖动的原生窗口）。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// 桌面窗口双击区（本平台为纯透传：没有可最大化的原生窗口）。
class WindowDoubleTapMaximize extends StatelessWidget {
  const WindowDoubleTapMaximize({super.key, required this.child, this.onDoubleTap});

  final Widget child;

  /// 测试注入；缺省由平台实现决定（本平台为空操作）。
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) => child;
}
