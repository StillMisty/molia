/// 歌词换源视图：来源来自注册表 / 测试注入，未登录 B 站只提示不发请求，
/// 选中结果按来源 provider 名写入手动歌词。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics/lyrics_source_strategy.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/lyrics_source_search_view.dart';

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
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async => payload;

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
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
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

  testWidgets('未登录 B 站：显示登录提示，且不发搜索请求', (tester) async {
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

    expect(find.text('登录后可优先使用 B 站字幕歌词'), findsOneWidget);
    expect(qq.searchCalls, 1);
    expect(bili.searchCalls, 0, reason: '不可用来源不发请求');
  });

  testWidgets('选中可用来源：saveManual 写入该来源的 providerName', (tester) async {
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
    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();

    expect(service.saved, hasLength(1));
    expect(service.saved.single.trackId, 'bili:1');
    expect(service.saved.single.provider, 'qq');
  });

  testWidgets('停用渠道：歌词来源隐藏；LRCLIB 不受渠道开关影响', (tester) async {
    final qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天 QQ', artist: '周杰伦')],
    );
    final bili = _FakeLyricProvider('bili');
    final lrclib = _FakeLyricProvider(
      'lrclib',
      matches: [SongMatch(songId: '2', title: '晴天 LRC', artist: '周杰伦')],
    );
    final lyricsProvider = LyricsProvider(service: _FakeLyricsService());
    addTearDown(lyricsProvider.dispose);

    await pumpView(
      tester,
      sources: [
        LyricsSourceStrategy(channelKey: 'tx', provider: qq),
        biliStrategy(bili),
        LyricsSourceStrategy(
          channelKey: 'lrclib',
          provider: lrclib,
          isChannel: false,
        ),
      ],
      enabledChannelKeys: const {'tx'},
      lyricsProvider: lyricsProvider,
    );

    expect(find.text('QQ音乐'), findsOneWidget);
    expect(find.text('哔哩哔哩'), findsNothing, reason: '停用渠道不出现在歌词换源');
    expect(find.text('LRCLIB'), findsOneWidget, reason: '非渠道来源不受开关影响');
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

    expect(find.text('哔哩哔哩'), findsOneWidget, reason: '来源名走 provider 标签');
    await tester.tap(find.text('晴天 翻唱'));
    await tester.pumpAndSettle();

    expect(service.saved.single.provider, 'bili');
  });
}
