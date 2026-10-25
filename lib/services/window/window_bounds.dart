/// 窗口几何恢复的纯逻辑：保存值的可用性校验与离屏回退。
///
/// 与插件 IO 分离（screen_retriever / window_manager 的调用都在
/// `window_chrome_io.dart`）：这里只做矩形运算，便于单测覆盖「显示器拔掉 /
/// 分辨率变化后窗口落在屏幕外」的边界。
library;

import 'dart:math' as math;
import 'dart:ui';

/// 窗口最小尺寸：与下发给原生的 `minimumSize` 同值（再窄时桌面骨架会破版式）。
const Size kMinimumWindowSize = Size(900, 600);

/// 判定「落在可见区内」所需的最小交集：两个方向各 100 逻辑像素。
///
/// 取 100 而不是「任意 1px」：只露出一条边或一个角时用户几乎抓不住窗口
/// （拖动区在顶栏，窗口顶部完全出屏就拖不回来），视为不可见更安全。
const double kMinimumVisibleOverlap = 100;

/// 保存的矩形与某显示器可见区是否有足够交集。
bool windowBoundsVisibleOn(Rect bounds, Rect visibleArea) {
  final overlap = bounds.intersect(visibleArea);
  return overlap.width >= kMinimumVisibleOverlap &&
      overlap.height >= kMinimumVisibleOverlap;
}

/// 解析要恢复的窗口矩形。
///
/// 规则：
/// - 尺寸先夹到最小 [kMinimumWindowSize]（异常存储值可能更小）；
/// - 与任一显示器可见区有足够交集 → 按保存的位置恢复（多显示器场景下
///   副屏上的窗口不会被打回主屏）；
/// - 否则（显示器拔掉、分辨率变小、存储值损坏）→ 主显示器居中，保证窗口
///   一定可见、可拖。
Rect resolveRestoredBounds({
  required Rect saved,
  required List<Rect> displayVisibleAreas,
  required Rect primaryVisibleArea,
}) {
  final usable = saved.isFinite && saved.width > 0 && saved.height > 0;
  final size = usable
      ? Size(
          math.max(saved.width, kMinimumWindowSize.width),
          math.max(saved.height, kMinimumWindowSize.height),
        )
      : kMinimumWindowSize;
  if (usable) {
    final candidate =
        Rect.fromLTWH(saved.left, saved.top, size.width, size.height);
    if (displayVisibleAreas
        .any((area) => windowBoundsVisibleOn(candidate, area))) {
      return candidate;
    }
  }
  return Rect.fromLTWH(
    primaryVisibleArea.left + (primaryVisibleArea.width - size.width) / 2,
    primaryVisibleArea.top + (primaryVisibleArea.height - size.height) / 2,
    size.width,
    size.height,
  );
}
