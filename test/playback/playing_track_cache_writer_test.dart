import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/playback/audio_predownload.dart';
import 'package:molia/playback/audio_predownloader.dart';
import 'package:molia/playback/playing_track_cache_writer.dart';
import 'package:molia/sources/source_track.dart';

/// 记录调用的假预下载器：任务永不完成，取消时记录序号。
class _RecordingPredownloader implements AudioPredownloader {
  _RecordingPredownloader({this.skip = false});

  /// true = 模拟「跳过」（已缓存 / 省流 / 非法直链）：不产生任务。
  final bool skip;

  final List<(SourceTrack track, PlayableStream stream, String? quality)>
      calls = [];
  final List<int> cancelled = [];
  int _nextId = 0;

  @override
  Future<AudioPredownloadTask?> predownload({
    required SourceTrack track,
    required PlayableStream stream,
    String? quality,
  }) async {
    calls.add((track, stream, quality));
    if (skip) return null;
    final id = _nextId++;
    return AudioPredownloadTask(
      done: Completer<void>().future,
      onCancel: () => cancelled.add(id),
    );
  }
}

SourceTrack _track(String id) => SourceTrack(
      sourceKey: 'kw',
      origin: 'builtin',
      title: 'Song $id',
      artist: 'Artist',
      album: 'Album',
      raw: {'songmid': id},
    );

void main() {
  test('起播写入：直链 / 音质原样交给预下载器', () async {
    final predownloader = _RecordingPredownloader();
    final writer = PlayingTrackCacheWriter(predownloader: predownloader);

    await writer.start(
      _track('1'),
      stream: PlayableStream(Uri.parse('https://cdn.example/1.mp3')),
      quality: '320k',
    );

    expect(predownloader.calls, hasLength(1));
    expect(predownloader.calls.single.$2.uri.toString(),
        'https://cdn.example/1.mp3');
    expect(predownloader.calls.single.$3, '320k');
    expect(predownloader.cancelled, isEmpty);
  });

  test('取链 headers 原样交给预下载器', () async {
    final predownloader = _RecordingPredownloader();
    final writer = PlayingTrackCacheWriter(predownloader: predownloader);

    await writer.start(
      _track('1'),
      stream: PlayableStream(
        Uri.parse('https://cdn.example/1.m4a'),
        headers: {'Referer': 'https://www.bilibili.com/'},
      ),
    );

    expect(predownloader.calls.single.$2.headers, {
      'Referer': 'https://www.bilibili.com/',
    });
  });

  test('切歌：新写入启动前先取消上一首未完成的任务', () async {
    final predownloader = _RecordingPredownloader();
    final writer = PlayingTrackCacheWriter(predownloader: predownloader);

    await writer.start(_track('1'),
        stream: PlayableStream(Uri.parse('https://cdn.example/1.mp3')));
    await writer.start(_track('2'),
        stream: PlayableStream(Uri.parse('https://cdn.example/2.mp3')));

    expect(predownloader.calls, hasLength(2));
    expect(predownloader.cancelled, [0]);
  });

  test('停止 / 销毁：cancel 取消进行中的写入', () async {
    final predownloader = _RecordingPredownloader();
    final writer = PlayingTrackCacheWriter(predownloader: predownloader);

    await writer.start(_track('1'),
        stream: PlayableStream(Uri.parse('https://cdn.example/1.mp3')));
    writer.cancel();

    expect(predownloader.cancelled, [0]);
    // 重复取消幂等（stop 与 dispose 都调）。
    writer.cancel();
    expect(predownloader.cancelled, [0]);
  });

  test('预下载器跳过（已缓存 / 省流）：无任务可取消', () async {
    final predownloader = _RecordingPredownloader(skip: true);
    final writer = PlayingTrackCacheWriter(predownloader: predownloader);

    await writer.start(_track('1'),
        stream: PlayableStream(Uri.parse('https://cdn.example/1.mp3')));
    writer.cancel();

    expect(predownloader.calls, hasLength(1));
    expect(predownloader.cancelled, isEmpty);
  });

  test('未注入预下载器：start / cancel 都不抛', () async {
    final writer = PlayingTrackCacheWriter();
    await writer.start(_track('1'),
        stream: PlayableStream(Uri.parse('https://cdn.example/1.mp3')));
    writer.cancel();
  });
}
