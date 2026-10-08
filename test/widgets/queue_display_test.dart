import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:molia/widgets/queue.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 队列显示：顶部「正在播放」高亮行 + 「接下来」列表；恢复态点击可续播。
///
/// 注意：provider 必须在测试体内创建（不要在 setUp 里）——setUp 在测试的
/// FakeAsync zone 之外运行，其异步链会跨 zone，await preferencesReady 后
/// 再 pump 会卡死（与 settings_page_test 同一约定）。
Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album $id',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: {'id': id, 'songmid': 'mid_$id'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpQueue(WidgetTester tester, PlaybackProvider playback) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const Scaffold(
            body: SingleChildScrollView(child: QueueDisplay()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 通知节流计时器跑完（queue 分类 300ms），避免 pending timer 报错。
  Future<void> drainThrottle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  testWidgets('正在播放高亮行 + 接下来分组（圆角封面/统一字号）', (tester) async {
    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(backend: backend);
    addTearDown(playback.dispose);

    backend.emit(BackendSnapshot(
      current: _track('a'),
      queue: [_track('a'), _track('b')],
      currentIndex: 0,
      next: _track('b'),
      upcoming: [_track('b')],
      isPlaying: true,
      position: Duration.zero,
      duration: const Duration(seconds: 30),
    ));
    await pumpQueue(tester, playback);

    expect(tester.takeException(), isNull);
    expect(find.text('正在播放'), findsOneWidget);
    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('Title a'), findsOneWidget);
    expect(find.text('Title b'), findsOneWidget);
    // 播放中的当前曲目显示均衡器图形；时长走 M3E trailingText（0:30）。
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);

    await drainThrottle(tester);
  });

  testWidgets('恢复态：正在播放行来自会话，点接下来条目恢复播放', (tester) async {
    // 先写入会话，再创建 provider（构造时即读取）。
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 0,
      position: const Duration(seconds: 10),
    ));

    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(backend: backend);
    addTearDown(playback.dispose);
    await playback.preferencesReady;
    await pumpQueue(tester, playback);

    expect(find.text('正在播放'), findsOneWidget);
    expect(find.text('Title a'), findsOneWidget);
    expect(find.text('Title b'), findsOneWidget);
    // 恢复态未真正播放：显示暂停图形。
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

    // 点「接下来」条目 → 用会话队列从该曲目恢复播放（而不是静默无响应）。
    await tester.tap(find.text('Title b'));
    await tester.pump();
    await tester.pump();

    expect(backend.calls, contains('load'));
    expect(backend.lastRequest?.startIndex, 1);

    await drainThrottle(tester);
  });
}
