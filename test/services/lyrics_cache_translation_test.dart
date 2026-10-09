import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词缓存：翻译 / 罗马音往返 + 旧版本 JSON 兼容。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('翻译/罗马音写入后可读', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);

    await cache.write(
      'fake:1',
      LyricCacheData(
        provider: 'netease',
        lyric: '[00:01]a',
        translation: '[00:01]译',
        roma: '[00:01]romaji',
        timestamp: 1,
      ),
    );
    final read = await cache.read('fake:1');
    expect(read, isNotNull);
    expect(read!.translation, '[00:01]译');
    expect(read.roma, '[00:01]romaji');
  });

  test('旧版本 JSON（无翻译字段）按无扩展行读取', () async {
    SharedPreferences.setMockInitialValues({
      'lyrics_cache_fake:2': jsonEncode({
        'provider': 'qq',
        'lyric': '[00:01]b',
        'ts': 1,
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);

    final read = await cache.read('fake:2');
    expect(read, isNotNull);
    expect(read!.lyric, '[00:01]b');
    expect(read.translation, isNull);
    expect(read.roma, isNull);
  });
}
