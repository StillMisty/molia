/// 音量入口：音量图标 + 弹出滑杆面板（静音开关、百分比读数）。
///
/// 从 `lib/app/desktop/now_playing_bar.dart` 抽出为公开组件：底栏进播放页会
/// 隐藏，音量必须在播放页传输排里同样可达，两处共用同一实现（拖拽提交、
/// 静音、Esc/焦点语义都只有一份）。
library;

import 'dart:math';

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../services/escape_claims.dart';
import 'icon_swap.dart';

/// 音量图标按钮 + 弹层。
class VolumeControl extends StatefulWidget {
  const VolumeControl({
    super.key,
    this.buttonKey,
    this.panelKey,
    this.size = M3EIconButtonSize.sm,
    this.visualSize,
  });

  /// 图标按钮的稳定 Key（宿主 / 测试定位入口）。
  final Key? buttonKey;

  /// 弹层根节点的稳定 Key（定位面板与焦点包含判定）。
  final Key? panelKey;

  /// 图标按钮档位（默认桌面档 `sm`：40 视觉 / 48 触控目标）。
  final M3EIconButtonSize size;

  /// 图标按钮视觉尺寸覆盖；为空用该档位的 token。
  final Size? visualSize;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  final OverlayPortalController _controller = OverlayPortalController();

  /// 图标与面板同组：点图标算「组内」，不触发 onTapOutside——否则点图标
  /// 关闭面板时 onTapOutside 会先关一次、onPressed 的 toggle 再把它开回来。
  final Object _tapGroup = Object();

  /// 面板上限宽度：冷音键 48 + 滑杆 120 + 读数 40 + 内边距与间距 32。
  static const double _panelWidth = 240;

  /// 面板下限宽度：固定项（内边距 16 + 静音键 48 + 间距 16 + 读数 40）+
  /// 滑杆至少 32 可用宽。
  static const double _panelMinWidth = 152;

  /// 面板与宿主边缘的最小间距（窄窗收窄与贴边判定用同一值）。
  static const double _panelEdgeInset = 8;

  @override
  Widget build(BuildContext context) {
    final (muted, volume) = context.select<PlaybackProvider, (bool, double)>(
      (provider) => (provider.muted, provider.volume),
    );
    final l10n = AppLocalizations.of(context)!;
    final bool off = muted || volume == 0;
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _controller,
      overlayChildBuilder: (context, info) {
        // 锚点矩形（overlay 坐标系）= portal child 的本地矩形经
        // childPaintTransform 映射。刻意不用 CompositedTransformFollower：
        // overlay child 拿到的永远是整屏紧约束，follower 会以整屏尺寸参与
        // 定位与命中（面板变成铺满屏幕的命中区，点外部永远关不掉）。
        final anchor = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        // 面板贴图标右缘向左展开；两侧都会夹进宿主可绘制区内——播放页的
        // 音量入口在列中段，右贴边会把面板整个推出左边界。
        final double width = max(
          _panelMinWidth,
          min(_panelWidth, info.overlaySize.width - _panelEdgeInset * 2),
        );
        final double maxLeft = max(
          _panelEdgeInset,
          info.overlaySize.width - width - _panelEdgeInset,
        );
        return Positioned(
          left: (anchor.right - width).clamp(_panelEdgeInset, maxLeft),
          bottom: info.overlaySize.height - anchor.top + _panelEdgeInset,
          child: TapRegion(
            groupId: _tapGroup,
            onTapOutside: (_) => _controller.hide(),
            child: _VolumePanel(
              key: widget.panelKey,
              width: width,
              onClose: _controller.hide,
            ),
          ),
        );
      },
      child: TapRegion(
        groupId: _tapGroup,
        child: MouseRegion(
          // 桌面鼠标习惯：可点元素给手型（M3E 按钮自身不设鼠标指针）。
          cursor: SystemMouseCursors.click,
          child: M3EIconButton(
            key: widget.buttonKey,
            variant: M3EIconButtonVariant.standard,
            size: widget.size,
            visualSize: widget.visualSize,
            tooltip: l10n.playerBarVolume,
            icon: IconSwap<bool>(
              value: off,
              builder: (context, off) => Icon(
                off ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
            onPressed: _controller.toggle,
          ),
        ),
      ),
    );
  }
}

/// 音量面板：静音开关 + 滑杆 + 百分比读数（同一行）。
///
/// Esc 由自己的 [HardwareKeyboard] 处理器接住，与 [EscapeClaims] 登记同源
/// （挂载 = 可见 = 占用，都不依赖焦点位置）。不用 [Focus.onKeyEvent]：焦点被
/// Tab 移出弹层子树后按键不再冒泡到这里，而登记仍让壳层让位，Esc 会被完全
/// 吞掉。焦点由滑杆的 autofocus 领取 —— 面板一出现，左右方向键 / Home / End
/// 就能调音量，不用先 Tab 一次。
class _VolumePanel extends StatefulWidget {
  const _VolumePanel({super.key, required this.width, required this.onClose});

  /// 面板宽度（窄窗时由宿主收窄，滑杆是弹性项）。
  final double width;

  final VoidCallback onClose;

  @override
  State<_VolumePanel> createState() => _VolumePanelState();
}

class _VolumePanelState extends State<_VolumePanel> {
  /// 登记判定：本组件存在 = 面板可见（随 Overlay 挂载 / 卸载）。
  late final bool Function() _escapeClaim = _claimEscape;

  bool _claimEscape() => true;

  /// HardwareKeyboard 处理器引用：注册 / 注销必须是同一闭包。
  late final bool Function(KeyEvent) _keyHandler = _handleKeyEvent;

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    widget.onClose();
    return true;
  }

  @override
  void initState() {
    super.initState();
    EscapeClaims.add(_escapeClaim);
    HardwareKeyboard.instance.addHandler(_keyHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    EscapeClaims.remove(_escapeClaim);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (muted, volume) = context.select<PlaybackProvider, (bool, double)>(
      (provider) => (provider.muted, provider.volume),
    );
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final double value = volume.clamp(0.0, 1.0);
    final String percent = l10n.playerBarVolumePercent((value * 100).round());
    // tabular figures：等宽数字，0%→100% 变化时读数宽度不跳。
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          color: scheme.onSurfaceVariant,
        );
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: M3EElevation.level4,
      shape: RoundedRectangleBorder(borderRadius: M3EShapes.radiusLarge),
      child: SizedBox(
        width: widget.width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                size: M3EIconButtonSize.sm,
                tooltip: muted ? l10n.playerBarUnmute : l10n.playerBarMute,
                icon: IconSwap<bool>(
                  value: muted,
                  builder: (context, muted) => Icon(
                    muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                  ),
                ),
                onPressed: () => context.read<PlaybackProvider>().toggleMute(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: M3ESlider(
                  value: value,
                  min: 0,
                  max: 1,
                  size: M3ESliderSize.xs,
                  autofocus: true,
                  semanticLabel: l10n.playerBarVolume,
                  // 读数与滑杆同一格式化口径：朗读「音量 60%」而不是 0.6。
                  semanticFormatterCallback: (_) => percent,
                  onChanged: (value) =>
                      context.read<PlaybackProvider>().setVolume(value),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 40,
                child: Text(
                  percent,
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  style: style,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
