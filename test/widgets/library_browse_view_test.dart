import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/library_browse.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/cross_fade_swap.dart';
import 'package:molia/widgets/library_browse_view.dart';

import '../support/cover_test_support.dart';

BrowseTrack _track(String id, {String artist = '曲目歌手'}) => BrowseTrack(
  sourceKey: 'wy',
  songId: id,
  title: '歌曲 $id',
  artist: artist,
  album: '专辑 A',
  durationMs: 200000,
);

Widget _host({bool reduceMotion = false}) => M3EMaterialApp(
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
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: Scaffold(
        body: withCoverStore(
          LibraryBrowseView(
            groups: [
              LibraryBrowseGroup(
                key: 'album-a',
                title: '专辑 A',
                subtitle: '歌手 A',
                tracks: [_track('1')],
              ),
              const LibraryBrowseGroup(
                key: 'album-b',
                title: '专辑 B',
                subtitle: '歌手 B',
                tracks: [],
              ),
            ],
            modeName: 'albums',
            query: '',
            emptyTitle: '还没有专辑',
            emptyBody: '收藏、列表和本地歌曲会出现在这里',
            searchEmpty: '没有匹配',
            selectHint: '选择一个专辑',
            resetSignature: 'albums||added',
            isFavorite: (_) => false,
            onPlay: (_, _, {shuffle = false}) async {},
            onPlayTrack: (_) async {},
            onAdd: (_) async {},
            onToggleFavorite: (_) async {},
            canRefreshLocal: (_) => false,
            onRefreshLocal: (_) async {},
            onSwap: (_) async {},
          ),
        ),
      ),
    ),
  ),
);

/// CrossFadeSwap 的离场层 `IgnorePointer`（key 是代次 int）。
Finder _outgoingLayer() => find.descendant(
  of: find.byType(CrossFadeSwap),
  matching: find.byWidgetPredicate(
    (widget) => widget is IgnorePointer && widget.key is ValueKey<int>,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('专辑 / 歌手行在列表与详情都显示副标题', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('歌手 A'), findsOneWidget, reason: '列表行显示副标题');
    await tester.tap(find.text('专辑 A'));
    await tester.pumpAndSettle();
    expect(find.text('歌手 A'), findsOneWidget, reason: '详情标题下保留副标题');
  });

  testWidgets('单栏列表→详情用过渡层：旧层不可点，落定后只剩一层', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(_outgoingLayer(), findsNothing);

    await tester.tap(find.text('专辑 A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(find.text('专辑 A'), findsNWidgets(2), reason: '过渡期间新旧两层同时在场');
    expect(
      tester.widget<IgnorePointer>(_outgoingLayer()).ignoring,
      isTrue,
      reason: '旧层必须停止接收点击',
    );

    await tester.pumpAndSettle();
    expect(_outgoingLayer(), findsNothing);
    expect(find.text('专辑 A'), findsOneWidget);
  });

  testWidgets('减弱动效时切详情直接落定，不保留过渡层', (tester) async {
    await tester.pumpWidget(_host(reduceMotion: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('专辑 A'));
    await tester.pump();

    expect(_outgoingLayer(), findsNothing);
    expect(find.text('歌手 A'), findsOneWidget);
  });
}
