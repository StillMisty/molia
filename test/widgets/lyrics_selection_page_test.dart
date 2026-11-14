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

  testWidgets('空选择：底栏是提示 + 复制全部，没有顶栏动作行', (tester) async {
    await pumpPage(tester);

    expect(find.text(l10n.lyricsSelectionHint), findsOneWidget);
    expect(find.byKey(const Key('lyricsCopyAll')), findsOneWidget);
    expect(find.byKey(const Key('lyricsSelectAll')), findsNothing);
    expect(find.byType(M3ESplitButton<String>), findsNothing);
  });

  testWidgets('全选只选中非空行；✕ 清空并回到空态', (tester) async {
    await pumpPage(tester);

    // 先选中一行，底栏才进入非空态（全选只在非空态出现）。
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('lyricsSelectAll')));
    await tester.pump();
    expect(find.text(l10n.copySelectedLines(4)), findsOneWidget);

    // 再次点击全选不会清空（已全选时按钮禁用）。
    await tester.tap(find.byKey(const Key('lyricsSelectAll')));
    await tester.pump();
    expect(find.text(l10n.copySelectedLines(4)), findsOneWidget);

    await tester.tap(find.byKey(const Key('lyricsDeselectAll')));
    await tester.pump();
    expect(find.text(l10n.lyricsSelectionHint), findsOneWidget);
  });

  testWidgets('长按终点：从最后一次点选的行选中闭区间', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('B'));
    await tester.pump();
    expect(find.text(l10n.copySelectedLines(1)), findsOneWidget);

    await tester.longPress(find.text('D'));
    await tester.pump();
    expect(
      find.text(l10n.copySelectedLines(3)),
      findsOneWidget,
      reason: 'B / C / D 含两端',
    );
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
