// LockCachingAudioSource 在 just_audio 中标记为 experimental；本测试就是
// 钉住它的 headers 字段，忽略该标注。
// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
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
    expect(withHeaders, isA<LockCachingAudioSource>());
    expect((withHeaders! as LockCachingAudioSource).headers, headers);

    final withoutHeaders = createCachingAudioSource(
      Uri.parse('https://cdn.example/b.m4a'),
      p.join(dir.path, 'b.m4a'),
    );
    expect(withoutHeaders, isA<LockCachingAudioSource>());
    expect((withoutHeaders! as LockCachingAudioSource).headers, isNull);
  });
}
