/// 歌词换源视图：来源来自注册表 / 测试注入，未登录 B 站只提示不发请求，
/// 选中结果按来源 provider 名写入手动歌词。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics/lyrics_source_strategy.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/app_search_bar.dart';
import 'package:molia/widgets/lyrics_source_search_view.dart';
import 'package:molia/widgets/source_swap/source_swap_chrome.dart';

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
  _FakeLyricProvider(this.name, {this.matches = const [], this.payload});

  @override
  final String name;

  final List<SongMatch> matches;
  final LyricsPayload? payload;
  int searchCalls = 0;

  /// 非空时取词挂起，直到测试放行（验证忙碌锁）。
  Completer<void>? fetchGate;

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
    return matches.take(limit).toList();
  }

  @override
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async {
    fetchedSongIds.add(match.songId);
    final gate = fetchGate;
    if (gate != null) await gate.future;
    return payload;
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
              enabledChannelKeys: enabledChannelKeys,
              autofocusSearch: false,
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
    expect(find.text('点选一项后确认'), findsOneWidget);
    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();

    expect(service.saved, isEmpty, reason: '点选不取词、不写缓存');
    expect(find.text('已选：晴天 · QQ音乐'), findsOneWidget);
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
    expect(find.text('已选：晴天 QQ · QQ音乐'), findsOneWidget);
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
    await tester.pumpAndSettle();
    expect(find.text('已选：晴天 A · QQ音乐'), findsOneWidget);

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

    // 点另一条候选：底栏摘要仍是 A，不会被改成 B。
    await tester.tap(find.text('晴天 B'));
    await tester.pump();
    expect(find.text('已选：晴天 A · QQ音乐'), findsOneWidget);
    expect(find.text('已选：晴天 B · QQ音乐'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(qq.fetchedSongIds, ['A'], reason: 'applySelected 写入确认时的旧选中项');
    expect(service.saved.single.provider, 'qq');
  });

  testWidgets('已选摘要按渠道 key 解析来源名（provider 名可不同）', (tester) async {
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);
    // provider 名与渠道 key 不同：摘要必须按渠道 key 显示「哔哩哔哩」。
    final custom = _FakeLyricProvider(
      'custom_bili',
      matches: [SongMatch(songId: '1', title: '晴天', artist: '某UP主')],
    );

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(
          channelKey: 'bili',
          provider: custom,
          unavailable: () => null,
        ),
      ],
      lyricsProvider: lyricsProvider,
    );

    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();
    expect(find.text('已选：晴天 · 哔哩哔哩'), findsOneWidget);
  });
}
