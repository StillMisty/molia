import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/playback_order.dart';
import 'package:molia/playback/shuffle_order.dart';
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 默认播放模式测试用曲目。
Track _track(String id) {
  return Track(
    id: TrackId('fake', id),
    title: 'Title $id',
    artists: [Artist(name: 'Artist $id')],
    album: 'Album',
    duration: const Duration(seconds: 30),
    origin: TrackOrigin.lx,
    payload: {'id': id},
  );
}

/// 顺序栈测试用曲目（队列还原）。
SourceTrack _source(String id) => SourceTrack(
      sourceKey: 'fake',
      origin: 'lx',
      title: 'Title $id',
      artist: 'Artist',
      album: 'Album',
      raw: {'id': id},
    );

/// 播放顺序族测试面：默认播放模式（持久化 / 启动应用 / 有曲目不打断）、
/// 顺序栈（压栈弹栈 / 上限 / 队列还原）、洗牌顺序（排列覆盖 / 轮末重洗 /
/// 队列追加）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // 默认播放模式（设置项）：持久化 + 启动时无曲目应用。
  test('默认 listLoop：启动不额外下发 setMode', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);

    await provider.preferencesReady;
    expect(provider.defaultPlayMode, PlayMode.listLoop);
    expect(provider.currentMode, PlayMode.listLoop);
    expect(backend.calls.where((call) => call == 'setMode'), isEmpty);
  });

  test('togglePlayMode 按 列表循环 → 顺序 → 单曲 → 随机 循环', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    final expected = [
      PlayMode.sequential,
      PlayMode.singleRepeat,
      PlayMode.shuffle,
      PlayMode.listLoop,
    ];
    for (final mode in expected) {
      await provider.togglePlayMode();
      expect(provider.currentMode, mode);
    }
  });

  test('启动时加载持久化的 shuffle 并应用到 facade（无曲目）', () async {
    SharedPreferences.setMockInitialValues({'default_play_mode': 'shuffle'});
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);

    await provider.preferencesReady;
    expect(provider.defaultPlayMode, PlayMode.shuffle);
    expect(provider.currentMode, PlayMode.shuffle);
    expect(backend.calls, contains('setMode'));
  });

  test('setDefaultPlayMode 持久化且无曲目时立即应用', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    await provider.setDefaultPlayMode(PlayMode.singleRepeat);
    expect(provider.defaultPlayMode, PlayMode.singleRepeat);
    expect(provider.currentMode, PlayMode.singleRepeat);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('default_play_mode'), 'singleRepeat');
  });

  test('有曲目时不打断当前会话，仅持久化默认值', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 当前正在播放（有曲目）时切换默认模式。
    final track = _track('a');
    backend.emit(BackendSnapshot(
      current: track,
      queue: [track],
      currentIndex: 0,
      isPlaying: true,
    ));
    await provider.setDefaultPlayMode(PlayMode.shuffle);

    expect(provider.defaultPlayMode, PlayMode.shuffle);
    expect(provider.currentMode, PlayMode.listLoop);
    expect(backend.calls.where((call) => call == 'setMode'), isEmpty);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('default_play_mode'), 'shuffle');
  });

  // 顺序栈：压栈 / 弹栈 / 上限 / 清空 / 队列还原（越界忽略）。
  test('record 压栈、popPrevious 弹栈（后进先出）', () {
    final order = PlaybackOrder();

    expect(order.isEmpty, isTrue);
    expect(order.popPrevious(), isNull);

    order.record(0);
    order.record(2);
    expect(order.isEmpty, isFalse);
    expect(order.popPrevious(), 2);
    expect(order.popPrevious(), 0);
    expect(order.popPrevious(), isNull);
    expect(order.isEmpty, isTrue);
  });

  test('peekPrevious 只读栈顶（快照展示用，不消耗播放顺序）', () {
    final order = PlaybackOrder();

    expect(order.peekPrevious(), isNull);

    order.record(0);
    order.record(2);
    expect(order.peekPrevious(), 2);
    expect(order.peekPrevious(), 2);
    expect(order.popPrevious(), 2);
    expect(order.peekPrevious(), 0);
  });

  test('栈深上限：超出后丢弃最早记录', () {
    final order = PlaybackOrder(maxEntries: 3);
    for (var i = 0; i < 5; i++) {
      order.record(i);
    }
    expect(order.popPrevious(), 4);
    expect(order.popPrevious(), 3);
    expect(order.popPrevious(), 2);
    expect(order.popPrevious(), isNull);
  });

  test('clear 清空；tracksOf 按队列还原且忽略越界下标', () {
    final queue = [_source('a'), _source('b')];
    final order = PlaybackOrder();

    order.record(0);
    order.record(1);
    expect(order.tracksOf(queue).map((track) => track.id), ['fake:a', 'fake:b']);

    order.record(9); // 越界（模拟队列被替换）
    expect(order.tracksOf(queue).map((track) => track.id), ['fake:a', 'fake:b']);

    order.clear();
    expect(order.isEmpty, isTrue);
    expect(order.tracksOf(queue), isEmpty);
  });

  // 洗牌顺序（纯逻辑）：排列覆盖、起播置首、轮末重洗、预览稳定。
  test('reset 覆盖全部下标且起播置首', () {
    final order = PlaybackShuffleOrder(random: Random(7))
      ..reset(5, startIndex: 3);

    expect(order.positionOf(3), 0);
    final remaining = order.remainingAfter(3);
    expect(remaining, hasLength(4));
    expect({3, ...remaining}, {0, 1, 2, 3, 4});
  });

  test('next 走完一轮不重复，末尾自动重洗新一轮', () {
    final order = PlaybackShuffleOrder(random: Random(1))
      ..reset(4, startIndex: 0);

    final played = <int>[0];
    var current = 0;
    for (var i = 0; i < 3; i++) {
      current = order.next(current);
      expect(played, isNot(contains(current)), reason: '同一轮不应重复');
      played.add(current);
    }
    expect(played.toSet(), {0, 1, 2, 3});

    // 一轮结束：重洗新一轮，下一首不应等于当前曲目。
    final nextRoundFirst = order.next(current);
    expect(nextRoundFirst, isNot(current));
    expect(order.remainingAfter(current), hasLength(3));
  });

  test('peekNext 到末尾返回 null 且不重洗（连续读取稳定）', () {
    final order = PlaybackShuffleOrder(random: Random(2))
      ..reset(3, startIndex: 1);

    final second = order.peekNext(1);
    expect(second, isNotNull);
    final third = order.peekNext(second!);
    expect(third, isNotNull);
    expect(order.peekNext(third!), isNull);
    expect(order.peekNext(third), isNull, reason: '读取预览不应触发重洗');
    expect(order.remainingAfter(1), [second, third]);
  });

  test('reset(0) 清空；单曲队列 next 返回自身', () {
    final order = PlaybackShuffleOrder(random: Random(3))..reset(0);
    expect(order.isEmpty, isTrue);
    expect(order.remainingAfter(0), isEmpty);

    order.reset(1, startIndex: 0);
    expect(order.next(0), 0);
    expect(order.peekNext(0), isNull);
  });

  group('extend（队列追加）', () {
    test('老歌保持原顺序在前，追加下标随机分布在后且恰好一次', () {
      final order = PlaybackShuffleOrder(random: Random(5))
        ..reset(3, startIndex: 0);
      final before = order.remainingAfter(0);

      order.extend(3, 6);

      final rest = order.remainingAfter(0);
      expect(rest.sublist(0, before.length), before,
          reason: '当前轮先放完老歌，顺序不被打乱');
      final appended = rest.sublist(before.length);
      expect(appended.toSet(), {3, 4, 5});
      expect(appended, hasLength(3));
    });

    test('扩展后轮末重洗覆盖全队列（追加曲目可播）', () {
      final order = PlaybackShuffleOrder(random: Random(9))
        ..reset(2, startIndex: 0);
      order.extend(2, 4);

      // 走完当前轮（老歌 + 追加歌），轮末 next 重洗新一轮。
      final played = <int>{0};
      var current = 0;
      for (var i = 0; i < 3; i++) {
        current = order.next(current);
        played.add(current);
      }
      expect(played, {0, 1, 2, 3}, reason: '一轮覆盖含追加曲目');
    });

    test('空排列 / 长度不匹配保守跳过', () {
      final order = PlaybackShuffleOrder(random: Random(1));
      order.extend(0, 3);
      expect(order.isEmpty, isTrue, reason: '未洗牌时跳过（后续 reset 重建）');

      order.reset(3, startIndex: 0);
      order.extend(2, 5);
      expect(order.remainingAfter(0), hasLength(2),
          reason: '队列长度与排列不匹配时不扩展');
    });
  });
}
