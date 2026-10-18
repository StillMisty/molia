import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/duration_text.dart';
import 'seek_preview.dart';

/// 进度滑杆：`SeekPreviewController` 的渲染面（播放页 / 桌面底栏共用）。
///
/// 只做取值与外观映射，不含时序语义（时序在 controller）：
/// - 预览值优先于 position 通道：拖动中与提交等待期不被旧值回拽；
/// - 松手提交不看滑杆回调的入参（快速单击时它是上一帧的旧位置），落点由
///   [SeekPreviewController.commit] 按预览值决定；
/// - 播放中用波浪滑杆，暂停切平直：波浪动画不会停，与暂停态自相矛盾；
/// - 气泡 / 侧时间统一走 [durationText]，无效值兜 `0:00` / `--:--`；
/// - 外层 `RepaintBoundary` 是硬需求：波浪滑杆内部是 `repeat()` 的无限
///   动画，不隔离的话播放中每次波形重绘都会把宿主整块卷进同一图层重光栅化。
class SeekBar extends StatelessWidget {
  const SeekBar({
    super.key,
    required this.controller,
    required this.position,
    required this.durationMs,
    required this.isPlaying,
    required this.hasTrack,
    this.showTimeLabels = false,
  });

  final SeekPreviewController controller;

  /// position 通道：高频道，重建只发生在滑杆内部。
  final ValueListenable<Duration> position;

  final int durationMs;
  final bool isPlaying;
  final bool hasTrack;

  /// 显示左右时间文字（桌面底栏版式）；播放页只显示拖动气泡。
  final bool showTimeLabels;

  @override
  Widget build(BuildContext context) {
    final bool enabled = hasTrack && durationMs > 0;
    final double maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
    return RepaintBoundary(
      child: ValueListenableBuilder<double?>(
        valueListenable: controller.previewMs,
        builder: (context, previewMs, _) {
          return ValueListenableBuilder<Duration>(
            valueListenable: position,
            builder: (context, position, _) {
              final double valueMs =
                  (previewMs ?? position.inMilliseconds.toDouble())
                      .clamp(0.0, maxMs);
              final ValueChanged<double>? onChanged =
                  enabled ? controller.preview : null;
              // 入参是滑杆上一帧的 value（快速单击时即点击前的位置），不可用：
              // 提交落点由 controller 记住的预览值决定。
              final ValueChanged<double>? onChangeEnd =
                  enabled ? (double _) => controller.commit() : null;
              final String label = durationText(valueMs.round()) ?? '0:00';

              final Widget slider = isPlaying
                  ? M3ESlider.wavy(
                      value: valueMs,
                      min: 0,
                      max: maxMs,
                      size: M3ESliderSize.xs,
                      trackThickness: 6,
                      enabled: enabled,
                      label: label,
                      onChanged: onChanged,
                      onChangeEnd: onChangeEnd,
                    )
                  : M3ESlider(
                      value: valueMs,
                      min: 0,
                      max: maxMs,
                      size: M3ESliderSize.xs,
                      trackThickness: 6,
                      enabled: enabled,
                      label: label,
                      onChanged: onChanged,
                      onChangeEnd: onChangeEnd,
                    );
              if (!showTimeLabels) return slider;

              // tabular figures：等宽数字避免每秒文本宽度变化把滑杆左右推挤。
              final style = Theme.of(context).textTheme.labelSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              );
              return Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      enabled ? label : '--:--',
                      style: style,
                      maxLines: 1,
                    ),
                  ),
                  Expanded(child: slider),
                  SizedBox(
                    width: 40,
                    child: Text(
                      enabled ? (durationText(durationMs) ?? '--:--') : '--:--',
                      style: style,
                      maxLines: 1,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
