import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import 'app_semantic_colors.dart';

/// Windows 未自定义字体时的默认族与回退栈（详见 [buildAppThemeData]）。
const String _windowsDefaultFontFamily = 'Microsoft YaHei UI';
const List<String> _windowsDefaultFontFallback = <String>[
  'Microsoft YaHei',
  'Segoe UI',
];

/// 应用 ThemeData 的唯一构建入口：`ThemeProvider` 只产出 ColorScheme，
/// 其余组件默认值/语义扩展在这里集中展开，避免 main.dart 与各页面
/// 各自覆写造成「同语义不同颜色」。
///
/// 只做与配色契约相关的全局配置；具体组件的颜色覆写应优先靠 M3E 默认值。
/// [fontFamily] 为设备字体族名（设置页「应用字体」），null 时用系统默认字体；
/// 未覆盖的字形（如 CJK）由引擎逐字回退系统字体。
/// [platform] 仅用于测试注入（默认 [defaultTargetPlatform]）。
ThemeData buildAppThemeData(
  ColorScheme scheme, {
  SystemUiOverlayStyle? systemUiOverlayStyle,
  String? fontFamily,
  TargetPlatform? platform,
}) {
  // Windows 未自定义字体时显式给「微软雅黑」字体栈：引擎默认从 Segoe UI
  // 起手（Material 的 Redmond 排版），中文经回退链拿到的不是系统 UI 字体
  // （微软雅黑），与系统其它窗口观感不一致（用户反馈）。自定义字体优先，
  // 其它平台保持引擎默认（其回退链已是系统 UI 字体）。
  final effectivePlatform = platform ?? defaultTargetPlatform;
  final useWindowsDefault =
      fontFamily == null && effectivePlatform == TargetPlatform.windows;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: fontFamily ??
        (useWindowsDefault ? _windowsDefaultFontFamily : null),
    fontFamilyFallback: useWindowsDefault ? _windowsDefaultFontFallback : null,
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
