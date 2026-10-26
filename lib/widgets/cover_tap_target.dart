import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 可点击查看封面的统一交互面。
///
/// 透明 [M3ECard] 只借它的交互层：hover / press 状态层、焦点环与
/// Enter/Space 激活；封面本身的裁切（ClipRRect / ClipOval）仍由调用方决定。
/// 有封面时才由页面包上本组件；空封面 / 错误回退保持原图、不可点。
///
/// [size] 给出封面边长，保证卡片在 Row 等无界宽度宿主里有确定触控面；
/// 缺省时由宿主约束宽度（如放在 Expanded 里）。
class CoverTapTarget extends StatelessWidget {
  const CoverTapTarget({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.onPressed,
    required this.semanticLabel,
    this.size,
    this.trackHover = true,
  });

  /// 封面视觉（通常已包好 ClipRRect / ClipOval）。
  final Widget child;

  /// 交互层圆角：与封面裁切保持同一形状（圆形头像传 `size / 2`）。
  final BorderRadius borderRadius;

  final VoidCallback onPressed;

  final String semanticLabel;

  /// 方形触控面边长；null = 由宿主约束。
  final double? size;

  /// 是否绘制 hover 状态层（键盘 / 触屏宿主可关掉）。
  final bool trackHover;

  @override
  Widget build(BuildContext context) {
    final card = M3ECard(
      variant: M3ECardVariant.filled,
      color: Colors.transparent,
      elevation: 0,
      borderRadius: borderRadius,
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      semanticLabel: semanticLabel,
      trackHover: trackHover,
      child: child,
    );
    final dimension = size;
    if (dimension == null) return card;
    return SizedBox.square(dimension: dimension, child: card);
  }
}
