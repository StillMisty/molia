import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'app_semantic_colors.dart';

/// 扫码登录二维码固定黑 / 白：扫码器不保证支持反色，不能跟随暗色主题。
///
/// 放主题基建而不是页面：颜色架构测试只允许 `lib/theme/app_theme.dart`
/// 出现原始颜色字面量。
const Color kQrModuleColor = Color(0xFF000000);
const Color kQrBackgroundColor = Color(0xFFFFFFFF);

/// 应用 ThemeData 的唯一构建入口：`ThemeProvider` 只产出 ColorScheme，
/// 其余组件默认值/语义扩展在这里集中展开，避免 main.dart 与各页面
/// 各自覆写造成「同语义不同颜色」。
///
/// 只做与配色契约相关的全局配置；具体组件的颜色覆写应优先靠 M3E 默认值。
///
/// [fontFamily] 为设置页「应用字体」选中的设备字体族名；为 null 时使用
/// [platformDefaultFontFamily]（Windows 启动时从系统 `MessageFont` 解析，
/// 中文系统即微软雅黑 UI），再没有才走 ThemeData 的平台默认排版。
///
/// 不能依赖 ThemeData 在 Windows 上的默认排版当作「系统字体」：它硬编码
/// Segoe UI（Material Redmond 排版），中文靠 DirectWrite 逐字回退，而
/// Flutter 不保证回退结果（flutter/flutter#103811）。[platformDefaultFontFallbacks]
/// 只跟系统默认字体一起注入；自定义字体不追加，保持用户选择。
ThemeData buildAppThemeData(
  ColorScheme scheme, {
  SystemUiOverlayStyle? systemUiOverlayStyle,
  String? fontFamily,
  String? platformDefaultFontFamily,
  List<String>? platformDefaultFontFallbacks,
}) {
  final useSystemFont =
      fontFamily == null && platformDefaultFontFamily != null;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // 自定义字体优先，其次系统 UI 字体，最后引擎默认（null）。
    fontFamily: fontFamily ?? platformDefaultFontFamily,
    fontFamilyFallback: useSystemFont ? platformDefaultFontFallbacks : null,
    appBarTheme: AppBarTheme(systemOverlayStyle: systemUiOverlayStyle),
    // 页面过渡沿用 ThemeData 默认值：Android = 预测返回 builder（跟手预览
    // 只由它插入的手势 detector 提供），iOS = Cupertino（边缘返回手势），
    // 桌面 = Zoom。框架默认 map 已覆盖本仓库的四个目标平台；不要再手写一份
    // 只含 Android/iOS 的 map——其余平台会回退到 Zoom，反而与默认值脱节。
    // 语义色（成功/警告）随方案亮度派生，供全 App 统一取用。
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.fromScheme(scheme),
    ],
  );
}

/// 从 Material [ThemeData] 派生 M3E 主题数据：应用内唯一 M3E 主题出口。
///
/// `M3EThemeData.fromMaterial` 只把 `textTheme` 映射进 baseline typeScale，
/// emphasized 用的是包内默认字体（没有字体族）。用户自定义「应用字体」后，
/// baseline 角色跟随、emphasized 角色（按钮 / 强调标题）却掉回引擎默认字体。
/// 这里把 [ThemeData.textTheme] `bodyMedium` 的字体族与回退链同步到两套
/// typeScale；颜色与组件主题仍然只来自 [ThemeData]，不引入第二个主题源。
/// （`ThemeData` 的平台排版通常已给出字体族，例如 Linux/Windows 的 Roboto，
/// 所以 emphasized 会拿到与 baseline 相同的族名，而不是包内默认的 null。）
M3EThemeData buildM3EThemeData(ThemeData theme) {
  final data = M3EThemeData.fromMaterial(theme);
  final body = theme.textTheme.bodyMedium;
  final fontFamily = body?.fontFamily;
  final fontFamilyFallback = body?.fontFamilyFallback;
  if (fontFamily == null &&
      (fontFamilyFallback == null || fontFamilyFallback.isEmpty)) {
    return data;
  }
  return data.copyWith(
    typography: data.typography.apply(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    ),
  );
}

/// 系统栏样式：透明系统栏 + 按方案亮度选择图标明暗（edge-to-edge）。
SystemUiOverlayStyle buildSystemUiOverlayStyle(ColorScheme scheme) {
  final brightness = scheme.brightness;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarIconBrightness:
        brightness == Brightness.dark ? Brightness.light : Brightness.dark,
    statusBarBrightness:
        brightness == Brightness.dark ? Brightness.dark : Brightness.light,
  );
}
