import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/lyrics_poster_preview_page.dart';
import 'package:molia/widgets/lyrics_selection_page.dart';
import 'package:molia/widgets/track_artwork.dart';

import '../support/fakes.dart';

const _trackId = TrackId('wy', '1');
const _originalCover = 'https://example.com/original.jpg';

Widget _host(
  Widget child, {
  required PlaybackProvider playback,
  CustomCoverStore? covers,
}) {
  return MultiProvider(
    providers: [
      Provider<CustomCoverStore>.value(value: covers ?? CustomCoverStore()),
      Provider<NotificationService>.value(value: NotificationService()),
      ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
    ],
    child: M3EMaterialApp(
      data: M3EThemeData.fromMaterial(ThemeData.light()),
      theme: ThemeData.light(),
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: const [Locale('zh')],
      home: Scaffold(body: child),
    ),
  );
}

List<LyricLine> _lyrics(List<String> texts) => [
  for (var i = 0; i < texts.length; i++)
    LyricLine(Duration(seconds: i), texts[i]),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  late PlaybackProvider playback;

  setUp(() {
    playback = buildTestPlaybackProvider();
  });

  tearDown(() => playback.dispose());

  Future<void> pumpPage(
    WidgetTester tester, {
    List<String> lines = const ['A', '', 'B', 'C', 'D'],
    CustomCoverStore? covers,
  }) async {
    await tester.pumpWidget(
      _host(
        LyricsSelectionPage(
          lyrics: _lyrics(lines),
          trackTitle: 'Title',
          artistName: 'Artist',
          albumCoverUrl: _originalCover,
          trackId: _trackId,
          isSynced: false,
        ),
        playback: playback,
        covers: covers,
      ),
    );
    await tester.pump();
  }

  Finder countPill(String value) => find.descendant(
    of: find.byKey(const Key('lyricsSelectionCount')),
    matching: find.text(value),
  );

  testWidgets('全选只选非空行；再点一次与取消全选同义', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('lyricsSelectAll')));
    await tester.pump();
    expect(countPill('4'), findsOneWidget, reason: '空行不参与全选');

    await tester.tap(find.byKey(const Key('lyricsSelectAll')));
    await tester.pump();
    expect(find.byKey(const Key('lyricsSelectionCount')), findsNothing);
  });

  testWidgets('范围选择：最后一次点选为锚点，点终点选中闭区间', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('B'));
    await tester.pump();
    expect(countPill('1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('lyricsRangeAction')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.selectionRangeHint), findsOneWidget);
    expect(find.text(l10n.selectionRangeCancel), findsOneWidget);

    await tester.tap(find.text('D'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(countPill('3'), findsOneWidget, reason: 'B / C / D 含两端');
    expect(find.text(l10n.selectionRangeAction), findsOneWidget);
  });

  testWidgets('再次点击范围选择取消：下一次点行恢复普通切换', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('lyricsRangeAction')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.selectionRangeCancel), findsOneWidget);

    await tester.tap(find.byKey(const Key('lyricsRangeAction')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.selectionRangeAction), findsOneWidget);

    await tester.tap(find.text('D'));
    await tester.pump();
    expect(countPill('2'), findsOneWidget, reason: '普通切换：B + D');
  });

  testWidgets('页头与海报输入共用同一份自定义展示封面', (tester) async {
    // 真实文件 I/O 必须走 runAsync：testWidgets 的假异步不会驱动真实
    // 事件循环，直接 await 目录 / 文件操作会挂住。
    final setup = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('molia_cover_');
      addTearDown(() => temp.delete(recursive: true));
      final covers = CustomCoverStore(supportDirectory: () async => temp);
      await covers.load();
      await covers.setTrackCover(
        _trackId,
        Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 1, 2, 3]),
      );
      return covers;
    });
    final covers = setup!;
    final expected = covers.resolution
        .displayForId(_trackId, originalUrl: _originalCover)
        .url;
    expect(expected, isNotNull, reason: '自定义封面应覆盖原始封面');

    await pumpPage(tester, covers: covers);

    final artwork = tester.widget<TrackArtwork>(
      find.byType(TrackArtwork).first,
    );
    expect(artwork.originalUrl, expected, reason: '页头用的是解析后的展示封面');

    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.tap(find.text(l10n.posterButtonLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final poster = tester.widget<LyricsPosterPreviewPage>(
      find.byType(LyricsPosterPreviewPage),
    );
    expect(poster.albumCoverUrl, expected, reason: '海报输入与页头同一个展示封面 URL');
  });
}
