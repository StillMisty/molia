/// AI 推荐历史持久化：索引（SharedPreferences）+ 每批一个文件。
///
/// - `ai_dj_history_index_v1`：`{activeBatchId, entries}`（历史页首屏只读索引，
///   体积小，继续放 prefs）；
/// - `<appSupport>/ai_history/<sha1(id)>.json`：完整批次 JSON（曲目 + 未解析项
///   + 元数据）。
///
/// 为什么批次要离开 prefs：prefs 每次 `setString` 都会重写整份偏好文件，而
/// 批次含曲目原始 payload，历史一多就会把小设置写入放大成几百 KB（见
/// pitfalls #93）。文件只承载单批，写入不会波及其它设置。
///
/// LLM 原始返回与实际提示词只存内存：批次 JSON 不包含它们。历史详情懒加载，
/// 启动只读索引 + active 批次。旧版 `ai_dj_history_batch_v1:<id>` 键在首次
/// 读取索引 / 批次时一次性迁移为文件后删除；文件后端不可用时退回旧 prefs 键，
/// 避免受限平台（含不注册 path_provider 的单元测试）丢历史。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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
          ? (json['raw'] as Map).map(
              (key, value) => MapEntry(key.toString(), value),
            )
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
        {'title': item.title, 'artist': item.artist, 'reason': item.reason},
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
        unresolved.add(
          AiRecommendation(
            title: title,
            artist: entry['artist']?.toString() ?? '',
            reason: entry['reason']?.toString() ?? '',
          ),
        );
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
  const AiDjHistoryIndex({required this.entries, this.activeBatchId});

  final List<AiDjHistoryEntry> entries;
  final String? activeBatchId;

  static const AiDjHistoryIndex empty = AiDjHistoryIndex(entries: []);

  AiDjHistoryIndex copyWith({
    List<AiDjHistoryEntry>? entries,
    String? activeBatchId,
    bool clearActive = false,
  }) => AiDjHistoryIndex(
    entries: entries ?? this.entries,
    activeBatchId: clearActive ? null : (activeBatchId ?? this.activeBatchId),
  );
}

/// 历史删除 / 清空的结果：`ok=false` 表示存储失败，调用方保留内存状态。
typedef AiDjHistoryMutationResult = ({bool ok, AiDjHistoryIndex index});

class AiRecommendationStore {
  /// [_preferences] / [clock] / [_directoryProvider] 仅测试注入；生产走
  /// SharedPreferences、系统时钟与应用支持目录。
  AiRecommendationStore({
    this._preferences,
    DateTime Function()? clock,
    this._directoryProvider,
  }) : _clock = clock ?? DateTime.now;

  static const String indexKey = 'ai_dj_history_index_v1';
  static const String batchKeyPrefix = 'ai_dj_history_batch_v1:';

  /// 批次文件子目录名（位于应用支持目录下）。
  static const String batchDirectoryName = 'ai_history';

  final SharedPreferences? _preferences;
  final DateTime Function() _clock;

  /// 覆盖批次文件目录；返回 null 表示「没有文件后端」，调用方退回 prefs。
  final Future<Directory?> Function()? _directoryProvider;

  /// 目录解析只算一次：解析失败后本实例退回旧 prefs 键，避免每次读写都
  /// 重复调用 path_provider（也避免测试里反复走平台通道）。
  Future<Directory?>? _directoryFuture;

  /// 旧 prefs 批次是否已全部迁移；只在全部成功时置位，失败下次读取再试。
  bool _legacyMigrated = false;

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

  /// 读取索引；不存在 / 损坏时返回空索引。
  ///
  /// 读取前先做一次旧载荷迁移：索引还在 prefs 里，历史详情却已换代；必须在
  /// 用户打开历史前把 `<prefix>:<id>` 转成文件，否则删掉旧键后会永久丢批次。
  Future<AiDjHistoryIndex> loadIndex() async {
    try {
      final prefs = await _prefsOrNull();
      if (prefs == null) return AiDjHistoryIndex.empty;
      await _migrateLegacyBatches(prefs);
      return _decodeIndex(prefs.getString(indexKey)) ?? AiDjHistoryIndex.empty;
    } catch (_) {
      return AiDjHistoryIndex.empty;
    }
  }

  /// 按 id 加载完整批次（历史详情懒加载）。
  ///
  /// 文件不存在时回退旧 prefs 键一次：升级后的首个详情请求可能早于索引
  /// 迁移；读到后立即转存文件并删除旧键，后续只读文件。
  Future<StoredAiBatch?> loadBatch(String id) async {
    if (id.isEmpty) return null;
    try {
      final prefs = await _prefsOrNull();
      final directory = await _batchDirectory();
      if (directory != null) {
        final file = File(_batchFilePath(directory, id));
        try {
          if (await file.exists()) {
            final batch = StoredAiBatch.fromJson(
              jsonDecode(await file.readAsString()),
            );
            if (batch != null) return batch;
          }
        } catch (_) {
          // 文件存在但读 / 解析失败：继续尝试旧键（可能还有一份完整副本）。
        }
      }

      if (prefs == null) return null;
      final legacyKey = '$batchKeyPrefix$id';
      final raw = prefs.getString(legacyKey);
      if (raw == null || raw.isEmpty) return null;
      final batch = StoredAiBatch.fromJson(jsonDecode(raw));
      if (batch == null) return null;
      if (directory != null) {
        // 写文件成功才删旧键：失败时旧键仍是唯一副本，下次继续回退。
        if (await _writeBatchFile(directory, id, raw)) {
          await _removeLegacyKey(prefs, id);
        }
      }
      return batch;
    } catch (_) {
      return null;
    }
  }

  /// 写入一批；[makeActive] 为真时同时切换 active（显式生成）。
  ///
  /// 失败时静默返回：调用方的内存状态仍可继续展示与播放。
  Future<void> saveBatch(StoredAiBatch batch, {bool makeActive = false}) =>
      _serialized(() async {
        try {
          final prefs = await _prefsOrNull();
          if (prefs == null) return;
          final raw = jsonEncode(batch.toJson());
          final directory = await _batchDirectory();
          if (directory != null) {
            // 先落载荷、后写索引：索引写失败时旧索引仍引用完整批次；反之
            // 会留下「索引有条目、文件不存在」的坏条目。
            if (!await _writeBatchFile(directory, batch.id, raw)) return;
            // 同一 id 的旧 prefs 载荷已由文件取代，顺手删掉，避免 prefs 里
            // 残留大 JSON 继续被整文件重写放大。删失败时让下次 loadIndex 再试。
            if (!await _removeLegacyKey(prefs, batch.id)) {
              _legacyMigrated = false;
            }
          } else {
            // 目录不可用（极简平台 / 未注册 path_provider 的测试）：退回旧
            // prefs 键，至少不丢历史；生产正常路径永远走文件。
            final saved = await prefs.setString(
              '$batchKeyPrefix${batch.id}',
              raw,
            );
            if (!saved) return;
          }
          var index =
              _decodeIndex(prefs.getString(indexKey)) ??
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
          final trimmed = _trim(index);
          // 先写索引、后删被裁掉的载荷：索引写失败时旧索引仍能找到自己的
          // 批次；留下的多余载荷只是无害的孤儿。
          final wrote = await _writeIndex(prefs, trimmed.index);
          if (!wrote) return;
          await _deleteBatchPayloads(prefs, trimmed.removed);
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
        index.copyWith(activeBatchId: id, clearActive: id == null),
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
          final index =
              _decodeIndex(prefs.getString(indexKey)) ??
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
          // 先写索引、后删载荷：写失败时索引仍引用完整批次，不会出现
          // 「索引有条目、载荷已没」的坏条目；删失败只留下孤儿载荷。
          final wrote = await _writeIndex(prefs, updated);
          if (wrote) await _deleteBatchPayload(prefs, id);
          return (ok: wrote, index: wrote ? updated : index);
        } catch (_) {
          return (ok: false, index: AiDjHistoryIndex.empty);
        }
      });

  /// 清空历史：默认保留 active（及其批次载荷）。
  Future<AiDjHistoryMutationResult> clearHistory() => _serialized(() async {
    try {
      final prefs = await _prefsOrNull();
      if (prefs == null) {
        return (ok: false, index: AiDjHistoryIndex.empty);
      }
      final index =
          _decodeIndex(prefs.getString(indexKey)) ??
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
      final updated = AiDjHistoryIndex(
        entries: keptEntry == null ? const [] : [keptEntry],
        activeBatchId: keptEntry == null ? null : activeId,
      );
      // 同上：先写索引再删非 active 载荷，失败只留孤儿。
      final wrote = await _writeIndex(prefs, updated);
      if (wrote) {
        for (final entry in index.entries) {
          if (entry.id != activeId) {
            await _deleteBatchPayload(prefs, entry.id);
          }
        }
      }
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

  /// 只计算保留后的索引与被裁掉的批次，不碰存储。
  ///
  /// 写序由调用方保证「先写索引、后删载荷」：索引写失败时不能先失去载荷。
  ({AiDjHistoryIndex index, List<AiDjHistoryEntry> removed}) _trim(
    AiDjHistoryIndex index,
  ) {
    final result = trimAiDjHistory(
      index.entries,
      activeBatchId: index.activeBatchId,
      now: _clock(),
    );
    return (
      index: index.copyWith(entries: result.kept),
      removed: result.removed,
    );
  }

  Future<void> _deleteBatchPayloads(
    SharedPreferences prefs,
    Iterable<AiDjHistoryEntry> entries,
  ) async {
    for (final entry in entries) {
      await _deleteBatchPayload(prefs, entry.id);
    }
  }

  /// 删载荷失败只留下孤儿（索引已经写好），不能反过来把成功写成失败。
  Future<void> _deleteBatchPayload(SharedPreferences prefs, String id) async {
    // 先删旧键再删文件：反过来的话，旧键删除失败会让 loadBatch 从旧键把
    // 已删除的批次「复活」。旧键删不掉时保留文件，至少数据完整。
    final legacyRemoved = await _removeLegacyKey(prefs, id);
    if (!legacyRemoved) {
      _legacyMigrated = false;
      return;
    }
    final directory = await _batchDirectory();
    if (directory == null) return;
    try {
      final file = File(_batchFilePath(directory, id));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 孤儿文件无害，下次保存 / 清理会再尝试；索引已经不再引用它。
    }
  }

  /// 一次性迁移旧版 `ai_dj_history_batch_v1:<id>` 键。
  ///
  /// 逐条写文件成功才删旧键：中途失败 / 进程被杀时旧键还在，下次读取继续
  /// 迁移；文件已存在则直接删旧键，避免用更旧的载荷覆盖新文件。
  Future<void> _migrateLegacyBatches(SharedPreferences prefs) async {
    if (_legacyMigrated) return;
    try {
      final legacyKeys = [
        for (final key in prefs.getKeys())
          if (key.startsWith(batchKeyPrefix)) key,
      ];
      if (legacyKeys.isEmpty) {
        _legacyMigrated = true;
        return;
      }
      final directory = await _batchDirectory();
      if (directory == null) return;
      var allMigrated = true;
      for (final key in legacyKeys) {
        final id = key.substring(batchKeyPrefix.length);
        final raw = prefs.getString(key);
        if (id.isEmpty || raw == null) {
          allMigrated = false;
          continue;
        }
        var ready = false;
        try {
          ready = await File(_batchFilePath(directory, id)).exists();
        } catch (_) {
          // 探测失败按未就绪处理，交给写入再试一次。
        }
        ready = ready || await _writeBatchFile(directory, id, raw);
        if (!ready) {
          allMigrated = false;
          continue;
        }
        try {
          final removed = await prefs.remove(key);
          if (!removed) {
            // 平台拒绝删除时旧键还在：不缓存「已迁移」，下次读取再试。
            allMigrated = false;
          }
        } catch (_) {
          // 旧键删除失败：文件已就位，下次读取会再清一次。
          allMigrated = false;
        }
      }
      if (allMigrated) _legacyMigrated = true;
    } catch (_) {
      // 扫描 / 解析失败不阻塞索引读取；旧键还在，下次读取再试。
    }
  }

  Future<bool> _removeLegacyKey(SharedPreferences prefs, String id) async {
    try {
      return await prefs.remove('$batchKeyPrefix$id');
    } catch (_) {
      // 旧键残留不影响文件优先读取，下次保存 / 清理会再尝试。
      return false;
    }
  }

  Future<Directory?> _batchDirectory() =>
      _directoryFuture ??= _resolveBatchDirectory();

  Future<Directory?> _resolveBatchDirectory() async {
    try {
      final provider = _directoryProvider;
      if (provider != null) return await provider();
      return await _defaultBatchDirectory();
    } catch (_) {
      // path_provider 不可用（单元测试 / 极简平台）：调用方退回旧 prefs 键。
      return null;
    }
  }

  static Future<Directory> _defaultBatchDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, batchDirectoryName));
  }

  static String _batchFilePath(Directory directory, String id) {
    // sha1 固定 40 位十六进制：id 可能含 `:` / `/` / `..` 等路径字符，
    // 哈希后既不参与路径解析，也不受文件名长度限制；本地历史碰撞可忽略。
    final name = sha1.convert(utf8.encode(id)).toString();
    return p.join(directory.path, '$name.json');
  }

  /// 原子写入单批：先写同目录临时文件（flush 落盘），再 rename 到正式名。
  ///
  /// rename 在同一文件系统内是原子的：读者只会看到完整 JSON，进程被杀最多
  /// 留下一个 `.tmp` 孤儿，不会读到半截批次。
  Future<bool> _writeBatchFile(
    Directory directory,
    String id,
    String raw,
  ) async {
    final target = File(_batchFilePath(directory, id));
    final temp = File(
      '${target.path}.$pid.'
      '${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await directory.create(recursive: true);
      await temp.writeAsString(raw, flush: true);
      await temp.rename(target.path);
      return true;
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 临时文件清理失败不影响「未写入」的结果。
      }
      return false;
    }
  }
}
