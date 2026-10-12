/// AI 推荐列表持久化：SharedPreferences 单键 JSON。
///
/// 这份列表就是「今日推荐」：持久、可浏览，发现页 carousel 与 AI 推歌页
/// 共用；「换一批」替换缓存，播放会话不消耗它。曲目按"库内形状"存储
/// （sourceKey + 元数据 + raw payload），载入时经
/// `LibraryProvider.sourceTrackFromRaw` 还原为可播放 Track。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/ai_dj.dart';

/// 持久化的单条推荐（解析成功的曲目）。
class StoredAiBatchItem {
  const StoredAiBatchItem({
    required this.sourceKey,
    required this.songId,
    required this.title,
    required this.artist,
    required this.album,
    required this.reason,
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
  });

  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String reason;
  final String? coverUrl;
  final int? durationMs;
  final Map<String, dynamic> raw;

  Map<String, dynamic> toJson() => {
        'sourceKey': sourceKey,
        'songId': songId,
        'title': title,
        'artist': artist,
        'album': album,
        'reason': reason,
        'coverUrl': coverUrl,
        'durationMs': durationMs,
        'raw': raw,
      };

  static StoredAiBatchItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final sourceKey = json['sourceKey']?.toString() ?? '';
    final songId = json['songId']?.toString() ?? '';
    if (sourceKey.isEmpty || songId.isEmpty) return null;
    return StoredAiBatchItem(
      sourceKey: sourceKey,
      songId: songId,
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      raw: json['raw'] is Map
          ? (json['raw'] as Map)
              .map((key, value) => MapEntry(key.toString(), value))
          : const {},
    );
  }
}

/// 持久化的一批推荐（曲目 + 未解析项 + 生成时间）。
class StoredAiBatch {
  const StoredAiBatch({
    required this.items,
    required this.unresolved,
    required this.generatedAt,
  });

  final List<StoredAiBatchItem> items;
  final List<AiRecommendation> unresolved;
  final DateTime generatedAt;
}

class AiRecommendationStore {
  /// [preferences] 仅测试注入；生产走 [SharedPreferences.getInstance]。
  AiRecommendationStore({SharedPreferences? preferences})
      : _preferences = preferences;

  /// 存储键保留旧名（老版本的"待播批次"缓存可直接作为今日推荐列表恢复）。
  static const String storageKey = 'ai_dj_pending_batch_v1';

  final SharedPreferences? _preferences;

  Future<SharedPreferences?> _prefsOrNull() async {
    try {
      return _preferences ?? await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<StoredAiBatch?> load() async {
    try {
      final prefs = await _prefsOrNull();
      final raw = prefs?.getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final items = <StoredAiBatchItem>[];
      final rawItems = decoded['items'];
      if (rawItems is List) {
        for (final entry in rawItems) {
          final item = StoredAiBatchItem.fromJson(entry);
          if (item != null) items.add(item);
        }
      }
      final unresolved = <AiRecommendation>[];
      final rawUnresolved = decoded['unresolved'];
      if (rawUnresolved is List) {
        for (final entry in rawUnresolved) {
          if (entry is! Map) continue;
          final title = entry['title']?.toString() ?? '';
          if (title.isEmpty) continue;
          unresolved.add(AiRecommendation(
            title: title,
            artist: entry['artist']?.toString() ?? '',
            reason: entry['reason']?.toString() ?? '',
          ));
        }
      }
      final epochMs = (decoded['generatedAt'] as num?)?.toInt() ?? 0;
      if (items.isEmpty && unresolved.isEmpty) return null;
      return StoredAiBatch(
        items: items,
        unresolved: unresolved,
        generatedAt: DateTime.fromMillisecondsSinceEpoch(epochMs),
      );
    } catch (_) {
      // 损坏数据按无缓存处理（下次生成覆盖）。
      return null;
    }
  }

  Future<void> save(AiDjBatch batch) async {
    try {
      final prefs = await _prefsOrNull();
      if (prefs == null) return;
      await prefs.setString(
        storageKey,
        jsonEncode({
          'generatedAt': batch.generatedAt.millisecondsSinceEpoch,
          'items': [
            for (final item in batch.items)
              {
                'sourceKey': item.track.id.sourceKey,
                'songId': item.track.id.id,
                'title': item.track.title,
                'artist': item.track.artists.map((a) => a.name).join(', '),
                'album': item.track.album ?? '',
                'reason': item.source.reason,
                'coverUrl': item.track.artwork?.uri.toString(),
                'durationMs': item.track.duration?.inMilliseconds,
                'raw': item.track.payload,
              },
          ],
          'unresolved': [
            for (final item in batch.unresolved)
              {
                'title': item.title,
                'artist': item.artist,
                'reason': item.reason,
              },
          ],
        }),
      );
    } catch (_) {
      // 持久化失败只影响下次启动的缓存命中，不影响本次展示。
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await _prefsOrNull();
      await prefs?.remove(storageKey);
    } catch (_) {
      // 清除失败：键仍在，下次启动按缓存命中处理。
    }
  }
}
