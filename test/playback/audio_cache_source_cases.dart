// LockCachingAudioSource 在 just_audio 中标记为 experimental；本测试就是
// 钉住它的 headers 字段，忽略该标注。
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:molia/playback/audio_cache_completion.dart';
import 'package:molia/playback/audio_cache_source.dart';
import 'package:path/path.dart' as p;

/// 边播边缓存源的请求头透传：B 站直链离开 `Referer` / `UA` 会 403，
/// 移动端主路径（`LockCachingAudioSource`）不能比直接流播少头部。
void main() {
  test('headers 原样交给 LockCachingAudioSource；空 headers 为 null', () {
    final dir = Directory.systemTemp.createTempSync('molia_cache_source');
    addTearDown(() => dir.deleteSync(recursive: true));
    const headers = {
      'Referer': 'https://www.bilibili.com/',
      'User-Agent': 'Mozilla/5.0',
    };

    final withHeaders = createCachingAudioSource(
      Uri.parse('https://cdn.example/a.m4a'),
      p.join(dir.path, 'a.m4a'),
      headers: headers,
    );
    expect(withHeaders, isNotNull);
    expect(withHeaders!.source, isA<LockCachingAudioSource>());
    expect((withHeaders.source as LockCachingAudioSource).headers, headers);
    withHeaders.cancel();

    final withoutHeaders = createCachingAudioSource(
      Uri.parse('https://cdn.example/b.m4a'),
      p.join(dir.path, 'b.m4a'),
    );
    expect(withoutHeaders, isNotNull);
    expect(withoutHeaders!.source, isA<LockCachingAudioSource>());
    expect((withoutHeaders.source as LockCachingAudioSource).headers, isNull);
    withoutHeaders.cancel();
  });

  group('缓存完成信号', () {
    late StreamController<double> progress;
    late AudioSource source;

    setUp(() {
      progress = StreamController<double>.broadcast();
      source = AudioSource.uri(Uri.parse('https://cdn.example/a.m4a'));
    });

    tearDown(() => progress.close());

    test('进度 100% 且最终文件存在才完成 true', () async {
      var exists = false;
      final handle = watchCachingAudioSource(
        source: source,
        progress: progress.stream,
        fileExists: () => exists,
        retryDelay: const Duration(milliseconds: 1),
        retries: 3,
      );

      progress.add(1.0);
      // 100% 与原子改名之间允许一个事件循环：第一次检查还没文件。
      exists = true;

      expect(await handle.completed, isTrue);
    });

    test('进度 100% 但最终文件始终不存在：按未完成处理', () async {
      final handle = watchCachingAudioSource(
        source: source,
        progress: progress.stream,
        fileExists: () => false,
        retryDelay: const Duration(milliseconds: 1),
        retries: 2,
      );

      progress.add(1.0);

      expect(await handle.completed, isFalse);
    });

    test('失败 / 取消不完成成功', () async {
      final failed = watchCachingAudioSource(
        source: source,
        progress: progress.stream,
        fileExists: () => true,
      );
      progress.addError(StateError('network'));

      expect(await failed.completed, isFalse);

      final cancelled = watchCachingAudioSource(
        source: source,
        progress: StreamController<double>.broadcast().stream,
        fileExists: () => true,
      );
      cancelled.cancel();

      expect(await cancelled.completed, isFalse);
    });
  });
}
