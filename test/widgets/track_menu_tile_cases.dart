import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/download/download_manager.dart';
import 'package:molia/services/download/download_queue.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/widgets/track_menu_tile.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../support/cover_test_support.dart';
import '../support/fakes.dart';

/// 只记录下载命令的窄实现（公共下载动作测试）。
class _RecordingDownloadManager extends ChangeNotifier
    implements DownloadManager {
  final List<Track> downloaded = [];
  final Map<String, DownloadTask> tasks = {};
  Object? failure;

  @override
  bool get supported => true;

  @override
  DownloadTask? taskForTrack(Track track) => tasks[track.id.uri];

  @override
  String defaultQualityFor(Track track) => '320k';

  @override
  Future<void> download(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async {
    downloaded.add(track);
    final error = failure;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 曲目行本体 [TrackMenuTile] 的操作入口：触摸端行尾 ⋮ 常显可点；桌面端无 ⋮，
/// 行表面右键在落点弹出同一份菜单。
///
/// 菜单条目与领域接线由队列 / 搜索结果行的既有用例与各适配层测试覆盖，
/// 这里只钉住两条入口接线。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpTile(
    WidgetTester tester, {
    VoidCallback? onToggleFavorite,
  }) async {
    await tester.pumpWidget(
      withCoverStore(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: Center(
              child: TrackMenuTile(
                track: const Track(
                  id: TrackId('test', 'a'),
                  title: 'Title',
                  origin: TrackOrigin.lx,
                ),
                row: const TrackRowModel(title: 'Title', artist: 'Artist'),
                position: M3ECardPosition.single,
                onTap: () {},
                favorite: false,
                onToggleFavorite: onToggleFavorite ?? () {},
                onAddToPlaylist: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('桌面：行内无 ⋮，右键在落点弹出菜单，动作走注入回调', (tester) async {
    var toggled = 0;
    await pumpTile(tester, onToggleFavorite: () => toggled++);

    expect(
      find.byIcon(Icons.more_vert_rounded),
      findsNothing,
      reason: '桌面入口是行表面右键，不再有行尾 ⋮',
    );

    // 右键行内某点 → 菜单出现（选中即关）。
    await tester.tapAt(
      tester.getRect(find.byType(TrackRow)).center,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('加入列表'), findsOneWidget);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(toggled, 1);
    expect(find.text('加入列表'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面：菜单贴锚点左缘——左缘随右键落点平移，并从落点下方展开', (tester) async {
    await pumpTile(tester);

    final Rect rowRect = tester.getRect(find.byType(TrackRow));
    final double clickY = rowRect.center.dy;

    // 一次落点：右键 → 量菜单条目左上角 → 点空白关菜单，供下一个落点复用。
    Future<Offset> menuTopLeftAt(double x) async {
      await tester.tapAt(
        Offset(x, clickY),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      final Offset topLeft = tester.getTopLeft(find.text('收藏'));
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      return topLeft;
    }

    final Offset near = await menuTopLeftAt(rowRect.left + 40);
    final Offset far = await menuTopLeftAt(rowRect.left + 120);

    expect(
      far.dx - near.dx,
      moreOrLessEquals(80, epsilon: 2),
      reason: '菜单左缘=锚点左右跟随落点',
    );
    expect(
      near.dy,
      inInclusiveRange(clickY, clickY + 40),
      reason: '菜单在落点下方展开（菜单内边距容忍）',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('触摸端：⋮ 恒显可点，右键不接线', (tester) async {
    await pumpTile(tester);

    // 入口恒定可见可点（点击命中即证明未被隐藏）。
    expect(find.byIcon(Icons.more_vert_rounded).hitTestable(), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TrackRow), buttons: kSecondaryButton);
    await tester.pump();
    expect(find.text('收藏'), findsNothing, reason: '触摸端无右键菜单');
  });

  group('公共动作', () {
    const track = Track(
      id: TrackId('test', 'a'),
      title: 'Title',
      origin: TrackOrigin.lx,
    );

    Future<void> pumpWithProviders(
      WidgetTester tester, {
      required PlaybackProvider? playback,
      DownloadRecords? records,
      DownloadManager? downloads,
    }) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            coverStoreProvider(),
            if (playback != null)
              ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
            if (records != null)
              ChangeNotifierProvider<DownloadRecords>.value(value: records),
            if (downloads != null)
              ChangeNotifierProvider<DownloadManager>.value(value: downloads),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: const [Locale('zh')],
            home: Scaffold(
              body: TrackMenuTile(
                track: track,
                row: const TrackRowModel(title: 'Title', artist: 'Artist'),
                position: M3ECardPosition.single,
                onTap: () {},
                favorite: false,
                onToggleFavorite: () {},
                onAddToPlaylist: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('无当前曲目：隐藏加入队列；有当前曲目：追加并提示', (tester) async {
      final backend = FakePlaybackBackend();
      final playback = buildTestPlaybackProvider(backend: backend);
      addTearDown(playback.dispose);

      await pumpWithProviders(tester, playback: playback);
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('加入队列'), findsNothing);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();

      backend.emit(
        const BackendSnapshot(
          current: Track(
            id: TrackId('test', 'now'),
            title: 'Now',
            origin: TrackOrigin.lx,
          ),
          queue: [
            Track(
              id: TrackId('test', 'now'),
              title: 'Now',
              origin: TrackOrigin.lx,
            ),
          ],
          currentIndex: 0,
        ),
      );
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('加入队列'), findsOneWidget);
      await tester.tap(find.text('加入队列'));
      await tester.pumpAndSettle();

      expect(backend.calls, contains('enqueueTracks'));
      expect(find.text('已加入队列'), findsOneWidget);
    });

    testWidgets('下载：默认音质入队并提示；已下载 / 本地曲目不显示', (tester) async {
      final manager = _RecordingDownloadManager();
      addTearDown(manager.dispose);
      final records = DownloadRecords(supported: true, initialized: true);

      await pumpWithProviders(
        tester,
        playback: null,
        records: records,
        downloads: manager,
      );
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('下载'), findsOneWidget);
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      expect(manager.downloaded.single.id, track.id);
      expect(find.text('已加入下载队列'), findsOneWidget);

      // 已有音频记录：入口消失。
      records.put(
        const DownloadedTrack(
          originSourceKey: 'test',
          originSongId: 'a',
          title: 'Title',
          filePath: '/downloads/a.mp3',
          downloadedAt: 1,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('下载'), findsNothing);
    });

    testWidgets('下载失败：提示失败文案，不留下未处理异常', (tester) async {
      final manager = _RecordingDownloadManager()
        ..failure = const SourceFailure(
          kind: FailureKind.network,
          message: 'boom',
        );
      addTearDown(manager.dispose);
      final records = DownloadRecords(supported: true, initialized: true);

      await pumpWithProviders(
        tester,
        playback: null,
        records: records,
        downloads: manager,
      );
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('下载失败'), findsOneWidget);
    });
  });
}
