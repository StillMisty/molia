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

    test('buildM3EThemeData 把应用字体同步到 baseline 与 emphasized', () {
      // M3EThemeData.fromMaterial 只映射 baseline：emphasized 会掉回包内
      // 默认字体。buildM3EThemeData 必须两套都带应用字体（按钮 / 强调标题
      // 也跟着用户选择走）。
      final custom = buildAppThemeData(light, fontFamily: 'Noto Sans CJK SC');
      final m3e = buildM3EThemeData(custom);
      expect(m3e.typeScale.bodyMedium.fontFamily, 'Noto Sans CJK SC');
      expect(
        m3e.typography.emphasized.bodyLarge.fontFamily,
        'Noto Sans CJK SC',
      );
      expect(
          m3e.typography.emphasized.labelLarge.fontFamily, 'Noto Sans CJK SC');

      // 颜色 / 组件主题仍然只来自 ThemeData（不引入第二个主题源）。
      final mapped = M3EThemeData.fromMaterial(custom);
      expect(m3e.colorScheme.primary, mapped.colorScheme.primary);
      expect(m3e.colorScheme.surface, mapped.colorScheme.surface);

      // 系统默认字体的缺字回退链同样要覆盖 emphasized。
      final system = buildAppThemeData(
        light,
        platformDefaultFontFamily: 'Microsoft YaHei UI',
        platformDefaultFontFallbacks: const ['Segoe UI', 'Microsoft YaHei'],
      );
      final systemM3E = buildM3EThemeData(system);
      expect(
        systemM3E.typography.emphasized.bodyMedium.fontFamily,
        'Microsoft YaHei UI',
      );
      expect(
        systemM3E.typography.emphasized.bodyMedium.fontFamilyFallback,
        const ['Segoe UI', 'Microsoft YaHei'],
      );

      // 没有显式字体覆盖时，基线字体仍是 ThemeData 的平台排版字体
      // （Linux/Windows 默认 Roboto），两套 scale 保持一致即可。
      final plain = buildAppThemeData(light);
      final plainFamily = plain.textTheme.bodyMedium?.fontFamily;
      final plainM3E = buildM3EThemeData(plain);
      expect(plainM3E.typeScale.bodyMedium.fontFamily, plainFamily);
      expect(plainM3E.typography.emphasized.bodyMedium.fontFamily, plainFamily);
    });

    test('系统默认字体优先于平台排版，自定义字体优先于系统字体', () {
      // 未注入系统字体时仍走 ThemeData 的平台默认排版（Windows = Segoe UI）；
      // Windows 的真实系统字体由启动时读取 MessageFont 后显式注入。
      final data = buildAppThemeData(light);
      final defaultFamily =
          ThemeData(colorScheme: light).textTheme.bodyMedium?.fontFamily;
      expect(data.textTheme.bodyMedium?.fontFamily, defaultFamily);
      expect(data.textTheme.bodyMedium?.fontFamilyFallback, isNull);
      // M3E 侧同步（typeScale 从 ThemeData.textTheme 映射）。
      expect(
        M3EThemeData.fromMaterial(data).typeScale.bodyMedium.fontFamily,
        defaultFamily,
      );

      // 系统默认字体 + 缺字回退链落到两套主题。
      final system = buildAppThemeData(
        light,
        platformDefaultFontFamily: 'Microsoft YaHei UI',
        platformDefaultFontFallbacks: const ['Segoe UI', 'Microsoft YaHei'],
      );
      expect(system.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei UI');
      expect(
        system.textTheme.bodyMedium?.fontFamilyFallback,
        const ['Segoe UI', 'Microsoft YaHei'],
      );
      final systemM3E = M3EThemeData.fromMaterial(system).typeScale.bodyMedium;
      expect(systemM3E.fontFamily, 'Microsoft YaHei UI');
      expect(
        systemM3E.fontFamilyFallback,
        const ['Segoe UI', 'Microsoft YaHei'],
      );

      // 自定义字体优先，且不追加系统字体的回退链（尊重用户选择）。
      final custom = buildAppThemeData(
        light,
        fontFamily: 'Noto Sans CJK SC',
        platformDefaultFontFamily: 'Microsoft YaHei UI',
        platformDefaultFontFallbacks: const ['Segoe UI', 'Microsoft YaHei'],
      );
      expect(custom.textTheme.bodyMedium?.fontFamily, 'Noto Sans CJK SC');
      expect(custom.textTheme.bodyMedium?.fontFamilyFallback, isNull);
      expect(
        M3EThemeData.fromMaterial(custom).typeScale.bodyMedium.fontFamily,
        'Noto Sans CJK SC',
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
