import 'package:animations/animations.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import 'app_semantic_colors.dart';

/// 应用 ThemeData 的唯一构建入口：`ThemeProvider` 只产出 ColorScheme，
/// 其余组件默认值/语义扩展在这里集中展开，避免 main.dart 与各页面
/// 各自覆写造成「同语义不同颜色」。
///
/// 只做与配色契约相关的全局配置；具体组件的颜色覆写应优先靠 M3E 默认值。
/// [fontFamily] 为设备字体族名（设置页「应用字体」），null 时用系统默认字体；
/// 未覆盖的字形（如 CJK）由引擎逐字回退系统字体。
ThemeData buildAppThemeData(
  ColorScheme scheme, {
  SystemUiOverlayStyle? systemUiOverlayStyle,
  String? fontFamily,
}) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: fontFamily,
    appBarTheme: AppBarTheme(systemOverlayStyle: systemUiOverlayStyle),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: SharedAxisPageTransitionsBuilder(
          transitionType: SharedAxisTransitionType.horizontal,
        ),
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
