import 'package:material_ui/material_ui.dart';

/// Molia 品牌标志图标：替代 Material 音符字形（封面占位/回退等）。
///
/// - 默认实心版；[outlined] 用描边（非填充）版，供导航「未选中」等空心语境；
/// - [color]/[size] 缺省时跟随环境 [IconTheme]（与 `Icon` 行为一致），
///   可直接放进 NavigationBar/Rail 的 destination 或任意图标位；
/// - PNG 资源由 `assets/icons/molia_logo.svg`（描边版为
///   `molia_logo_outline.svg`）导出；SVG 是唯一矢量源，改图后需重新导出。
class MoliaMark extends StatelessWidget {
  const MoliaMark({super.key, this.size, this.color, this.outlined = false});

  /// 图标边长；缺省取环境 [IconTheme] 的 size，再退 24。
  final double? size;

  /// 着色；缺省取环境 [IconTheme] 的 color，再退 onSurface。
  final Color? color;

  /// 是否使用描边（非填充）版本。
  final bool outlined;

  static const String _filledAsset = 'assets/icons/molia_logo.png';
  static const String _outlinedAsset = 'assets/icons/molia_logo_outline.png';

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24.0;
    final resolvedColor =
        color ?? iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    return Image.asset(
      outlined ? _outlinedAsset : _filledAsset,
      width: resolvedSize,
      height: resolvedSize,
      fit: BoxFit.contain,
      color: resolvedColor,
      filterQuality: FilterQuality.medium,
    );
  }
}
