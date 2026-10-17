import 'package:material_ui/material_ui.dart';

/// 全局主题的基础配色来源（与「播放时跟随封面」覆盖层正交）。
///
/// - [wallpaper]：系统壁纸配色（桌面优先壁纸图 seed，其次系统强调色），
///   不可用时回退自定义种子色；
/// - [custom]：用户自定义种子色（`ThemeProvider.seedColor`）。
enum ColorBaseSource { wallpaper, custom }

/// 消费面（桌面歌词 / 海报）的取色来源。
///
/// - [appTheme]：跟随应用当前 ColorScheme（已含基础配色与封面覆盖）；
/// - [artwork]：按当前曲目封面取色，无封面 / 取色不可用时回退应用主题。
enum SurfaceColorSource { appTheme, artwork }

/// 全 App 唯一的 ColorScheme 工厂：同 seed + 亮度必得同一方案。
///
/// ThemeProvider、桌面歌词、海报一律经此派生；禁止各处直接
/// `ColorScheme.fromSeed` 造成口径漂移（取色来源不同，派生规则必须同源）。
ColorScheme buildColorScheme(Color seed, Brightness brightness) =>
    ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

/// 消费面来源解析：封面方案缺失（无封面 / 省流未命中）时回退应用主题，
/// 不抛错、不闪变；调用方无需各自写回退分支。
ColorScheme resolveSurfaceScheme(
  SurfaceColorSource source, {
  required ColorScheme appScheme,
  ColorScheme? artworkScheme,
}) =>
    source == SurfaceColorSource.artwork
        ? (artworkScheme ?? appScheme)
        : appScheme;

/// 二维码等**机器可读表面**的固定配色。
///
/// 必须保持高对比黑白且**不随主题反转**（深色主题下白底黑码的相机解码率
/// 明显更高）；只给二维码渲染用，不参与任何 UI 取色。
const Color qrSurfaceColor = Color(0xFFFFFFFF);
const Color qrModuleColor = Color(0xFF000000);

/// 纯黑表面覆盖：仅深色模式生效，surface 系列全部覆盖为纯黑。
///
/// 与取色来源正交：任何来源（壁纸 / 封面 / 自定义 / 莫奈）都可叠加。
/// 同时黑掉 surfaceBright/surfaceTint：前者是「更亮的面」角色，后者是高程
/// 叠加色调，留色会让纯黑出现发灰的浮层；其余角色（inverseSurface、
/// outline 等）保持原样，保留弹层/边界的可辨识度。
ColorScheme applyPureBlackScheme(ColorScheme scheme) {
  if (scheme.brightness != Brightness.dark) return scheme;
  const black = Color(0xFF000000);
  return scheme.copyWith(
    surface: black,
    surfaceDim: black,
    surfaceBright: black,
    surfaceTint: black,
    surfaceContainerLowest: black,
    surfaceContainerLow: black,
    surfaceContainer: black,
    surfaceContainerHigh: black,
    surfaceContainerHighest: black,
  );
}
