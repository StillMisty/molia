import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';

import '../support/fakes.dart';
import '../support/perf_app_harness.dart';

/// 长按底栏「收藏」：切到收藏页并在当前可见行里定位当前播放曲目。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  /// 收藏页长按热区（收藏目的地图标的整块指示器）。
  const navKey = Key('shellNavLongPress-favorites');

  /// 与 `pumpPerfApp` 写入的收藏行同身份（`perf:song-N`）。
  Track favoriteTrack(int index) => Track(
    id: TrackId('perf', 'song-$index'),
    title: 'Performance Track $index',
    artists: [Artist(name: 'Perf Artist ${index % 100}')],
    album: 'Perf Album ${index % 40}',
    duration: Duration(milliseconds: 180000 + index * 1000),
    origin: TrackOrigin.lx,
  );

  Future<FakePlaybackFacade> pumpFavorites(WidgetTester tester) => pumpPerfApp(
    tester,
    desktopShell: false,
    favoritesCount: 60,
    size: const Size(500, 900),
  );

  /// 列表行按合集行键定位（`CollectionTrackList` 的稳定 key）。
  Finder rowOf(int index) => find.byKey(ValueKey<String>('perf:song-$index'));

  /// 滚动 / 切页 / 底栏提示都是有限动画；播放中的当前行有无限动画，
  /// 不能用 pumpAndSettle（会一直等下去）。
  Future<void> advance(WidgetTester tester, {int frames = 40}) => pumpFrames(
    tester,
    frames: frames,
    interval: const Duration(milliseconds: 16),
  );

  testWidgets('已在收藏页：长按滚到当前播放曲目', (tester) async {
    final backend = await pumpFavorites(tester);
    final track = favoriteTrack(25);
    backend.emit(
      PlaybackSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        duration: track.duration ?? Duration.zero,
      ),
    );
    await tester.pump();

    // 目标行在首屏之外（懒列表不会构建到第 25 行）；顶栏迷你条的同名标题
    // 与列表无关，按行 key 判定。
    expect(rowOf(25), findsNothing);

    await tester.longPress(find.byKey(navKey));
    await advance(tester);

    expect(
      rowOf(25).hitTestable(),
      findsOneWidget,
      reason: '长按后应滚到当前播放曲目并完整可见',
    );
  });

  testWidgets('其它页面：先切到收藏页再定位', (tester) async {
    final backend = await pumpFavorites(tester);
    final track = favoriteTrack(25);
    backend.emit(
      PlaybackSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        duration: track.duration ?? Duration.zero,
      ),
    );
    await tester.pump();

    await tester.tap(find.text(l10n.libraryLabel));
    await advance(tester);
    expect(
      find.byKey(const Key('favoritesTitleSwitcher')).hitTestable(),
      findsNothing,
      reason: '已切到资料库，收藏页只是隐藏挂载',
    );

    await tester.longPress(find.byKey(navKey));
    await advance(tester);

    expect(
      find.byKey(const Key('favoritesTitleSwitcher')).hitTestable(),
      findsOneWidget,
      reason: '长按应先切回收藏页',
    );
    expect(rowOf(25).hitTestable(), findsOneWidget, reason: '切页后仍要定位到当前播放曲目');
  });

  testWidgets('当前曲目不在当前列表：给底栏提示', (tester) async {
    await pumpFavorites(tester);

    // 默认当前曲目是 perf:queue-0，不在收藏列表里。
    await tester.longPress(find.byKey(navKey));
    await advance(tester);

    expect(find.text(l10n.favoritesLocateMissing), findsOneWidget);
  });

  testWidgets('没有正在播放的歌曲：给底栏提示', (tester) async {
    final backend = await pumpFavorites(tester);
    backend.emit(PlaybackSnapshot.empty);
    await tester.pump();

    await tester.longPress(find.byKey(navKey));
    await advance(tester);

    expect(find.text(l10n.favoritesLocateNoTrack), findsOneWidget);
  });
}
