import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/lyrics_display/desktop_lyrics_settings_page.dart';
import 'package:molia/pages/lyrics_display/lyrics_content_settings_page.dart';
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/utils/snapshot_source.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_display/lyrics_output.dart';

import '../support/provider_test_scope.dart';
import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LyricsDisplaySettings settings;
  late ThemeProvider theme;
  late ProviderTestScope scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final registry = testSettingsRegistry();
    settings = LyricsDisplaySettings(settings: registry);
    scope = ProviderTestScope(registry: registry);
    scope.put<LyricsDisplaySettings>(settings);
    theme = scope.theme;
    await theme.preferencesReady;
  });

  tearDown(() {
    settings.dispose();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    required _FakeLyricsDisplay display,
  }) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    scope.put<LyricsDisplayProvider>(display);
    await tester.pumpWidget(
      scope.wrap(
        M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('歌词与输出页合并通知与车机歌词，细节收进高级', (tester) async {
    await pump(
      tester,
      const LyricsContentSettingsPage(),
      display: _FakeLyricsDisplay(),
    );

    // 两个总开关在首层。
    expect(find.byKey(const Key('lyricsNotificationSwitch')), findsOneWidget);
    expect(find.byKey(const Key('lyricsBluetoothSwitch')), findsOneWidget);
    expect(find.byKey(const Key('lyricsBluetoothA2dpSwitch')), findsOneWidget);
    // 目标 / 格式 / 暂停行为不在首层。
    expect(find.text('显示在'), findsNothing);
    expect(find.text('格式'), findsNothing);

    final advanced = find.byKey(const Key('lyricsSystemMediaAdvancedItem'));
    await tester.ensureVisible(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();

    // 高级页才出现两组输出细节。
    expect(find.text('显示在'), findsNWidgets(2));
    expect(find.text('格式'), findsNWidgets(2));
    expect(find.text('暂停时'), findsNWidgets(2));
  });

  testWidgets('桌面歌词页只留日常项，行为细节收进高级', (tester) async {
    await pump(
      tester,
      const DesktopLyricsSettingsPage(),
      display: _FakeLyricsDisplay(),
    );

    // 主页面仍有字号、透明度、颜色与隐藏暂停。
    expect(find.text('字号'), findsOneWidget);
    expect(find.text('透明度'), findsOneWidget);
    expect(find.text('当前行颜色'), findsOneWidget);
    expect(find.text('暂停时隐藏'), findsOneWidget);
    // 控制条按钮与冻结不在主页面。
    expect(find.text('控制条按钮'), findsNothing);
    expect(find.text('息屏时暂停更新'), findsNothing);

    final advanced = find.byKey(const Key('lyricsDesktopAdvancedItem'));
    await tester.ensureVisible(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();

    expect(find.text('控制条按钮'), findsOneWidget);
    expect(find.text('息屏时暂停更新'), findsOneWidget);
    expect(find.text('行切换动画'), findsOneWidget);
    expect(find.text('上一首'), findsOneWidget);
  });
}

class _FakeLyricsDisplay implements LyricsDisplayProvider {
  final SnapshotSignal _signal = SnapshotSignal();

  @override
  LyricsDisplayState get state => const LyricsDisplayState(
    capabilities: {
      LyricsOutputIds.desktop: LyricsOutputCapability.ready,
      LyricsOutputIds.media: LyricsOutputCapability.ready,
    },
  );

  @override
  Listenable get changes => _signal;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试替身不应调用 ${invocation.memberName}');
}
