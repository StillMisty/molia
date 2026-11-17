import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:molia/playback/audio_cache_completion.dart';
import 'package:molia/playback/audio_cache_completion_recorder.dart';
import 'package:molia/sources/source_track.dart';

SourceTrack _track(String id) => SourceTrack(
  sourceKey: 'wy',
  origin: 'builtin',
  title: 'Song $id',
  artist: 'Artist',
  album: 'Album',
  raw: {'songId': id},
);

class _FakeHandle {
  final Completer<bool> completed = Completer<bool>();
  bool cancelled = false;

  late final CachingAudioSourceHandle handle = CachingAudioSourceHandle(
    source: AudioSource.uri(Uri.parse('https://cdn.example/x.mp3')),
    completed: completed.future,
    cancel: () {
      cancelled = true;
      if (!completed.isCompleted) completed.complete(false);
    },
  );

  void finish(bool value) {
    if (!completed.isCompleted) completed.complete(value);
  }
}

void main() {
  test('完成 true 才回调；false 静默丢弃', () async {
    final done = <String>[];
    final recorder = AudioCacheCompletionRecorder(
      onCompleted: (track) => done.add(track.id),
    );
    addTearDown(recorder.dispose);

    final ok = _FakeHandle();
    final failed = _FakeHandle();
    recorder.record(_track('ok'), ok.handle);
    recorder.record(_track('failed'), failed.handle);

    failed.finish(false);
    await pumpEventQueue();
    expect(done, isEmpty);
    expect(recorder.pendingCount, 1);

    ok.finish(true);
    await pumpEventQueue();
    expect(done, ['wy:ok']);
    expect(recorder.pendingCount, 0);
  });

  test('切歌后旧缓存完成仍回调（不再取消完成监听）', () async {
    final done = <String>[];
    final recorder = AudioCacheCompletionRecorder(
      onCompleted: (track) => done.add(track.id),
    );
    addTearDown(recorder.dispose);

    final first = _FakeHandle();
    final second = _FakeHandle();
    recorder.record(_track('first'), first.handle);
    // 模拟切歌：旧 handle 没有被 cancel，直接开始下一首的记录。
    recorder.record(_track('second'), second.handle);
    expect(first.cancelled, isFalse);
    expect(recorder.pendingCount, 2);

    first.finish(true);
    await pumpEventQueue();
    expect(done, ['wy:first'], reason: '切歌不能丢旧曲目的完成事件');

    second.finish(true);
    await pumpEventQueue();
    expect(done, ['wy:first', 'wy:second']);
  });

  test('超时取消 handle 且迟到完成不回调', () async {
    final done = <String>[];
    final recorder = AudioCacheCompletionRecorder(
      onCompleted: (track) => done.add(track.id),
      timeout: const Duration(milliseconds: 20),
    );
    addTearDown(recorder.dispose);
    final handle = _FakeHandle();

    recorder.record(_track('slow'), handle.handle);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(handle.cancelled, isTrue);
    expect(recorder.pendingCount, 0);
    expect(done, isEmpty);

    handle.finish(true);
    await pumpEventQueue();
    expect(done, isEmpty, reason: '超时后迟到的完成不能写索引');
  });

  test('dispose 取消全部 pending 且不再回调', () async {
    final done = <String>[];
    final recorder = AudioCacheCompletionRecorder(
      onCompleted: (track) => done.add(track.id),
    );
    final first = _FakeHandle();
    final second = _FakeHandle();
    recorder.record(_track('1'), first.handle);
    recorder.record(_track('2'), second.handle);

    recorder.dispose();
    expect(first.cancelled, isTrue);
    expect(second.cancelled, isTrue);
    expect(recorder.pendingCount, 0);

    first.finish(true);
    second.finish(true);
    await pumpEventQueue();
    expect(done, isEmpty);
  });

  test('pending 超限时取消最旧 handle，保留较新的', () async {
    final done = <String>[];
    final recorder = AudioCacheCompletionRecorder(
      onCompleted: (track) => done.add(track.id),
      maxPending: 2,
    );
    addTearDown(recorder.dispose);
    final first = _FakeHandle();
    final second = _FakeHandle();
    final third = _FakeHandle();

    recorder.record(_track('1'), first.handle);
    recorder.record(_track('2'), second.handle);
    recorder.record(_track('3'), third.handle);

    expect(first.cancelled, isTrue);
    expect(second.cancelled, isFalse);
    expect(third.cancelled, isFalse);
    expect(recorder.pendingCount, 2);

    second.finish(true);
    await pumpEventQueue();
    expect(done, ['wy:2']);
  });
}
