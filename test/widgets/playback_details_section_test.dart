import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback_feel.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/card_list_surface.dart';
import 'package:molia/widgets/settings/playback_details_section.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PlaybackProvider playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    playback = buildTestPlaybackProvider(facade: FakePlaybackFacade());
    await playback.preferencesReady;
  });

  tearDown(() => playback.dispose());

  Future<void> pumpSection(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const Scaffold(body: PlaybackDetailsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('播放细节卡只有两行，显示当前值与无障碍标签', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpSection(tester);

    // 一行选择 + 一行开关，没有第三条。
    expect(find.byType(CardListSurface), findsNWidgets(2));
    expect(find.byType(SettingsChoiceRow<PlaybackFadePreset>), findsOneWidget);
    expect(find.byType(SettingsSwitchTile), findsOneWidget);
    expect(find.byKey(const Key('settingsFadeItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSmartShuffleSwitch')), findsOneWidget);

    // 当前值：0.2 秒选中；智能随机默认开。
    final segmented = tester.widget<M3ESegmentedButton<PlaybackFadePreset>>(
      find.byType(M3ESegmentedButton<PlaybackFadePreset>),
    );
    expect(segmented.selected, {PlaybackFadePreset.ms200});
    final smartSwitch = tester.widget<M3ESwitch>(
      find.byKey(const Key('settingsSmartShuffleSwitch')),
    );
    expect(smartSwitch.value, isTrue);

    // 行标题 + 副标题进入无障碍标签（读屏能听到这一行做什么）。
    final fadeRow = find.descendant(
      of: find.byKey(const Key('settingsFadeItem')),
      matching: find.byType(CardListSurface),
    );
    final fadeLabel = tester.getSemantics(fadeRow).label;
    expect(fadeLabel, contains('淡入淡出'));
    expect(fadeLabel, contains('切歌不受影响'));

    expect(
      find.bySemanticsLabel(RegExp('少放最近听过的')),
      findsWidgets,
      reason: '开关行标题进入无障碍标签',
    );
    expect(
      find.bySemanticsLabel(RegExp('随机播放时少放最近听过的歌')),
      findsWidgets,
      reason: '开关行副标题进入无障碍标签',
    );
    semantics.dispose();
  });

  testWidgets('切换档位与开关立即写回 provider', (tester) async {
    await pumpSection(tester);

    await tester.tap(find.text('0.15 秒'));
    await tester.pumpAndSettle();
    expect(playback.fadePreset, PlaybackFadePreset.ms150);

    await tester.tap(find.byKey(const Key('settingsSmartShuffleSwitch')));
    await tester.pumpAndSettle();
    expect(playback.smartShuffleEnabled, isFalse);
  });
}
