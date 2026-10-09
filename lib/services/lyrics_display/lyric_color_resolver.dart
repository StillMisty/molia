import 'package:material_ui/material_ui.dart';

import 'lyrics_display_settings.dart';

/// 桌面歌词颜色解析：自定义色板或跟随主题 ColorScheme 角色。
///
/// 主题角色由 `ThemeProvider` 统一解析（莫奈壁纸取色 > 专辑封面取色 > 种子色），
/// 因此「跟随主题」自动覆盖系统配色（莫奈）与歌曲图片取色两条链路；
/// 封面切换 / 系统配色变化导致主题更新时，歌词显示调度会重新下发悬浮窗配置。
int resolveLyricColor(
  LyricColorSource source,
  int customColor,
  ColorScheme scheme,
) {
  return switch (source) {
    LyricColorSource.custom => customColor,
    LyricColorSource.primary => scheme.primary.toARGB32(),
    LyricColorSource.secondary => scheme.secondary.toARGB32(),
    LyricColorSource.tertiary => scheme.tertiary.toARGB32(),
    LyricColorSource.onSurface => scheme.onSurface.toARGB32(),
    LyricColorSource.onSurfaceVariant => scheme.onSurfaceVariant.toARGB32(),
  };
}
