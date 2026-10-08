import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词缓存模块（唯一所有者）的测试面。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('write/read 往返（规范键）', () async {
    final cache = LyricsCache();
    await cache.write(
      'kw:1',
      LyricCacheData(provider: 'netease', lyric: '[00:01]hi', timestamp: 123),
    );
    final entry = await cache.read('kw:1');
    expect(entry, isNotNull);
    expect(entry!.provider, 'netease');
    expect(entry.lyric, '[00:01]hi');
    expect(entry.timestamp, 123);
  });

  test('损坏条目按未命中处理', () async {
    SharedPreferences.setMockInitialValues({'lyrics_cache_x': 'not-json'});
    expect(await LyricsCache().read('x'), isNull);
  });

  test('usage 只统计规范键（历史 manual 键不算用量）', () async {
    SharedPreferences.setMockInitialValues({
      'lyrics_cache_a': '{"provider":"qq","lyric":"x","timestamp":1}',
      'manual_lyrics_cache_a': '{"provider":"qq","lyric":"x","timestamp":1}',
    });
    final usage = await LyricsCache().usage();
    expect(usage.count, 1);
    expect(usage.bytes, greaterThan(0));
  });

  test('clear 同时清理规范键与历史 manual 键，不碰其它键', () async {
    SharedPreferences.setMockInitialValues({
      'lyrics_cache_a': '{}',
      'manual_lyrics_cache_a': '{}',
      'other_key': 'keep',
    });
    await LyricsCache().clear();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('lyrics_cache_a'), isFalse);
    expect(prefs.containsKey('manual_lyrics_cache_a'), isFalse);
    expect(prefs.getString('other_key'), 'keep');
  });
}
