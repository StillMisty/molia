/// 海报渲染样式解析：把当前主题与海报偏好（取色 / 字体）收成一组绘制参数。
///
/// UI 层调用；海报服务本身不读主题 / 偏好，只接收这里解析出的配色与字体。
library;

import 'package:material_ui/material_ui.dart';

import '../services/poster/poster_style_settings.dart';
import '../services/system_fonts_service.dart';
import '../theme/m3e_context.dart';
import '../theme/poster_palette.dart';
import '../theme/scheme_builder.dart';

typedef PosterRenderStyle = ({
  PosterPalette palette,
  String? fontFamily,
  List<String>? fontFamilyFallback,
});

/// 读取当前主题 + 海报取色 / 字体偏好。
///
/// 异步返回后调用方应检查 `mounted`；本函数在第一个 await 之前已取完
/// `BuildContext` 上的主题与排版。
Future<PosterRenderStyle> resolvePosterRenderStyle(BuildContext context) async {
  final appScheme = Theme.of(context).colorScheme;
  final textStyle = context.typeScale.bodyMedium;
  await PosterStyleSettings.ensureLoaded();
  final scheme = switch (PosterStyleSettings.colorSource) {
    PosterColorSource.appTheme || PosterColorSource.artwork => appScheme,
    PosterColorSource.custom => buildColorScheme(
      Color(PosterStyleSettings.seed),
      appScheme.brightness,
    ),
  };
  final override = PosterStyleSettings.fontFamily;
  final font = switch (override) {
    null => (
      family: textStyle.fontFamily,
      fallback: textStyle.fontFamilyFallback,
    ),
    '' => (
      family: SystemFontsService.platformDefaultFamily,
      fallback: SystemFontsService.platformDefaultFontFallbacks,
    ),
    final family => (family: family, fallback: null),
  };
  return (
    palette: PosterPalette.fromScheme(scheme),
    fontFamily: font.family,
    fontFamilyFallback: font.fallback,
  );
}
