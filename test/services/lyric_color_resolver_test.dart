import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/services/lyrics_display/lyric_color_resolver.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';

/// 歌词颜色解析：自定义原样返回；主题角色映射 ColorScheme（莫奈/封面取色出口）。
void main() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3366FF));

  test('自定义来源原样返回', () {
    expect(
      resolveLyricColor(LyricColorSource.custom, 0xFF123456, scheme),
      0xFF123456,
    );
  });

  test('主题角色映射到 ColorScheme', () {
    expect(
      resolveLyricColor(LyricColorSource.primary, 0, scheme),
      scheme.primary.toARGB32(),
    );
    expect(
      resolveLyricColor(LyricColorSource.secondary, 0, scheme),
      scheme.secondary.toARGB32(),
    );
    expect(
      resolveLyricColor(LyricColorSource.tertiary, 0, scheme),
      scheme.tertiary.toARGB32(),
    );
    expect(
      resolveLyricColor(LyricColorSource.onSurface, 0, scheme),
      scheme.onSurface.toARGB32(),
    );
    expect(
      resolveLyricColor(LyricColorSource.onSurfaceVariant, 0, scheme),
      scheme.onSurfaceVariant.toARGB32(),
    );
  });
}
