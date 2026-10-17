import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/theme/animated_scheme.dart';
import 'package:molia/theme/app_semantic_colors.dart';
import 'package:molia/theme/app_theme.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 色彩基建测试：单一 ThemeData 构建入口、语义色扩展、方案色过渡、
/// 以及「appBuilder 无需重复包 Theme」的接线前提。
void main() {
  final light = ColorScheme.fromSeed(seedColor: Colors.blue);
  final dark = ColorScheme.fromSeed(
    seedColor: Colors.red,
    brightness: Brightness.dark,
  );

  group('buildAppThemeData', () {
    test('注册语义色扩展并跟随亮度', () {
      final lightData = buildAppThemeData(light);
      expect(lightData.colorScheme, light);
      expect(lightData.useMaterial3, isTrue);

      final lightSemantic = lightData.extension<AppSemanticColors>();
      expect(lightSemantic, isNotNull);
      expect(lightSemantic!.success, AppSemanticColors.fromScheme(light).success);

      final darkData = buildAppThemeData(dark);
      expect(darkData.brightness, Brightness.dark);
      final darkSemantic = darkData.extension<AppSemanticColors>()!;
      expect(darkSemantic.success, AppSemanticColors.fromScheme(dark).success);
      // 明暗两套语义色不应相同（暗色需要更亮的前景）。
      expect(darkSemantic.success, isNot(lightSemantic.success));
    });

    test('语义色与方案色解耦：换种子不改变状态色', () {
      final purple = ColorScheme.fromSeed(seedColor: Colors.purple);
      final a = AppSemanticColors.fromScheme(light);
      final b = AppSemanticColors.fromScheme(purple);
      expect(a.success, b.success);
      expect(a.warningContainer, b.warningContainer);
    });

    test('语义色 lerp 覆盖全部字段', () {
      final a = AppSemanticColors.fromScheme(light);
      final b = AppSemanticColors.fromScheme(dark);
      final mid = a.lerp(b, 0.5);
      expect(mid.success, isNot(a.success));
      expect(mid.warning, isNot(a.warning));
      expect(a.lerp(b, 0.0).success, a.success);
      expect(a.lerp(b, 1.0).success, b.success);
    });

    test('系统栏样式图标明暗跟随方案亮度', () {
      expect(
        buildSystemUiOverlayStyle(light).statusBarIconBrightness,
        Brightness.dark,
      );
      expect(
        buildSystemUiOverlayStyle(dark).statusBarIconBrightness,
        Brightness.light,
      );
    });

    test('Android 页面过渡保留预测返回 builder', () {
      final data = buildAppThemeData(light);
      // 跟手预览只由该 builder 插入的手势 detector 提供（换成普通 builder
      // 会静默退化成「能返回、无预览」，实测见
      // test/theme/predictive_back_page_transitions_test.dart）；
      // cupertino builder 同理是 iOS 边缘返回手势的来源。
      expect(
        data.pageTransitionsTheme.builders[TargetPlatform.android],
        isA<PredictiveBackPageTransitionsBuilder>(),
      );
      expect(
        data.pageTransitionsTheme.builders[TargetPlatform.iOS],
        isA<CupertinoPageTransitionsBuilder>(),
      );
    });

    test('fontFamily 注入 textTheme 并传递到 M3E typeScale', () {
      final data = buildAppThemeData(light, fontFamily: 'Noto Sans CJK SC');
      expect(data.textTheme.bodyMedium?.fontFamily, 'Noto Sans CJK SC');
      expect(
        M3EThemeData.fromMaterial(data).typeScale.bodyMedium.fontFamily,
        'Noto Sans CJK SC',
      );

      // 未指定时沿用 ThemeData 默认字体族（不注入自定义字体）。
      expect(
        buildAppThemeData(light).textTheme.bodyMedium?.fontFamily,
        isNot('Noto Sans CJK SC'),
      );
    });

    test('未自定义字体时使用平台默认 UI 字体，自定义字体优先', () {
      // 平台默认 UI 字体由启动时解析（Windows 读系统窗口字体；其它平台为
      // null 走引擎默认）——主题层只做「自定义 > 平台默认」的优先级。
      final data = buildAppThemeData(
        light,
        platformDefaultFontFamily: 'Microsoft YaHei UI',
      );
      expect(data.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei UI');
      // M3E 侧同步（typeScale 从 ThemeData.textTheme 映射）。
      expect(
        M3EThemeData.fromMaterial(data).typeScale.bodyMedium.fontFamily,
        'Microsoft YaHei UI',
      );

      // 自定义字体优先：平台默认不再覆盖用户选择。
      final custom = buildAppThemeData(
        light,
        fontFamily: 'Noto Sans CJK SC',
        platformDefaultFontFamily: 'Microsoft YaHei UI',
      );
      expect(custom.textTheme.bodyMedium?.fontFamily, 'Noto Sans CJK SC');

      // 平台默认缺失（非 Windows / 解析失败）时保持引擎默认。
      expect(
        buildAppThemeData(light).textTheme.bodyMedium?.fontFamily,
        isNot('Microsoft YaHei UI'),
      );
    });
  });

  group('AnimatedSchemeBuilder', () {
    testWidgets('首个方案变化直接跳变（不播启动动画）', (tester) async {
      ColorScheme? seen;
      Widget build(ColorScheme scheme) => AnimatedSchemeBuilder(
            scheme: scheme,
            builder: (context, animated) {
              seen = animated;
              return const SizedBox();
            },
          );

      await tester.pumpWidget(build(light));
      expect(seen, light);

      await tester.pumpWidget(build(dark));
      expect(seen, dark);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('后续变化先插值、动画结束后到达目标方案', (tester) async {
      var scheme = light;
      final seen = <Color>[];
      late StateSetter setState;
      final target = ColorScheme.fromSeed(seedColor: Colors.green);

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setter) {
            setState = setter;
            return AnimatedSchemeBuilder(
              scheme: scheme,
              builder: (context, animated) {
                seen.add(animated.primary);
                return const SizedBox();
              },
            );
          },
        ),
      );

      // 第一次变化消耗「首变跳变」。
      setState(() => scheme = ColorScheme.fromSeed(seedColor: Colors.red));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);

      // 第二次变化播放过渡：首帧为起点色，结束后为目标色。
      setState(() => scheme = target);
      await tester.pump();
      expect(seen.last, isNot(target.primary));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(seen.last, target.primary);
    });

    testWidgets('系统关闭动画时直接跳变', (tester) async {
      var scheme = light;
      ColorScheme? seen;
      late StateSetter setState;
      final target = ColorScheme.fromSeed(seedColor: Colors.teal);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setter) {
              setState = setter;
              return AnimatedSchemeBuilder(
                scheme: scheme,
                builder: (context, animated) {
                  seen = animated;
                  return const SizedBox();
                },
              );
            },
          ),
        ),
      );

      setState(() => scheme = target);
      await tester.pump();
      expect(seen, target);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('M3EMaterialApp 接线前提', () {
    testWidgets('appBuilder 上下文可读到 MaterialApp theme（无需重复包 Theme）',
        (tester) async {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      final themedData = buildAppThemeData(scheme);
      ColorScheme? observed;
      AppSemanticColors? semantic;

      await tester.pumpWidget(
        M3EMaterialApp(
          data: M3EThemeData.fromMaterial(themedData),
          theme: themedData,
          darkTheme: themedData,
          autoTheming: false,
          dynamicColoring: false,
          appBuilder: (context, child) => MediaQuery(
            data: MediaQuery.of(context),
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              observed = theme.colorScheme;
              semantic = theme.extension<AppSemanticColors>();
              return const SizedBox();
            },
          ),
        ),
      );

      // M3E 的 M3EResolvedTheme 会把 ColorScheme 经 M3EColorScheme 重投影
      //（*Fixed 角色会折叠），但主要角色与扩展必须保留。
      expect(observed, isNotNull);
      expect(observed!.primary, scheme.primary);
      expect(observed!.surface, scheme.surface);
      expect(observed!.onSurface, scheme.onSurface);
      expect(observed!.surfaceContainerHighest, scheme.surfaceContainerHighest);
      expect(semantic, isNotNull);
      expect(semantic!.success, AppSemanticColors.fromScheme(scheme).success);
    });
  });
}
