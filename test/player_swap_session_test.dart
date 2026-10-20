import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/cover_deck_metrics.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 封面堆叠尺寸：与播放器同一预算口径（封面边 240 → 堆叠 360 × 254.4）。
final _deck = coverDeckMetricsFor(
  availableWidth: 240 * coverDeckHorizontalFactor,
  availableHeight: 300,
);

/// 切歌检测的快照监听路径：deck 不在自己的 build 里检测曲目变化，
/// 而是监听 [PlaybackProvider] 通知、比较当前曲目 id 后开启切歌会话。
///
/// 这里把 [PlayerCoverDeck] 直接挂在根上且 `displayTrack` 固定不变：
/// 父级不会因通知重建，deck 也不可能通过「displayTrack 变化」察觉切歌，
/// 唯一能启动动画/触发联动的只有快照监听本身；本测试即锁定该契约。
Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  final a = _track('a');
  final b = _track('b');
  final c = _track('c');
  final order = [a, b, c];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  void emitFor(String id) {
    final index = order.indexWhere((track) => track.id.id == id);
    backend.emit(BackendSnapshot(
      current: order[index],
      queue: order,
      currentIndex: index,
      next: index + 1 < order.length ? order[index + 1] : null,
      previous: index > 0 ? order[index - 1] : null,
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
  }

  /// 中心封面相对堆叠中心的横向偏移：0 = 稳态；切歌入场期间非 0
  /// （向前从右侧入场 = 正值）。
  double centerOffset(WidgetTester tester) {
    final deckCenter =
        tester.getCenter(find.byKey(PlayerCoverDeck.swipeHostKey));
    final coverCenter =
        tester.getCenter(find.byKey(PlayerCoverDeck.centerCoverCardKey));
    return coverCenter.dx - deckCenter.dx;
  }

  /// 挂载固定 `displayTrack = A` 的 deck，等首帧落定，
  /// 返回切歌联动回调的记录列表（已清掉首帧入场留下的调用）。
  Future<List<bool>> pumpDeck(WidgetTester tester) async {
    final swaps = <bool>[];
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerCoverDeck(
                displayTrack: a,
                artDimension: _deck.artDimension,
                stackDimension: _deck.stackWidth,
                stackHeight: _deck.stackHeight,
                fullCoverKey: GlobalKey(),
                onTrackSwapped: swaps.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 等首帧落定（冷启动恢复态首帧已是稳态）。
    await tester.pump(const Duration(milliseconds: 600));
    swaps.clear();
    return swaps;
  }

  testWidgets('快照通知即切歌检测：不依赖父级重建，动画照常开始', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester);
    expect(swaps, isEmpty);

    emitFor('b');
    // 通知（可能是节流后补发）→ 微任务对账 → 检测帧末尾触发联动。
    await tester.pump(const Duration(milliseconds: 50));
    expect(swaps, [false], reason: '快照通知应在本帧触发 onTrackSwapped（无需父级重建）');

    await tester.pump(); // 动画首 tick
    await tester.pump(const Duration(milliseconds: 100)); // 中间态
    expect(centerOffset(tester), greaterThan(4),
        reason: '切歌动画应由快照通知驱动启动（中心封面从右侧入场）');
    expect(tester.takeException(), isNull);
    // 让 provider 的通知节流计时器（queue 300ms）跑完，避免残留 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('同一批多条通知只对账一次，不重复触发', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester);

    // 同一同步批次内连续两条快照（b → c）：微任务合并后只应处理最终曲目。
    emitFor('b');
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(swaps, hasLength(1), reason: '同一批通知只应触发一次切歌联动，而不是每帧每条都触发');
    expect(tester.takeException(), isNull);
    // 让 provider 的通知节流计时器（queue 300ms）跑完，避免残留 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('快速连切：从当前进度续走，不回到起点重放', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester);

    emitFor('b');
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧
    await tester.pump(); // 动画首 tick
    await tester.pump(const Duration(milliseconds: 100)); // 动画中段（弹簧 ~0.66）
    expect(centerOffset(tester), greaterThan(4));

    // 动画尚未结束就切到 c：应从当前进度续走。
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 50)); // 第二次检测帧
    await tester.pump(); // 检测 post-frame 之后一帧
    expect(centerOffset(tester), lessThan(40),
        reason: '连切应从当前进度续走；若回到起点重放会跳回满偏移（约 72）');
    expect(swaps, hasLength(2));

    await tester.pump(const Duration(milliseconds: 600));
    expect(centerOffset(tester), closeTo(0, 1));
    expect(tester.takeException(), isNull);
    // 让 provider 的通知节流计时器（queue 300ms）跑完，避免残留 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('current 变为 null：不触发切歌、不崩，随后切歌仍正常', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester);

    // 停止/清空：快照 current 为 null。
    backend.emit(BackendSnapshot.empty);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(swaps, isEmpty, reason: 'current 清空不应触发切歌联动');
    expect(tester.takeException(), isNull);

    // 清空后再出现另一首：动画身份仍从 A 比较，正常触发。
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 50));
    expect(swaps, [false]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(centerOffset(tester), greaterThan(4));
    expect(tester.takeException(), isNull);
    // 让 provider 的通知节流计时器（queue 300ms）跑完，避免残留 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });
}
