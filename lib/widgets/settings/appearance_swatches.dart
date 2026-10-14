import 'package:material_ui/material_ui.dart';

/// 外观分区的预览图（在 [SettingsSwatchRow] 的 56dp 圆内自绘）。
///
/// 取色不在这里做：调用方（设置页）从 `ThemeProvider` 解析出各亮度方案后
/// 传入，与「主题解析唯一来源」保持一致；本文件只把方案画成可读的迷你界面。

/// 迷你界面：surface 底 + 主色圆点 + 次要文字条（表达「界面用这套方案」）。
class SchemeSwatchPreview extends StatelessWidget {
  const SchemeSwatchPreview({super.key, required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: 24,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 跟随系统：左右对切（浅 / 深两套方案各半），一眼看出「两套都跟随」。
class SystemSchemeSwatchPreview extends StatelessWidget {
  const SystemSchemeSwatchPreview({
    super.key,
    required this.lightScheme,
    required this.darkScheme,
  });

  final ColorScheme lightScheme;
  final ColorScheme darkScheme;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: SchemeSwatchPreview(scheme: lightScheme)),
        Expanded(child: SchemeSwatchPreview(scheme: darkScheme)),
      ],
    );
  }
}

/// 系统壁纸（莫奈）：主 / 次 / 三级色扫掠渐变——表达「配色取自壁纸多色」
/// （壁纸缩略图不可得；纯色块无法区分壁纸与自定义）。
class WallpaperSwatchPreview extends StatelessWidget {
  const WallpaperSwatchPreview({super.key, required this.scheme});

  /// 壁纸取色方案（莫奈不可用时由调用方传回退方案）。
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: SweepGradient(
          colors: [
            scheme.primary,
            scheme.secondary,
            scheme.tertiary,
            scheme.primary,
          ],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}
