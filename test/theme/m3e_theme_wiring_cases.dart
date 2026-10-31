import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/widgets/m3e_page_route.dart';

/// 主题接线测试：验证 App 壳经 `M3EMaterialApp` 承载后，
/// ThemeProvider 的 ColorScheme 能正确映射为 M3EThemeData，且
/// material_ui `Theme.of` 与 M3E `M3ETheme.of` 颜色保持一致。
void main() {
  group('M3EThemeData.fromMaterial', () {
    test('light ColorScheme 的颜色角色与亮度完整映射', () {
      final material = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      );
      final data = M3EThemeData.fromMaterial(material);

      expect(data.brightness, Brightness.light);
      expect(data.colorScheme.brightness, Brightness.light);
      expect(data.colorScheme.primary, material.colorScheme.primary);
      expect(data.colorScheme.onPrimary, material.colorScheme.onPrimary);
      expect(data.colorScheme.primaryContainer,
          material.colorScheme.primaryContainer);
      expect(data.colorScheme.surface, material.colorScheme.surface);
      expect(data.colorScheme.onSurface, material.colorScheme.onSurface);
      expect(data.colorScheme.surfaceContainerHighest,
          material.colorScheme.surfaceContainerHighest);
      expect(data.useMaterial3, isTrue);
    });

    test('dark ColorScheme 映射 + 文本样式字体族保留 + 实例缓存', () {
      final material = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
        ),
        textTheme: const TextTheme(
          titleMedium: TextStyle(fontFamily: 'Montserrat', fontSize: 17),
        ),
      );
      final data = M3EThemeData.fromMaterial(material);

      expect(data.brightness, Brightness.dark);
      expect(data.colorScheme.brightness, Brightness.dark);
      expect(data.colorScheme.primary, material.colorScheme.primary);
      expect(data.colorScheme.onSurface, material.colorScheme.onSurface);
      expect(data.typeScale.titleMedium.fontFamily, 'Montserrat');
      expect(data.typeScale.titleMedium.fontSize, 17);

      // 按 ThemeData 实例缓存：同一实例重复映射返回同一 M3EThemeData。
      expect(identical(M3EThemeData.fromMaterial(material), data), isTrue);
    });
  });

  group('M3EMaterialApp 壳接线', () {
    testWidgets('冒烟：M3ETheme.of 不抛错且 primary 与 ColorScheme 一致', (tester) async {
      final colorScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
      late M3EThemeData m3eData;
      late ColorScheme materialScheme;

      await tester.pumpWidget(
        M3EMaterialApp(
          data: M3EThemeData.fromMaterial(
            ThemeData(colorScheme: colorScheme),
          ),
          home: Builder(
            builder: (context) {
              m3eData = M3ETheme.of(context);
              materialScheme = Theme.of(context).colorScheme;
              return const SizedBox();
            },
          ),
        ),
      );

      expect(m3eData.colorScheme.primary, colorScheme.primary);
      expect(m3eData.brightness, colorScheme.brightness);
      expect(materialScheme.primary, colorScheme.primary);
    });

    testWidgets('ColorScheme 变化时壳重建，M3E 与 material_ui 主题同步跟随', (tester) async {
      Brightness? m3eBrightness;
      Color? m3ePrimary;
      Brightness? materialBrightness;
      Color? materialPrimary;

      Widget buildShell(ColorScheme scheme) {
        final themedData = ThemeData(colorScheme: scheme, useMaterial3: true);
        return M3EMaterialApp(
          data: M3EThemeData.fromMaterial(themedData),
          theme: themedData,
          darkTheme: themedData,
          autoTheming: false,
          dynamicColoring: false,
          home: Builder(
            builder: (context) {
              final data = M3ETheme.of(context);
              m3eBrightness = data.brightness;
              m3ePrimary = data.colorScheme.primary;
              final materialTheme = Theme.of(context);
              materialBrightness = materialTheme.brightness;
              materialPrimary = materialTheme.colorScheme.primary;
              return const SizedBox();
            },
          ),
        );
      }

      final light = ColorScheme.fromSeed(seedColor: Colors.blue);
      await tester.pumpWidget(buildShell(light));
      expect(m3ePrimary, light.primary);
      expect(m3eBrightness, Brightness.light);
      expect(materialPrimary, light.primary);
      expect(materialBrightness, Brightness.light);

      final dark = ColorScheme.fromSeed(
        seedColor: Colors.red,
        brightness: Brightness.dark,
      );
      await tester.pumpWidget(buildShell(dark));
      await tester.pump();
      expect(m3ePrimary, dark.primary);
      expect(m3eBrightness, Brightness.dark);
      expect(materialPrimary, dark.primary);
      expect(materialBrightness, Brightness.dark);
    });

    testWidgets('autoTheming=false 时不跟随系统亮度（亮度由 ThemeProvider 决定）',
        (tester) async {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
      final themedData = ThemeData(colorScheme: scheme, useMaterial3: true);
      Brightness? resolved;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(platformBrightness: Brightness.dark),
          child: M3EMaterialApp(
            data: M3EThemeData.fromMaterial(themedData),
            theme: themedData,
            autoTheming: false,
            dynamicColoring: false,
            home: Builder(
              builder: (context) {
                resolved = M3ETheme.of(context).brightness;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(resolved, Brightness.light);
    });

    testWidgets('appBuilder 生效，navigatorKey / scaffoldMessengerKey 透传',
        (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
      var appBuilderCalled = false;

      await tester.pumpWidget(
        M3EMaterialApp(
          data: M3EThemeData.light(),
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          appBuilder: (context, child) {
            appBuilderCalled = true;
            return KeyedSubtree(
              key: const Key('m3e-app-builder'),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const SizedBox(),
        ),
      );

      expect(appBuilderCalled, isTrue);
      expect(find.byKey(const Key('m3e-app-builder')), findsOneWidget);
      expect(navigatorKey.currentState, isNotNull);
      expect(scaffoldMessengerKey.currentState, isNotNull);
    });

    testWidgets('M3EPageRoute 在路由内再挂 M3ETheme，页面不依赖 App 级 DefaultTextStyle',
        (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
      final themedData = ThemeData(colorScheme: scheme, useMaterial3: true);
      final data = M3EThemeData.fromMaterial(themedData);
      late DefaultTextStyle homeDefaultTextStyle;

      await tester.pumpWidget(
        M3EMaterialApp(
          data: data,
          theme: themedData,
          darkTheme: themedData,
          navigatorKey: navigatorKey,
          autoTheming: false,
          dynamicColoring: false,
          // home 不走 M3EPageRoute（初始路由由 MaterialApp 创建），
          // 与 App 壳一样显式包一层路由级主题。这里同时捕获 home 内的
          // DefaultTextStyle，防止 home 包装被回退成直接挂 MyApp。
          home: M3ERouteTheme(
            builder: (context) {
              homeDefaultTextStyle = DefaultTextStyle.of(context);
              return const Scaffold(body: Center(child: Text('home')));
            },
          ),
        ),
      );

      // Navigator 的 context 在 App 级 M3ETheme 之下，取到的就是 chrome 使用的
      // DefaultTextStyle；页面内若还是同一个实例，说明路由没有自己的主题层。
      final appDefaultTextStyle =
          DefaultTextStyle.of(navigatorKey.currentContext!);
      expect(
        identical(homeDefaultTextStyle, appDefaultTextStyle),
        isFalse,
        reason: 'home 初始路由也必须依赖 M3ERouteTheme 内的 DefaultTextStyle，'
            '不能退回 App 级',
      );
      late DefaultTextStyle pageDefaultTextStyle;
      late M3EThemeData pageTheme;

      navigatorKey.currentState!.push(
        M3EPageRoute<void>(
          builder: (context) {
            pageDefaultTextStyle = DefaultTextStyle.of(context);
            pageTheme = M3ETheme.of(context);
            return const Scaffold(body: Center(child: Text('page')));
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(
        identical(pageDefaultTextStyle, appDefaultTextStyle),
        isFalse,
        reason: '页面必须依赖路由内的 DefaultTextStyle，'
            '不能退回 App 级（预测返回退场 + 主题重建会触发断言）',
      );
      expect(pageTheme.colorScheme.primary, scheme.primary);
      expect(pageTheme.brightness, scheme.brightness);
    });
  });
}
