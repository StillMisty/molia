import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import 'app_semantic_colors.dart';

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
    // Android 页面过渡必须选框架的预测返回 builder：跟手预览只由它插入的
    // 手势 detector 提供，没有观察者接管时 `WidgetsBinding` 会把返回手势
    // 退化成普通返回（能出栈、全程无预览）。换成任何普通 builder
    // （共享轴过渡这类纯动画 builder 同样如此）都会静默丢掉这套预览。
    pageTransitionsTheme: PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: const PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
      },
    ),
    // 语义色（成功/警告）随方案亮度派生，供全 App 统一取用。
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.fromScheme(scheme),
    ],
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
