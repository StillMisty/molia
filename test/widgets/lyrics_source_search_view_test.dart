/// 歌词换源视图：来源来自注册表 / 测试注入，未登录 B 站只提示不发请求，
/// 选中结果按来源 provider 名写入手动歌词。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/source.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics/lyrics_source_strategy.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/app_search_bar.dart';
import 'package:molia/widgets/lyrics_source_search_view.dart';
import 'package:molia/widgets/source_swap/source_swap_chrome.dart';
import 'package:molia/widgets/track_row.dart';

/// 记录手动选择写入了哪个 provider（不落真实缓存）。
class _FakeLyricsService extends LyricsService {
  _FakeLyricsService() : super(providers: const []);

  final List<({String trackId, String provider})> saved = [];

  @override
  Future<void> saveLyrics(
    String trackId,
    String lyric,
    String providerName, {
    String? translation,
    String? roma,
    String? lxlyric,
  }) async {
    saved.add((trackId: trackId, provider: providerName));
  }
}

class _FakeLyricProvider extends LyricProvider {
  _FakeLyricProvider(
    this.name, {
    this.matches = const [],
    this.payload,
    this.fetchError,
  });

  @override
  final String name;

  final List<SongMatch> matches;
  LyricsPayload? payload;
  Object? fetchError;
  int searchCalls = 0;
  int fetchCalls = 0;
  int? lastSearchLimit;

  /// 非空时取词挂起，直到测试放行（验证忙碌锁 / 预览加载态）。
  Completer<void>? fetchGate;

  /// 按 songId 覆盖 payload（预览与确认分别取不同结果时用）。
  final Map<String, LyricsPayload?> payloads = {};

  /// 实际取词的 match id（验证写入的是确认时的旧选中项）。
  final List<String> fetchedSongIds = [];

  @override
  Future<SongMatch?> search(String title, String artist) async {
    final results = await searchMultiple(title, artist, limit: 1);
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) async {
    searchCalls++;
    lastSearchLimit = limit;
    return matches.take(limit).toList();
  }

  @override
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async {
    fetchCalls++;
    fetchedSongIds.add(match.songId);
    final gate = fetchGate;
    if (gate != null) await gate.future;
    if (fetchError != null) throw fetchError!;
    return payloads.containsKey(match.songId)
        ? payloads[match.songId]
        : payload;
  }

  @override
  Future<String?> fetchLyric(String songId) async => payload?.lyric;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpView(
    WidgetTester tester, {
    required List<LyricsSourceStrategy> sources,
    required LyricsProvider lyricsProvider,
    Set<String>? enabledChannelKeys,
    List<SourceDescriptor> sourceDescriptors = const [],
    List<String>? channelOrder,
    Locale locale = const Locale('zh'),
  }) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      Provider<NotificationService>.value(
        value: NotificationService(),
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: [locale],
          home: Scaffold(
            body: LyricsSourceSearchView(
              initialTrackTitle: '晴天',
              initialArtistName: '周杰伦',
              trackId: 'bili:1',
              lyricsProvider: lyricsProvider,
              sources: sources,
              sourceDescriptors: sourceDescriptors,
              enabledChannelKeys: enabledChannelKeys,
              channelOrder: channelOrder,
            ),
          ),
        ),
      ),
    );
    // 首帧 post-frame 才发起搜索；等结果与列表落定。
    await tester.pump();
    await tester.pumpAndSettle();
  }

  LyricsSourceStrategy biliStrategy(_FakeLyricProvider provider) {
    return LyricsSourceStrategy(
      channelKey: 'bili',
      provider: provider,
      autoFallback: false,
      unavailable: () => LyricsSourceUnavailable.biliLoginRequired,
    );
  }

  bool rowSelected(WidgetTester tester, String title) {
    final row = tester.widget<TrackRow>(
      find.ancestor(of: find.text(title), matching: find.byType(TrackRow)),
    );
    return row.model.selected;
  }

  testWidgets('未登录 B 站：登录提示内联在 B 站 section header，且不发搜索请求', (tester) async {
    final qq = _FakeLyricProvider('qq');
    final bili = _FakeLyricProvider('bili');
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
        biliStrategy(bili),
      ],
      lyricsProvider: lyricsProvider,
    );

    final biliHeader = find.byKey(const ValueKey('lyricsSourceSection-bili'));
    expect(biliHeader, findsOneWidget, reason: '无结果也要保留 B 站标题挂提示');
    expect(
      find.descendant(of: biliHeader, matching: find.text('登录后可优先使用 B 站字幕歌词')),
      findsOneWidget,
    );
    expect(find.byType(SourceSwapNotice), findsNothing, reason: '登录提示不再走全局状态条');
    expect(
      find.text('暂时没找到歌词，换个来源试试？'),
      findsOneWidget,
      reason: 'header-only 时下方仍给空态',
    );
    expect(qq.searchCalls, 1);
    expect(bili.searchCalls, 0, reason: '不可用来源不发请求');
  });

  testWidgets('英文 B 站标题右侧用短提示，不占满整行', (tester) async {
    final qq = _FakeLyricProvider('qq');
    final bili = _FakeLyricProvider('bili');
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);

    await pumpView(
      tester,
      locale: const Locale('en'),
      sources: [
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
        biliStrategy(bili),
      ],
      lyricsProvider: lyricsProvider,
    );

    final biliHeader = find.byKey(const ValueKey('lyricsSourceSection-bili'));
    expect(
      find.descendant(
        of: biliHeader,
        matching: find.text('Sign in to use Bilibili captions'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Sign in to prefer Bilibili captions as lyrics'),
      findsNothing,
      reason: '标题右侧用短句，避免英文长提示被省略号截断',
    );
  });

  testWidgets('单源筛选未登录 B 站：空态 hint 显示登录提示', (tester) async {
    final qq = _FakeLyricProvider('qq');
    final bili = _FakeLyricProvider('bili');
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
        biliStrategy(bili),
      ],
      lyricsProvider: lyricsProvider,
    );

    await tester.tap(find.byKey(const ValueKey('sourceSwapSourceChip-bili')));
    await tester.pumpAndSettle();

    expect(find.text('在「哔哩哔哩」中没有找到结果'), findsOneWidget);
    expect(find.text('登录后可优先使用 B 站字幕歌词'), findsOneWidget);
    expect(
      find.text('换个关键词或来源试试'),
      findsNothing,
      reason: '单源不可用时用登录提示替代通用空态提示',
    );
  });

  testWidgets('点结果只选中；底部确认后才 saveManual 写入该来源', (tester) async {
    final service = _FakeLyricsService();
    final lyricsProvider = LyricsProvider(service: service);
    addTearDown(lyricsProvider.dispose);

    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天', artist: '周杰伦')],
      payload: const LyricsPayload(lyric: '[00:01.00]晴天'),
    );
    final bili = _FakeLyricProvider('bili');

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
        biliStrategy(bili),
      ],
      lyricsProvider: lyricsProvider,
    );

    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('点选一项后确认'), findsNothing);
    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();

    expect(service.saved, isEmpty, reason: '点选不取词、不写缓存');
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await tester.tap(find.text('使用此歌词'));
    await tester.pumpAndSettle();

    expect(service.saved, hasLength(1));
    expect(service.saved.single.trackId, 'bili:1');
    expect(service.saved.single.provider, 'qq');
  });

  testWidgets('来源 chips：默认全部，切单源只显示该源结果且不清选中', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);

    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天 QQ', artist: '周杰伦')],
    );
    final external = _FakeLyricProvider(
      'external',
      matches: [SongMatch(songId: '2', title: '晴天 外部', artist: '周杰伦')],
    );

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
        LyricsSourceStrategy(
          channelKey: 'external',
          provider: external,
          isChannel: false,
        ),
      ],
      lyricsProvider: lyricsProvider,
    );

    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-tx')),
      findsOneWidget,
    );
    expect(find.text('晴天 QQ'), findsOneWidget);
    expect(find.text('晴天 外部'), findsOneWidget);

    await tester.tap(find.text('晴天 QQ'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sourceSwapSourceChip-tx')));
    await tester.pumpAndSettle();
    expect(find.text('晴天 QQ'), findsOneWidget);
    expect(find.text('晴天 外部'), findsNothing);
    expect(
      find.byIcon(Icons.check_circle_rounded),
      findsOneWidget,
      reason: '切筛选不丢选中项',
    );
  });

  testWidgets('来源 chips 顺序跟随 channelOrder，LRCLIB 固定在最后', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    final lrclib = _FakeLyricProvider('lrclib');
    final bili = _FakeLyricProvider('bili');
    final wy = _FakeLyricProvider('netease');
    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天 QQ', artist: '周杰伦')],
    );

    await pumpView(
      tester,
      sources: [
        // 声明顺序故意打乱：lrclib 在前、tx 在前，都不能决定展示顺序。
        LyricsSourceStrategy(
          channelKey: 'lrclib',
          provider: lrclib,
          isChannel: false,
        ),
        LyricsSourceStrategy(channelKey: 'bili', provider: bili),
        LyricsSourceStrategy(channelKey: 'wy', provider: wy),
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
      ],
      // 顺序表只给已知渠道；bili 不在表里，保持声明顺序排在已知渠道之后。
      channelOrder: const ['wy', 'tx'],
      lyricsProvider: lyricsProvider,
    );

    double xOf(String key) =>
        tester.getTopLeft(find.byKey(ValueKey('sourceSwapSourceChip-$key'))).dx;
    expect(xOf('wy'), lessThan(xOf('tx')));
    expect(xOf('tx'), lessThan(xOf('bili')));
    expect(xOf('bili'), lessThan(xOf('lrclib')), reason: 'LRCLIB 固定在渠道之后');
  });

  testWidgets('结果行显示匹配时长；未知时长不占位', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    final qq = _FakeLyricProvider(
      'qq',
      matches: [
        SongMatch(
          songId: 'timed',
          title: '晴天 有时长',
          artist: '周杰伦',
          duration: const Duration(minutes: 4, seconds: 5),
        ),
        SongMatch(songId: 'untimed', title: '晴天 无时长', artist: '周杰伦'),
      ],
    );

    await pumpView(
      tester,
      sources: [LyricsSourceStrategy(channelKey: 'tx', provider: qq)],
      lyricsProvider: lyricsProvider,
    );

    expect(find.text('4:05'), findsOneWidget);
    expect(find.text('0:00'), findsNothing);
    expect(qq.lastSearchLimit, 10);
    final timedRow = tester.widget<TrackRow>(
      find.ancestor(of: find.text('晴天 有时长'), matching: find.byType(TrackRow)),
    );
    expect(timedRow.model.durationMs, 245000);
    final untimedRow = tester.widget<TrackRow>(
      find.ancestor(of: find.text('晴天 无时长'), matching: find.byType(TrackRow)),
    );
    expect(untimedRow.model.durationMs, isNull);
  });

  testWidgets('选中后预览 loading → ready，LRC 只展示前 3 行', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    final gate = Completer<void>();
    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天', artist: '周杰伦')],
      payload: const LyricsPayload(
        lyric:
            '[ti:晴天]\n'
            '[00:01.00]第一句\n'
            '[00:02.00]第二句\n'
            '[00:03.00]第三句\n'
            '[00:04.00]第四句',
      ),
    )..fetchGate = gate;

    await pumpView(
      tester,
      sources: [LyricsSourceStrategy(channelKey: 'tx', provider: qq)],
      lyricsProvider: lyricsProvider,
    );

    await tester.tap(find.byKey(const ValueKey('lyricsSourceRow-qq-1')));
    await tester.pump();

    expect(find.byKey(const Key('lyricsSourcePreview')), findsOneWidget);
    expect(find.text('歌词预览'), findsOneWidget);
    expect(find.text('正在获取歌词...'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('第一句\n第二句\n第三句'), findsOneWidget);
    expect(find.textContaining('第四句'), findsNothing);
  });

  testWidgets('预览失败：显示失败文案，重试后展示歌词', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天', artist: '周杰伦')],
      fetchError: StateError('preview down'),
    );

    await pumpView(
      tester,
      sources: [LyricsSourceStrategy(channelKey: 'tx', provider: qq)],
      lyricsProvider: lyricsProvider,
    );

    await tester.tap(find.byKey(const ValueKey('lyricsSourceRow-qq-1')));
    await tester.pumpAndSettle();

    expect(find.text('获取歌词失败，换一个来源试试。'), findsOneWidget);
    final retry = tester.widget<M3EIconButton>(
      find.byKey(const Key('lyricsSourcePreviewRetry')),
    );
    expect(retry.semanticLabel, '重试');
    expect((retry.icon as Icon).icon, Icons.refresh_rounded);

    qq
      ..fetchError = null
      ..payload = const LyricsPayload(lyric: '第一行\n第二行\n第三行');
    await tester.tap(find.byKey(const Key('lyricsSourcePreviewRetry')));
    await tester.pumpAndSettle();

    expect(find.text('第一行\n第二行\n第三行'), findsOneWidget);
    expect(find.text('获取歌词失败，换一个来源试试。'), findsNothing);
    expect(qq.fetchCalls, 2);
  });

  testWidgets('底栏只在当前筛选有可见结果时出现；选中不可见时确认禁用', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天 QQ', artist: '周杰伦')],
      payload: const LyricsPayload(lyric: '[00:01.00]晴天'),
    );
    final external = _FakeLyricProvider(
      'external',
      matches: [SongMatch(songId: 'ext-1', title: '外部结果', artist: '周杰伦')],
    );
    final empty = _FakeLyricProvider('empty');

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
        LyricsSourceStrategy(
          channelKey: 'external',
          provider: external,
          isChannel: false,
        ),
        LyricsSourceStrategy(
          channelKey: 'empty',
          provider: empty,
          isChannel: false,
        ),
      ],
      lyricsProvider: lyricsProvider,
    );

    await tester.tap(find.byKey(const ValueKey('lyricsSourceRow-qq-1')));
    await tester.pumpAndSettle();
    expect(find.byType(SourceSwapActionBar), findsOneWidget);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, '使用此歌词'))
          .onPressed,
      isNotNull,
    );

    await tester.tap(
      find.byKey(const ValueKey('sourceSwapSourceChip-external')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SourceSwapActionBar), findsOneWidget);
    expect(find.byKey(const Key('lyricsSourcePreview')), findsNothing);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, '使用此歌词'))
          .onPressed,
      isNull,
      reason: '选中项不可见时不能确认',
    );

    await tester.tap(find.byKey(const ValueKey('sourceSwapSourceChip-empty')));
    await tester.pumpAndSettle();
    expect(find.byType(SourceSwapActionBar), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sourceSwapSourceChip-tx')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byKey(const Key('lyricsSourcePreview')), findsOneWidget);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, '使用此歌词'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('停用渠道：歌词来源隐藏；非渠道来源不受开关影响', (tester) async {
    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天 QQ', artist: '周杰伦')],
    );
    final bili = _FakeLyricProvider('bili');
    final external = _FakeLyricProvider(
      'external',
      matches: [SongMatch(songId: '2', title: '晴天 外部', artist: '周杰伦')],
    );
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
        biliStrategy(bili),
        LyricsSourceStrategy(
          channelKey: 'external',
          provider: external,
          isChannel: false,
        ),
      ],
      enabledChannelKeys: const {'tx'},
      lyricsProvider: lyricsProvider,
    );

    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-tx')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-bili')),
      findsNothing,
      reason: '停用渠道不出现在歌词换源',
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-external')),
      findsOneWidget,
      reason: '非渠道来源不受开关影响',
    );
    expect(bili.searchCalls, 0);
  });

  testWidgets('B 站已登录：可选字幕来源，providerName 写 bili', (tester) async {
    final service = _FakeLyricsService();
    final lyricsProvider = LyricsProvider(service: service);
    addTearDown(lyricsProvider.dispose);

    final bili = _FakeLyricProvider(
      'bili',
      matches: [
        SongMatch(songId: 'BV1xx411c7mD', title: '晴天 翻唱', artist: '某UP主'),
      ],
      payload: const LyricsPayload(lyric: '[00:01.00]字幕'),
    );

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(
          channelKey: 'bili',
          provider: bili,
          autoFallback: false,
          // 已登录：来源可用，正常参与手动搜索。
          unavailable: () => null,
        ),
      ],
      lyricsProvider: lyricsProvider,
    );

    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-bili')),
      findsOneWidget,
      reason: '来源名走 provider 标签',
    );
    expect(
      find.byKey(const ValueKey('lyricsSourceSection-bili')),
      findsOneWidget,
    );
    expect(
      find.text('登录后可优先使用 B 站字幕歌词'),
      findsNothing,
      reason: '已登录时标题右侧不能出现登录提示',
    );
    await tester.tap(find.text('晴天 翻唱'));
    await tester.pumpAndSettle();
    expect(service.saved, isEmpty, reason: '点选不取词');

    await tester.tap(find.text('使用此歌词'));
    await tester.pumpAndSettle();

    expect(service.saved.single.provider, 'bili');
  });

  testWidgets('没有歌词来源：只留空态，搜索栏与底栏都隐藏', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);

    await pumpView(tester, sources: const [], lyricsProvider: lyricsProvider);

    expect(find.text('没有可用的歌词来源'), findsOneWidget);
    expect(find.text('启用对应平台后，这里会列出可用的歌词来源'), findsOneWidget);
    expect(find.byKey(const Key('sourceSwapSearchFieldLyrics')), findsNothing);
    expect(find.byType(SourceSwapActionBar), findsNothing);
  });

  testWidgets('清空查询：chips 与底栏隐藏，搜索框保留', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天', artist: '周杰伦')],
    );

    await pumpView(
      tester,
      sources: [LyricsSourceStrategy(channelKey: 'tx', provider: qq)],
      lyricsProvider: lyricsProvider,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsOneWidget,
    );
    expect(find.byType(SourceSwapActionBar), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('sourceSwapSearchFieldLyrics')),
      '',
    );
    await tester.pumpAndSettle();

    expect(find.text('输入歌名或歌手开始搜索'), findsOneWidget);
    expect(
      find.byKey(const Key('sourceSwapSearchFieldLyrics')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsNothing,
    );
    expect(find.byType(SourceSwapActionBar), findsNothing);
  });

  testWidgets('搜索无结果：搜索框/chips 保留，底栏隐藏', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    final qq = _FakeLyricProvider('qq');

    await pumpView(
      tester,
      sources: [LyricsSourceStrategy(channelKey: 'tx', provider: qq)],
      lyricsProvider: lyricsProvider,
    );

    expect(find.text('暂时没找到歌词，换个来源试试？'), findsOneWidget);
    expect(
      find.byKey(const Key('sourceSwapSearchFieldLyrics')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsOneWidget,
    );
    expect(find.byType(SourceSwapActionBar), findsNothing);
  });

  testWidgets('取词中锁住交互：搜索/chips/候选不可改，写入仍是确认时的 A', (tester) async {
    final service = _FakeLyricsService();
    final lyricsProvider = LyricsProvider(service: service);
    addTearDown(lyricsProvider.dispose);
    final gate = Completer<void>();
    final qq = _FakeLyricProvider(
      'qq',
      matches: [
        SongMatch(songId: 'A', title: '晴天 A', artist: '周杰伦'),
        SongMatch(songId: 'B', title: '晴天 B', artist: '周杰伦'),
      ],
      payload: const LyricsPayload(lyric: '[00:01.00]晴天'),
    )..fetchGate = gate;

    await pumpView(
      tester,
      sources: [LyricsSourceStrategy(channelKey: 'tx', provider: qq)],
      lyricsProvider: lyricsProvider,
    );

    await tester.tap(find.text('晴天 A'));
    // 预览还挂在 fetchGate 上：loading 动画不会 settle，只推进一帧确认选中。
    await tester.pump();
    expect(rowSelected(tester, '晴天 A'), isTrue);

    await tester.tap(find.text('使用此歌词'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final field = tester.widget<AppSearchBar>(
      find.descendant(
        of: find.byKey(const Key('sourceSwapSearchFieldLyrics')),
        matching: find.byType(AppSearchBar),
      ),
    );
    expect(field.enabled, isFalse, reason: '取词中锁住搜索输入');
    expect(
      tester
          .widget<M3EChip>(
            find.byKey(const ValueKey('sourceSwapSourceChip-all')),
          )
          .onPressed,
      isNull,
      reason: '取词中锁住来源切换',
    );
    expect(
      tester
          .widget<M3EChip>(
            find.byKey(const ValueKey('sourceSwapSourceChip-tx')),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.byIcon(Icons.close_rounded),
      findsNothing,
      reason: '禁用搜索框时清除键也不能生效',
    );

    // 点另一条候选：选中项仍是 A，不会被改成 B。
    await tester.tap(find.text('晴天 B'));
    await tester.pump();
    expect(rowSelected(tester, '晴天 A'), isTrue);
    expect(rowSelected(tester, '晴天 B'), isFalse);

    gate.complete();
    await tester.pumpAndSettle();

    expect(qq.fetchedSongIds, ['A'], reason: 'applySelected 写入确认时的旧选中项');
    expect(service.saved.single.provider, 'qq');
  });
}
