/// 音量入口：音量图标 + 弹出滑杆面板（静音开关、百分比读数）。
///
/// 底栏与播放页传输排共用同一实现（拖拽提交、静音、Esc/焦点语义都只有一份）。
library;

import 'dart:math';

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../services/escape_claims.dart';
import '../theme/m3e_context.dart';
import '../theme/motion_policy.dart';
import 'icon_swap.dart';

/// 音量图标按钮 + 弹层。
///
/// 图标按钮与面板两个锚点 key 由宿主给出：底栏与播放页各有自己的稳定 Key
/// （测试定位入口与焦点包含判定）。
class VolumeControl extends StatefulWidget {
  const VolumeControl({super.key, this.buttonKey, this.panelKey});

  /// 图标按钮的稳定 Key（宿主 / 测试定位入口）。
  final Key? buttonKey;

  /// 弹层根节点的稳定 Key（定位面板与焦点包含判定）。
  final Key? panelKey;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl>
    with SingleTickerProviderStateMixin {
  final OverlayPortalController _controller = OverlayPortalController();

  /// 面板入场 / 退场进度：spatial 弹簧驱动缩放，透明度从同一进度截断
  /// 0..1（effects 不过冲）。
  late final SingleMotionController _panelMotion = SingleMotionController(
    motion: const MaterialSpringMotion.expressiveSpatialFast(snapToEnd: true),
    vsync: this,
  );

  /// 面板逻辑可见（关闭动画期间为 false，但 overlay 尚未移除）。
  bool _panelVisible = false;

  /// 关闭请求序号：关闭途中重开 / 再次关闭时让旧的 whenComplete 失效。
  int _closeRequest = 0;

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
  void dispose() {
    _panelMotion.dispose();
    super.dispose();
  }

  /// 打开面板：先挂 overlay 再起弹簧（关闭途中重开从当前进度续跑）。
  void _showPanel() {
    // 任何一次打开都让尚未落定的关闭请求失效。
    _closeRequest++;
    if (!_panelVisible) {
      setState(() => _panelVisible = true);
      _controller.show();
    }
    if (reduceMotionOf(context)) {
      _panelMotion.value = 1;
      return;
    }
    _panelMotion.animateTo(1);
  }

  /// 关闭面板：收起动画落定后才移除 overlay；等待期间 IgnorePointer。
  void _hidePanel() {
    if (!_panelVisible) return;
    final request = ++_closeRequest;
    setState(() => _panelVisible = false);
    if (reduceMotionOf(context)) {
      _panelMotion.value = 0;
      _controller.hide();
      return;
    }
    _panelMotion.animateTo(0).whenComplete(() {
      if (!mounted || request != _closeRequest || _panelVisible) return;
      _controller.hide();
    });
  }

  void _togglePanel() => _panelVisible ? _hidePanel() : _showPanel();

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
          child: AnimatedBuilder(
            animation: _panelMotion,
            builder: (context, child) {
              final double progress = _panelMotion.value;
              return IgnorePointer(
                // 关闭动画期间只保留视觉，不再接收点击（Esc / 外部点击
                // 的关闭入口都已走 [_hidePanel]，不会重复触发）。
                ignoring: !_panelVisible,
                child: Opacity(
                  opacity: progress.clamp(0.0, 1.0),
                  child: Transform.scale(
                    // 以图标（面板右下角）为锚点从 0.94 展开；spatial 弹簧
                    // 允许轻微过冲，透明度仍截断在 0..1。
                    scale: 0.94 + 0.06 * progress,
                    alignment: Alignment.bottomRight,
                    child: child,
                  ),
                ),
              );
            },
            child: TapRegion(
              groupId: _tapGroup,
              onTapOutside: (_) => _hidePanel(),
              child: _VolumePanel(
                key: widget.panelKey,
                width: width,
                onClose: _hidePanel,
              ),
            ),
          ),
        );
      },
      child: TapRegion(
        groupId: _tapGroup,
        // M3EIconButton 默认已是手型光标，不再叠一层 MouseRegion。
        child: M3EIconButton(
          key: widget.buttonKey,
          variant: M3EIconButtonVariant.standard,
          semanticLabel: l10n.playerBarVolume,
          icon: IconSwap<bool>(
            value: off,
            builder: (context, off) => Icon(
              off ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            ),
          ),
          onPressed: _togglePanel,
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
    final style = context.typeScale.labelSmall.copyWith(
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
                semanticLabel: muted ? l10n.playerBarUnmute : l10n.playerBarMute,
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
