import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/widgets/cross_fade_swap.dart';
import 'package:molia/widgets/library_search_tab.dart';
import 'package:molia/widgets/search_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/provider_test_scope.dart';

import '../support/fakes.dart';

/// 资料库搜索 tab：浏览态与结果态之间用 CrossFadeSwap，AI 轮播用 AnimatedSize
/// 收起/展开；减弱动效时尺寸动画时长归零。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PlaybackProvider playback;
  late ChannelSelection selection;
  late SearchProvider search;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    playback = buildTestPlaybackProvider(facade: FakePlaybackFacade());
    selection = ChannelSelection(
      validKeys: () => const [],
      defaultKey: () => '',
    );
    search = SearchProvider(playback, selection: selection);
  });

  tearDown(() {
    search.dispose();
    selection.dispose();
    playback.dispose();
  });

  Future<void> pumpTab(WidgetTester tester, {bool reduceMotion = false}) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ProviderTestScope()..put<SearchProvider>(search);
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
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reduceMotion),
              child: const Scaffold(body: LibrarySearchTab()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('输入后浏览态换成结果态，清空后恢复；全程无溢出', (tester) async {
    await pumpTab(tester);
    expect(find.byType(CrossFadeSwap), findsOneWidget);
    expect(find.byType(SearchSection), findsNothing);

    await tester.enterText(find.byType(EditableText), '晴天');
    await tester.pump();
    // 过渡中间帧：轮播尺寸收缩与新内容交叉淡化同时进行。
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.takeException(), isNull);
    expect(find.byType(SearchSection), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byType(SearchSection), findsOneWidget);

    await tester.enterText(find.byType(EditableText), '');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.takeException(), isNull);
    // 离场层在过渡结束前仍带着旧的结果面，落定后才彻底移除。
    await tester.pumpAndSettle();
    expect(find.byType(SearchSection), findsNothing);
  });

  testWidgets('减弱动效：AnimatedSize 时长为零', (tester) async {
    await pumpTab(tester, reduceMotion: true);
    final size = tester.widget<AnimatedSize>(find.byType(AnimatedSize));
    expect(size.duration, Duration.zero);
  });
}
