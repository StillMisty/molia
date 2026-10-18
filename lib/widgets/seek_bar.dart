import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/duration_text.dart';
import 'seek_preview.dart';

/// 侧时间文字的排布：两处宿主各取一档（见 [SeekBar.timeLabels]）。
enum SeekTimeLabels {
  /// 与滑杆同行、分列两侧 —— 桌面底栏版式（那里横向空间与传输键 / 右区共享，
  /// 再占一行会把整条底栏顶高）。
  inline,

  /// 滑杆独占一行，当前值 / 总时长**居中于条的左右端点正下方** —— 播放页版式：
  /// 横向空间全部还给进度条，时间行用溢出绘制叠在条下方、**不占纵向高度**
  /// （移动端把这块高度让给封面 / 歌词）。
  below,
}

/// 进度滑杆：`SeekPreviewController` 的渲染面（播放页 / 桌面底栏共用）。
///
/// 只做取值与外观映射，不含时序语义（时序在 controller）：
/// - 预览值优先于 position 通道：拖动中与提交等待期不被旧值回拽；
/// - 松手提交不看滑杆回调的入参（快速单击时它是上一帧的旧位置），落点由
///   [SeekPreviewController.commit] 按预览值决定；
/// - 播放中用波浪滑杆，暂停切平直：波浪动画不会停，与暂停态自相矛盾；
/// - 时间文字两档排布见 [SeekTimeLabels]，颜色 / 对齐也收在
///   [_labelStyle] / [_decorateSlider]；无效值兜 `0:00` / `--:--`；
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
    required this.timeLabels,
  });

  /// 时间标签槽宽：两档排布共用，等宽数字下 `12:34` 也不会被截。
  static const double _labelSlotWidth = 40;

  /// `below` 档条与时间之间的留白：时间行是溢出绘制的（不占块高），这里只留
  /// 2px 呼吸位，避免紧贴条的下缘。
  static const double _belowLabelGap = 2;

  /// 滑杆盒子高度：M3E 的 xs 沿用全局 [M3ESliderTheme]，默认 `height` /
  /// `handleHeight` 都是 44——可见轨道只有 6，多出来的全是拇指（4×44 竖条）与
  /// 命中区。进度条是「条 + 条下方时间」的两段结构，44 会把时间行挤到很下面，
  /// 这里只在本组件内压到 32：拇指仍是竖条，进度排整体矮 12dp（移动端把这块
  /// 让给封面 / 歌词）。两处宿主共用同一档，视觉一致。
  static const double _sliderHeight = 32;

  final SeekPreviewController controller;

  /// position 通道：高频道，重建只发生在滑杆内部。
  final ValueListenable<Duration> position;

  final int durationMs;
  final bool isPlaying;
  final bool hasTrack;

  /// 时间文字排布（见 [SeekTimeLabels]）。
  final SeekTimeLabels timeLabels;

  /// tabular figures：等宽数字避免每秒文本宽度变化把滑杆左右推挤。
  TextStyle? _labelStyle(BuildContext context, {required bool faint}) {
    final TextStyle? base = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (!faint) return base;
    // 读数不该与滑杆抢注意力：比默认 labelSmall 更淡一档。
    return base?.copyWith(
      color: Theme.of(context)
          .colorScheme
          .onSurfaceVariant
          .withValues(alpha: 0.6),
    );
  }

  /// 时间文字：`inline` 与滑杆同行分列两侧；`below` 排在条下方、各居中于条的
  /// 左右端点正下方。
  ///
  /// 两档共用同一对 40px 槽位与同一套取值，只有对齐口径与行位置不同——`below`
  /// 用 `Transform` 外移半个槽宽（只影响绘制，行高仍是文字自身高度），行满条宽
  /// 保证标签中心落在条的两个端点上。
  Widget _decorateSlider(
    BuildContext context,
    Widget slider,
    String current,
    String total,
  ) {
    final bool faint = timeLabels == SeekTimeLabels.below;
    final TextStyle? style = _labelStyle(context, faint: faint);
    Widget slot(String text, TextAlign align) => SizedBox(
          width: _labelSlotWidth,
          child: Text(text, style: style, maxLines: 1, textAlign: align),
        );

    // inline：时间与条同行，分列两侧。
    if (timeLabels == SeekTimeLabels.inline) {
      return Row(
        children: [
          slot(current, TextAlign.start),
          Expanded(child: slider),
          slot(total, TextAlign.end),
        ],
      );
    }
    // below：时间排在条下方，中心对齐条的两个端点（端点外半个槽宽）；整行都在
    // 图标与条那条线之下，所以不会撞上两侧图标，也不会碰到端点的拇指。
    //
    // 纵向不占高：零高槽位 + `OverflowBox` 让时间行照常布局、从槽位顶部往下
    // 溢出绘制——块高只算条（[_sliderHeight]），与「时间与条同行」的宿主一致；
    // 宿主按条高给块留位即可，多出来的空间由溢出的时间行占用。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        slider,
        SizedBox(
          height: 0,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            child: Padding(
              padding: const EdgeInsets.only(top: _belowLabelGap),
              child: Row(
                children: [
                  Transform.translate(
                    offset: const Offset(-_labelSlotWidth / 2, 0),
                    child: slot(current, TextAlign.center),
                  ),
                  const Spacer(),
                  Transform.translate(
                    offset: const Offset(_labelSlotWidth / 2, 0),
                    child: slot(total, TextAlign.center),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

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

              final Widget sliderBody = isPlaying
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

              // 只在进度条这一层压滑杆几何：拇指与命中区都跟着矮，轨道（6）不变。
              final M3EThemeData m3e = M3ETheme.of(context);
              final Widget slider = M3ETheme(
                data: m3e.copyWith(
                  sliderTheme: m3e.sliderTheme.copyWith(
                    height: _sliderHeight,
                    handleHeight: _sliderHeight,
                  ),
                ),
                child: sliderBody,
              );

              // 无效时长 / 无曲目时两档都用占位，读数不显示假值。
              final String currentLabel = enabled ? label : '--:--';
              final String totalLabel =
                  enabled ? (durationText(durationMs) ?? '--:--') : '--:--';
              return _decorateSlider(context, slider, currentLabel, totalLabel);
            },
          );
        },
      ),
    );
  }
}
