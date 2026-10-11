import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/theme/poster_palette.dart';
import 'package:molia/theme/scheme_builder.dart';

/// 色彩系统基建契约：方案工厂稳定、消费面来源回退、纯黑正交、海报角色成对。
void main() {
  const seed = Color(0xFF2196F3);
  const otherSeed = Color(0xFF00BB00);

  test('buildColorScheme：同 seed + 亮度必得同一方案', () {
    expect(
      buildColorScheme(seed, Brightness.light),
      buildColorScheme(seed, Brightness.light),
    );
    expect(
      buildColorScheme(seed, Brightness.dark),
      buildColorScheme(seed, Brightness.dark),
    );
    expect(
      buildColorScheme(seed, Brightness.light),
      isNot(buildColorScheme(seed, Brightness.dark)),
    );
  });

  test('resolveSurfaceScheme：封面方案缺失回退应用主题', () {
    final appScheme = buildColorScheme(seed, Brightness.light);
    final artworkScheme = buildColorScheme(otherSeed, Brightness.light);

    expect(
      resolveSurfaceScheme(SurfaceColorSource.appTheme,
          appScheme: appScheme, artworkScheme: artworkScheme),
      appScheme,
    );
    expect(
      resolveSurfaceScheme(SurfaceColorSource.artwork,
          appScheme: appScheme, artworkScheme: artworkScheme),
      artworkScheme,
    );
    // 无封面取色结果：回退应用主题，不抛错、不换来源。
    expect(
      resolveSurfaceScheme(SurfaceColorSource.artwork, appScheme: appScheme),
      appScheme,
    );
  });

  test('applyPureBlackScheme：仅深色覆盖 surface 系列，浅色原样返回', () {
    final dark = buildColorScheme(seed, Brightness.dark);
    final blackened = applyPureBlackScheme(dark);
    expect(blackened.surface.toARGB32(), 0xFF000000);
    expect(blackened.surfaceContainerHighest.toARGB32(), 0xFF000000);
    expect(blackened.surfaceBright.toARGB32(), 0xFF000000);
    expect(blackened.surfaceTint.toARGB32(), 0xFF000000);
    // 交互色不受纯黑影响（只是表面修饰）。
    expect(blackened.primary, dark.primary);

    final light = buildColorScheme(seed, Brightness.light);
    expect(applyPureBlackScheme(light), light);
  });

  test('PosterPalette：容器底 + 容器前景成对，歌手走强调色', () {
    final scheme = buildColorScheme(otherSeed, Brightness.dark);
    final palette = PosterPalette.fromScheme(scheme);
    expect(palette.background, scheme.primaryContainer);
    expect(palette.title, scheme.onPrimaryContainer);
    expect(palette.lyrics, scheme.onPrimaryContainer);
    expect(palette.watermark, scheme.onPrimaryContainer);
    expect(palette.artist, scheme.primary);
  });
}
