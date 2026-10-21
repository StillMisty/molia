/// AI 推荐历史持久化：索引 + 每批一键（SharedPreferences）。
///
/// - `ai_dj_history_index_v1`：`{activeBatchId, entries}`（历史页首屏只读索引）；
/// - `ai_dj_history_batch_v1:<id>`：完整批次 JSON（曲目 + 未解析项 + 元数据）；
/// - 旧键 `ai_dj_pending_batch_v1` 首次加载时迁移为一批（active），迁移成功
///   才删除旧键；失败保留旧键下次再试，不丢数据。
///
/// LLM 原始返回与实际提示词只存内存：批次 JSON 不包含它们。历史详情懒加载，
/// 启动只读索引 + active 批次。
library;

import 'dart:async';
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
    this.sourceName = '',
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
  final String sourceName;
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
        'sourceName': sourceName,
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
      sourceName: json['sourceName']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      raw: json['raw'] is Map
          ? (json['raw'] as Map)
              .map((key, value) => MapEntry(key.toString(), value))
          : const {},
    );
  }
}

/// 持久化的一批推荐（曲目 + 未解析项 + 元数据）。
class StoredAiBatch {
  const StoredAiBatch({
    required this.id,
    required this.items,
    required this.unresolved,
    required this.generatedAt,
    required this.origin,
    this.preferences,
  });

  final String id;
  final List<StoredAiBatchItem> items;
  final List<AiRecommendation> unresolved;
  final DateTime generatedAt;
  final AiDjOrigin origin;
  final AiPreferences? preferences;

  AiDjHistoryEntry toHistoryEntry() => AiDjHistoryEntry(
        id: id,
        generatedAt: generatedAt,
        itemCount: items.length,
        unresolvedCount: unresolved.length,
        origin: origin,
        preferences: preferences,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'generatedAt': generatedAt.millisecondsSinceEpoch,
        'origin': origin.storageValue,
        if (preferences != null) 'preferences': preferences!.toJson(),
        'items': [for (final item in items) item.toJson()],
        'unresolved': [
          for (final item in unresolved)
            {
              'title': item.title,
              'artist': item.artist,
              'reason': item.reason,
            },
        ],
      };

  static StoredAiBatch? fromJson(Object? json) {
    if (json is! Map) return null;
    final items = <StoredAiBatchItem>[];
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final entry in rawItems) {
        final item = StoredAiBatchItem.fromJson(entry);
        if (item != null) items.add(item);
      }
    }
    final unresolved = <AiRecommendation>[];
    final rawUnresolved = json['unresolved'];
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
    final epochMs = (json['generatedAt'] as num?)?.toInt() ?? 0;
    if (items.isEmpty && unresolved.isEmpty) return null;
    final generatedAt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final rawId = json['id']?.toString() ?? '';
    return StoredAiBatch(
      id: rawId.isEmpty ? 'batch-$epochMs' : rawId,
      items: items,
      unresolved: unresolved,
      generatedAt: generatedAt,
      origin: AiDjOrigin.fromStorage(json['origin']),
      preferences: json['preferences'] is Map
          ? AiPreferences.tryFromJson(json['preferences'])
          : null,
    );
  }
}

/// 索引 + active id（历史详情不在其中）。
class AiDjHistoryIndex {
  const AiDjHistoryIndex({
    required this.entries,
    this.activeBatchId,
  });

  final List<AiDjHistoryEntry> entries;
  final String? activeBatchId;

  static const AiDjHistoryIndex empty = AiDjHistoryIndex(entries: []);

  AiDjHistoryIndex copyWith({
    List<AiDjHistoryEntry>? entries,
    String? activeBatchId,
    bool clearActive = false,
  }) =>
      AiDjHistoryIndex(
        entries: entries ?? this.entries,
        activeBatchId:
            clearActive ? null : (activeBatchId ?? this.activeBatchId),
      );
}

/// 历史删除 / 清空的结果：`ok=false` 表示存储失败，调用方保留内存状态。
typedef AiDjHistoryMutationResult = ({bool ok, AiDjHistoryIndex index});

class AiRecommendationStore {
  /// [preferences] / [clock] 仅测试注入；生产走 SharedPreferences 与系统时钟。
  AiRecommendationStore(
      {SharedPreferences? preferences, DateTime Function()? clock})
      : _preferences = preferences,
        _clock = clock ?? DateTime.now;

  static const String indexKey = 'ai_dj_history_index_v1';
  static const String batchKeyPrefix = 'ai_dj_history_batch_v1:';
  static const String legacyStorageKey = 'ai_dj_pending_batch_v1';

  final SharedPreferences? _preferences;
  final DateTime Function() _clock;

  /// 写操作串行化：索引与批次键必须按顺序落盘，避免并发写读旧索引。
  Future<void> _writeQueue = Future<void>.value();

  Future<SharedPreferences?> _prefsOrNull() async {
    try {
      return _preferences ?? await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  /// 读取索引；不存在时尝试迁移旧单批键。
  Future<AiDjHistoryIndex> loadIndex() async {
    try {
      final prefs = await _prefsOrNull();
      if (prefs == null) return AiDjHistoryIndex.empty;
      final decoded = _decodeIndex(prefs.getString(indexKey));
      if (decoded != null) return decoded;
      return await _migrateLegacy(prefs);
    } catch (_) {
      return AiDjHistoryIndex.empty;
    }
  }

  /// 按 id 加载完整批次（历史详情懒加载）。
  Future<StoredAiBatch?> loadBatch(String id) async {
    if (id.isEmpty) return null;
    try {
      final prefs = await _prefsOrNull();
      final raw = prefs?.getString('$batchKeyPrefix$id');
      if (raw == null || raw.isEmpty) return null;
      return StoredAiBatch.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 写入一批；[makeActive] 为真时同时切换 active（显式生成）。
  ///
  /// 失败时静默返回：调用方的内存状态仍可继续展示与播放。
  Future<void> saveBatch(
    StoredAiBatch batch, {
    bool makeActive = false,
  }) =>
      _serialized(() async {
        try {
          final prefs = await _prefsOrNull();
          if (prefs == null) return;
          final saved = await prefs.setString(
            '$batchKeyPrefix${batch.id}',
            jsonEncode(batch.toJson()),
          );
          if (!saved) return;
          var index = _decodeIndex(prefs.getString(indexKey)) ??
              const AiDjHistoryIndex(entries: []);
          final entries = [
            for (final entry in index.entries)
              if (entry.id != batch.id) entry,
            batch.toHistoryEntry(),
          ];
          index = index.copyWith(
            entries: entries,
            activeBatchId: makeActive ? batch.id : index.activeBatchId,
          );
          index = await _trim(prefs, index);
          await _writeIndex(prefs, index);
        } catch (_) {
          // 持久化失败降级为内存状态。
        }
      });

  /// 切换 active（只动浏览列表，不动队列）。
  Future<void> setActive(String? id) => _serialized(() async {
        try {
          final prefs = await _prefsOrNull();
          if (prefs == null) return;
          final index = _decodeIndex(prefs.getString(indexKey));
          if (index == null) return;
          await _writeIndex(
            prefs,
            index.copyWith(
              activeBatchId: id,
              clearActive: id == null,
            ),
          );
        } catch (_) {
          // 失败保持原 active。
        }
      });

  /// 删除一批（含 active 时回退到最近一批）。
  Future<AiDjHistoryMutationResult> deleteBatch(String id) =>
      _serialized(() async {
        try {
          final prefs = await _prefsOrNull();
          if (prefs == null) {
            return (ok: false, index: AiDjHistoryIndex.empty);
          }
          final index = _decodeIndex(prefs.getString(indexKey)) ??
              const AiDjHistoryIndex(entries: []);
          final remaining = [
            for (final entry in index.entries)
              if (entry.id != id) entry,
          ]..sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
          var activeId = index.activeBatchId;
          if (activeId == id) {
            activeId = remaining.isEmpty ? null : remaining.first.id;
          }
          final updated = AiDjHistoryIndex(
            entries: remaining,
            activeBatchId: activeId,
          );
          await prefs.remove('$batchKeyPrefix$id');
          final wrote = await _writeIndex(prefs, updated);
          return (ok: wrote, index: wrote ? updated : index);
        } catch (_) {
          return (ok: false, index: AiDjHistoryIndex.empty);
        }
      });

  /// 清空历史：默认保留 active（及其批次键）。
  Future<AiDjHistoryMutationResult> clearHistory() => _serialized(() async {
        try {
          final prefs = await _prefsOrNull();
          if (prefs == null) {
            return (ok: false, index: AiDjHistoryIndex.empty);
          }
          final index = _decodeIndex(prefs.getString(indexKey)) ??
              const AiDjHistoryIndex(entries: []);
          final activeId = index.activeBatchId;
          AiDjHistoryEntry? keptEntry;
          if (activeId != null) {
            for (final entry in index.entries) {
              if (entry.id == activeId) {
                keptEntry = entry;
                break;
              }
            }
          }
          for (final entry in index.entries) {
            if (entry.id != activeId) {
              await prefs.remove('$batchKeyPrefix${entry.id}');
            }
          }
          final updated = AiDjHistoryIndex(
            entries: keptEntry == null ? const [] : [keptEntry],
            activeBatchId: keptEntry == null ? null : activeId,
          );
          final wrote = await _writeIndex(prefs, updated);
          return (ok: wrote, index: wrote ? updated : index);
        } catch (_) {
          return (ok: false, index: AiDjHistoryIndex.empty);
        }
      });

  AiDjHistoryIndex? _decodeIndex(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final entries = <AiDjHistoryEntry>[];
      final rawEntries = decoded['entries'];
      if (rawEntries is List) {
        for (final entry in rawEntries) {
          final parsed = AiDjHistoryEntry.fromJson(entry);
          if (parsed != null) entries.add(parsed);
        }
      }
      entries.sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
      final activeId = decoded['activeBatchId']?.toString();
      return AiDjHistoryIndex(
        entries: entries,
        activeBatchId: activeId == null || activeId.isEmpty ? null : activeId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<AiDjHistoryIndex> _migrateLegacy(SharedPreferences prefs) async {
    final raw = prefs.getString(legacyStorageKey);
    if (raw == null || raw.isEmpty) return AiDjHistoryIndex.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return AiDjHistoryIndex.empty;
      final generatedAt = (decoded['generatedAt'] as num?)?.toInt() ?? 0;
      final legacy = StoredAiBatch.fromJson({
        ...decoded.cast<String, dynamic>(),
        'id': 'restored-$generatedAt',
        'origin': AiDjOrigin.restored.storageValue,
      });
      if (legacy == null) return AiDjHistoryIndex.empty;
      final saved = await prefs.setString(
        '$batchKeyPrefix${legacy.id}',
        jsonEncode(legacy.toJson()),
      );
      if (!saved) return AiDjHistoryIndex.empty;
      final index = AiDjHistoryIndex(
        entries: [legacy.toHistoryEntry()],
        activeBatchId: legacy.id,
      );
      final wroteIndex = await _writeIndex(prefs, index);
      if (!wroteIndex) {
        await prefs.remove('$batchKeyPrefix${legacy.id}');
        return AiDjHistoryIndex.empty;
      }
      // 全部写成功后才删旧键；失败保留旧键下次再试。
      await prefs.remove(legacyStorageKey);
      return index;
    } catch (_) {
      return AiDjHistoryIndex.empty;
    }
  }

  Future<bool> _writeIndex(
    SharedPreferences prefs,
    AiDjHistoryIndex index,
  ) async {
    try {
      return await prefs.setString(
        indexKey,
        jsonEncode({
          'activeBatchId': index.activeBatchId,
          'entries': [for (final entry in index.entries) entry.toJson()],
        }),
      );
    } catch (_) {
      return false;
    }
  }

  Future<AiDjHistoryIndex> _trim(
    SharedPreferences prefs,
    AiDjHistoryIndex index,
  ) async {
    final result = trimAiDjHistory(
      index.entries,
      activeBatchId: index.activeBatchId,
      now: _clock(),
    );
    for (final entry in result.removed) {
      await prefs.remove('$batchKeyPrefix${entry.id}');
    }
    return index.copyWith(entries: result.kept);
  }
}
