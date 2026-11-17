/// 歌词页滚动协作：ScrollController、行 key、视口测量与跟随落点。
///
/// 「滚到哪、要不要动」仍是 [lyrics_scroll_policy] 里的纯函数；本文件只负责
/// 测量（ScrollController / RenderAbstractViewport / 遮挡回调）与执行
/// （jumpTo / animateTo），播放页状态机决定时机（见 `lyrics_view_session.dart`）。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../../domain/models/lyric_line.dart';
import '../lyrics_scroll_policy.dart';
import '../../theme/motion_policy.dart';

/// 激活行锚点相对「可见区域中线」的上移比例（占视口高度）。
///
/// 顶栏（顶部渐隐带 + 圆点带）比底栏高，只按可见区域居中会让激活行
/// 视觉偏下；0.14 使主行文本顶边落在视口约 38%–40% 高度（中上排版），
/// 上下留白更平衡。
/// 锚点作用于「主行文本块顶边」（整项还含翻译/罗马音，不参与锚定）。
const double _activeLineUpwardBias = 0.14;

/// 歌词列表的滚动宿主。
///
/// 行 key 由这里统一持有：点行 seek 用整项 key，自动滚动锚定用主行文本块
/// key（整项还包含翻译/罗马音，按文本块锚定落点才不会被项高带偏）。
class LyricsScrollDriver {
  LyricsScrollDriver({
    required ScrollController? externalController,
    required this.topOverlay,
    required this.bottomOverlay,
    required this.canScheduleWork,
    required this.onScrollableChanged,
  }) : controller = externalController ?? ScrollController(),
       ownsController = externalController == null;

  /// 外部控制器由宿主释放；为空时本类自建并自行释放。
  final ScrollController controller;
  final bool ownsController;

  /// 顶栏 / 底栏遮挡高度（含系统安全区）；由宿主按当前布局读取。
  final double Function() topOverlay;
  final double Function() bottomOverlay;

  /// 是否允许排帧末测量（页面挂载且当前可见）。
  final bool Function() canScheduleWork;

  /// 可滚性测量结果（交给视图会话统一决定操作栏显隐）。
  final ValueChanged<bool> onScrollableChanged;

  final GlobalKey listViewKey = GlobalKey();

  /// 行（整项）的 key：点行 seek 与命中判定用。
  final List<GlobalKey> lineKeys = [];

  /// 主行文本块的 key：自动滚动锚定用。
  final List<GlobalKey> lineTextKeys = [];

  bool _scrollabilityCheckScheduled = false;

  bool get hasClients => controller.hasClients;

  void syncLineKeys(int targetLength) {
    _resizeKeys(lineKeys, targetLength);
    _resizeKeys(lineTextKeys, targetLength);
  }

  static void _resizeKeys(List<GlobalKey> keys, int targetLength) {
    if (keys.length == targetLength) return;
    if (keys.length < targetLength) {
      final difference = targetLength - keys.length;
      for (int i = 0; i < difference; i++) {
        keys.add(GlobalKey());
      }
    } else {
      keys.removeRange(targetLength, keys.length);
    }
  }

  void jumpToTop() {
    if (!controller.hasClients) return;
    controller.jumpTo(0);
  }

  /// 激活行锚点：可见区域（去掉顶部渐隐带/底栏）的纵向中线，再整体上移
  /// `_activeLineUpwardBias` 个视口高度（顶栏比底栏高，居中会视觉偏下）。
  ///
  /// 只返回「视口比例」，落点由 `anchoredLineOffset` 换算为主行文本块顶边。
  double get anchorFraction {
    if (!controller.hasClients) {
      return 0.5 - _activeLineUpwardBias;
    }
    final viewport = controller.position.viewportDimension;
    return effectiveAlignment(
      viewport: viewport,
      topOverlay: topOverlay(),
      bottomOverlay: bottomOverlay(),
      upwardBias: _activeLineUpwardBias,
    );
  }

  /// 列表尾部留白：保证最后一行也能滚到锚点位置。
  double get tailSpacePixels {
    if (!controller.hasClients) return 400.0;
    final position = controller.position;
    if (!position.hasPixels || position.viewportDimension <= 0) {
      return 400.0;
    }
    return tailSpace(
      viewport: position.viewportDimension,
      topOverlay: topOverlay(),
      bottomOverlay: bottomOverlay(),
      upwardBias: _activeLineUpwardBias,
    );
  }

  /// 测量歌词内容是否可滚动，并把结果交给视图会话（显隐条件在那里统一）。
  void scheduleScrollabilityCheck() {
    if (_scrollabilityCheckScheduled) {
      return;
    }
    _scrollabilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollabilityCheckScheduled = false;
      if (!canScheduleWork()) {
        return;
      }
      if (!controller.hasClients) {
        scheduleScrollabilityCheck();
        return;
      }
      final position = controller.position;
      final bool canScroll =
          (position.maxScrollExtent - position.minScrollExtent).abs() > 1.0;
      onScrollableChanged(canScroll);
    });
  }

  /// 滚到当前行：把主行文本块的顶边锚定在 [anchorFraction] 处。
  ///
  /// 目标尚未布局（远跳 / 首帧）时返回 false，粗定位与按帧重试由视图会话
  /// 决定（见 `lyrics_view_session.dart`）。
  bool scrollToLine(int index, {required BuildContext context}) {
    if (!hasClients || index < 0 || index >= lineTextKeys.length) {
      return false;
    }

    final position = controller.position;
    final renderObject = lineTextKeys[index].currentContext?.findRenderObject();
    if (renderObject == null) return false;

    try {
      final viewport = RenderAbstractViewport.of(renderObject);
      // 顶边对齐视口顶边时的偏移；再减去锚点距离得到目标偏移。
      final leadingOffset = viewport
          .getOffsetToReveal(renderObject, 0.0)
          .offset;
      final target = anchoredLineOffset(
        leadingOffset: leadingOffset,
        viewport: position.viewportDimension,
        anchorFraction: anchorFraction,
      );
      final clampedOffset = clampScrollOffset(
        target: target,
        minScrollExtent: position.minScrollExtent,
        maxScrollExtent: position.maxScrollExtent,
      );

      if (reduceMotionOf(context)) {
        // 减弱动效：直接落位，保留同一 clamp / 重试口径。
        controller.jumpTo(clampedOffset);
      } else {
        controller.animateTo(
          clampedOffset,
          // M3E long4 + emphasized decelerate：长距离跟随「先快后稳」收住，
          // 到点不甩尾。
          duration: M3EMotion.long4,
          curve: M3EMotion.emphasizedDecelerate,
        );
      }
    } catch (_) {
      // 滚动失败可忽略：下一帧会话会重试
    }
    return true;
  }

  /// 目标未布局时的粗定位：按时间戳（缺曲目时长时按行号）比例估算偏移并
  /// 跳过去，让目标进入列表构建范围；精确滚动交给下一帧重试。
  void jumpTowardLine({
    required int currentLineIndex,
    required List<LyricLine> lines,
    required int? durationMs,
  }) {
    if (!controller.hasClients) return;
    final position = controller.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    if (lines.isEmpty || currentLineIndex >= lines.length) return;

    double ratio;
    if (durationMs != null && durationMs > 0) {
      ratio = lines[currentLineIndex].timestamp.inMilliseconds / durationMs;
    } else if (lines.length <= 1) {
      ratio = 0.0;
    } else {
      ratio = currentLineIndex / (lines.length - 1);
    }
    ratio = ratio.isFinite ? ratio.clamp(0.0, 1.0) : 0.0;

    final target = clampScrollOffset(
      target:
          ratio * position.maxScrollExtent -
          anchorFraction * position.viewportDimension,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
    );
    if (!shouldScrollTo(current: position.pixels, target: target)) return;
    try {
      controller.jumpTo(target);
    } catch (_) {
      // 跳转失败可忽略：下一帧会重试
    }
  }

  void dispose() {
    if (ownsController) controller.dispose();
  }
}
