import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import 'app_semantic_colors.dart';

/// 应用 ThemeData 的唯一构建入口：`ThemeProvider` 只产出 ColorScheme，
/// 其余组件默认值/语义扩展在这里集中展开，避免 main.dart 与各页面
/// 各自覆写造成「同语义不同颜色」。
///
/// 只做与配色契约相关的全局配置；具体组件的颜色覆写应优先靠 M3E 默认值。
/// [fontFamily] 为设备字体族名（设置页「应用字体」），null 时用平台默认 UI
/// 字体（[platformDefaultFontFamily]，见 `SystemFontsService`）；未覆盖的
/// 字形（如 CJK）由引擎逐字回退系统字体。
ThemeData buildAppThemeData(
  ColorScheme scheme, {
  SystemUiOverlayStyle? systemUiOverlayStyle,
  String? fontFamily,
  String? platformDefaultFontFamily,
}) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // 自定义字体优先；否则用启动时解析出的平台默认 UI 字体（Windows =
    // 系统窗口字体，中文系统即微软雅黑；其它平台为 null，走引擎默认）。
    fontFamily: fontFamily ?? platformDefaultFontFamily,
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
