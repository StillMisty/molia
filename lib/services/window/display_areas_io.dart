import 'dart:ui';

import 'package:nativeapi/nativeapi.dart' as na;

/// 桌面显示器可见区（Dock / 任务栏之外的部分）。
///
/// 与 window_manager 的窗口几何对接：nativeapi 的 `Display.workArea` 与
/// screen_retriever 的 `visiblePosition + visibleSize` 同口径（0.3.0 的兼容层
/// 就是直接映射这两个字段），因此可以直接用来校验 / 恢复窗口位置。
///
/// FFI 只在本文件出现：托盘实现（`app_tray_io.dart`）与这里各自持有
/// nativeapi 的调用面，其它窗口代码只消费纯 [Rect]。
class DesktopDisplayAreas {
  const DesktopDisplayAreas({
    required this.visibleAreas,
    required this.primary,
  });

  /// 所有显示器的可见区。
  final List<Rect> visibleAreas;

  /// 主显示器可见区；主屏查询失败时退回 [visibleAreas] 首项。
  final Rect primary;

  /// 读取显示器列表；没有显示器（或平台实现不可用）时返回 null。
  ///
  /// 其它 FFI 异常交给调用方按「恢复失败」处理，避免窗口启动被显示层拖死。
  static DesktopDisplayAreas? read() {
    final displays = na.DisplayManager.instance.getAll();
    if (displays.isEmpty) return null;
    final visibleAreas = [
      for (final display in displays) _rectOf(display.workArea),
    ];
    Rect primary;
    try {
      final primaryDisplay = na.DisplayManager.instance.getPrimary();
      if (primaryDisplay == null) throw StateError('no primary display');
      primary = _rectOf(primaryDisplay.workArea);
    } catch (_) {
      // 个别平台只实现枚举：用列表首项居中兜底。
      primary = visibleAreas.first;
    }
    return DesktopDisplayAreas(visibleAreas: visibleAreas, primary: primary);
  }

  static Rect _rectOf(na.Rectangle area) =>
      Rect.fromLTWH(area.x, area.y, area.width, area.height);
}
