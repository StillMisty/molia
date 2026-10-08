import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'cache_storage.dart' show CacheUsage;
import 'lyrics/lyric_provider.dart' show LyricCacheData;

/// 歌词缓存（键 / 读写 / 用量 / 清理）的唯一实现。
///
/// - 规范键：`lyrics_cache_{trackId}`（值与 [LyricCacheData] JSON 一致）；
/// - TTL 策略属于 `CacheService`（取词时读取），本模块只负责存取；
/// - 历史版本在歌词搜索页额外写过一份 `manual_lyrics_cache_*` 重复键：
///   读取一律以规范键为准，[clear] 时连同历史键一起清除（只清不读）。
class LyricsCache {
  LyricsCache({SharedPreferences? prefs}) : _prefsOverride = prefs;

  static const String keyPrefix = 'lyrics_cache_';

  /// 历史遗留的重复键前缀（只清不读）。
  static const String legacyManualKeyPrefix = 'manual_lyrics_cache_';

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;

  /// 读取条目；不存在 / 损坏 / prefs 不可用时返回 null（按未命中处理）。
  Future<LyricCacheData?> read(String trackId) async {
    final prefs = await _prefsOrNull();
    final raw = prefs?.getString('$keyPrefix$trackId');
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      return LyricCacheData.fromJson(json.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// 写入规范键。
  Future<void> write(String trackId, LyricCacheData data) async {
    final prefs = await _prefsOrNull();
    await prefs?.setString('$keyPrefix$trackId', json.encode(data.toJson()));
  }

  /// 歌词分区用量（只统计规范键；历史重复键不算用量）。
  Future<CacheUsage> usage() async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return CacheUsage.zero;
    var bytes = 0;
    var count = 0;
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(keyPrefix)) continue;
      final value = prefs.getString(key);
      if (value == null) continue;
      bytes += utf8.encode(value).length;
      count++;
    }
    return CacheUsage(bytes: bytes, count: count);
  }

  /// 清除歌词分区：规范键 + 历史重复键。
  Future<void> clear() async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final keys = prefs
        .getKeys()
        .where((key) =>
            key.startsWith(keyPrefix) ||
            key.startsWith(legacyManualKeyPrefix))
        .toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  Future<SharedPreferences?> _prefsOrNull() async {
    if (_prefsOverride != null) return _prefsOverride;
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }
}
