/// 自定义封面存储：每曲封面 + 全局默认封面（设备本地）。
///
/// 设计约束：
/// - 文件放在应用支持目录的 `custom_covers/`，**不进封面缓存**——清理缓存
///   不会删除用户选的封面；
/// - 每次替换都写新文件名（时间戳 + 自增序号）：同名覆盖会让 Flutter
///   ImageCache / 取色 LRU 继续命中旧图；
/// - 索引（路径 + 内容哈希 + 更新时间）落在 SharedPreferences，启动只读
///   索引并剔除丢失文件，不解码图片；
/// - 曲目键 = `sourceKey:songId`；`local` 下载副本剥掉一层 `local:` 前缀，
///   让下载前设置的自定义封面继续作用于本地副本（本地导入行的记录键是
///   `local:<path>`，同样保持不动）；
/// - 查询是同步的（[load] 之后），UI 通过 [revision] 感知变化；组合根另可
///   注册 [addChangeListener] 刷新当前播放 / 主题 / 系统媒体。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/download.dart' show kLocalSourceKey;
import '../../domain/models/track.dart';

/// 自定义封面变化类型（组合根按它决定刷新哪些展示面）。
enum CustomCoverChangeKind {
  /// 单曲封面替换 / 重置。
  track,

  /// 全局默认封面替换 / 重置。
  defaultCover,
}

/// 一次自定义封面变化。
@immutable
class CustomCoverChange {
  const CustomCoverChange({required this.kind, this.trackId, this.path});

  final CustomCoverChangeKind kind;

  /// 单曲封面所属曲目；默认封面变化时为 null。
  final TrackId? trackId;

  /// 新文件的绝对路径；重置时为 null。
  final String? path;

  bool get isDefaultCover => kind == CustomCoverChangeKind.defaultCover;
}

/// 索引条目（持久化形状）。
@immutable
class CustomCoverEntry {
  const CustomCoverEntry({
    required this.path,
    required this.hash,
    required this.updatedAt,
  });

  /// 封面文件绝对路径。
  final String path;

  /// 归一化后图片字节的 SHA-256（同步 / 备份等后续用途的稳定标识）。
  final String hash;

  /// 写入时间（毫秒时间戳）。
  final int updatedAt;

  Map<String, Object?> toJson() => {
        'path': path,
        'hash': hash,
        'updatedAt': updatedAt,
      };

  static CustomCoverEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final hash = raw['hash'];
    final updatedAt = raw['updatedAt'];
    if (path is! String || path.isEmpty) return null;
    return CustomCoverEntry(
      path: path,
      hash: hash is String ? hash : '',
      updatedAt: updatedAt is int ? updatedAt : 0,
    );
  }
}

/// 自定义封面存储（单例入口 [instance]；测试可 [overrideInstance]）。
class CustomCoverStore {
  CustomCoverStore({
    Future<SharedPreferences> Function()? preferences,
    Future<Directory> Function()? supportDirectory,
    DateTime Function()? clock,
  })  : _preferences = preferences ?? SharedPreferences.getInstance,
        _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _clock = clock ?? DateTime.now;

  static CustomCoverStore _instance = CustomCoverStore();

  /// 全应用共享实例（与 `ArtworkCache.instance` 同一模式）。
  static CustomCoverStore get instance => _instance;

  /// 测试替换实例；传 null 恢复默认实例。
  @visibleForTesting
  static void overrideInstance(CustomCoverStore? store) {
    _instance = store ?? CustomCoverStore();
  }

  static const String prefsKey = 'custom_cover_index_v1';
  static const String directoryName = 'custom_covers';

  final Future<SharedPreferences> Function() _preferences;
  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _clock;

  /// UI 订阅通道：任何替换 / 重置都会自增。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final List<void Function(CustomCoverChange)> _changeListeners = [];
  final Map<String, CustomCoverEntry> _tracks = {};
  CustomCoverEntry? _defaultCover;

  Future<void>? _loadFuture;
  int _writeSequence = 0;
  bool _loaded = false;

  /// 索引是否已读入（未 load 时所有查询返回空）。
  bool get isLoaded => _loaded;

  /// 读取索引并剔除已丢失的文件（幂等；启动只调用一次）。
  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await _preferences();
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final tracks = decoded['tracks'];
          if (tracks is Map) {
            for (final entry in tracks.entries) {
              final parsed = CustomCoverEntry.fromJson(entry.value);
              if (parsed != null) _tracks[entry.key.toString()] = parsed;
            }
          }
          _defaultCover = CustomCoverEntry.fromJson(decoded['default']);
        }
      }
    } catch (e) {
      // 索引损坏 / prefs 不可用：按空索引启动，不阻断首帧。
      debugPrint('[Molia] 读取自定义封面索引失败: $e');
      _tracks.clear();
      _defaultCover = null;
    }

    var pruned = false;
    for (final entry in _tracks.entries.toList()) {
      if (!await _fileExists(entry.value.path)) {
        _tracks.remove(entry.key);
        pruned = true;
      }
    }
    final defaultCover = _defaultCover;
    if (defaultCover != null && !await _fileExists(defaultCover.path)) {
      _defaultCover = null;
      pruned = true;
    }
    if (pruned) {
      try {
        await _persist();
      } catch (e) {
        debugPrint('[Molia] 清理自定义封面索引失败: $e');
      }
    }
    _loaded = true;
    _bumpRevision();
  }

  /// 注册变化回调（返回取消函数）。
  void Function() addChangeListener(void Function(CustomCoverChange) listener) {
    _changeListeners.add(listener);
    return () => _changeListeners.remove(listener);
  }

  /// 规范曲目键：`local` 下载副本剥掉一层 `local:` 前缀。
  ///
  /// `TrackId(kLocalSourceKey, 'wy:123')` → `wy:123`（下载前的原曲键）；
  /// 本地导入 `TrackId(kLocalSourceKey, 'local:/path')` → `local:/path`
  /// （记录键本身，不再二次剥离）。
  static String coverKeyOf(TrackId id) =>
      id.sourceKey == kLocalSourceKey ? id.id : id.uri;

  /// 字符串形态的规范化（只认 `TrackId.uri` 形状）。
  static String normalizeCoverKey(String key) =>
      key.startsWith('$kLocalSourceKey:')
          ? key.substring(kLocalSourceKey.length + 1)
          : key;

  /// 曲目自定义封面文件路径（未设置为 null）。
  String? trackCoverPath(TrackId id) {
    final entry = _tracks[coverKeyOf(id)];
    return entry?.path;
  }

  /// 曲目自定义封面 `file://` 地址（未设置为 null）。
  String? trackCoverUrl(TrackId id) {
    final path = trackCoverPath(id);
    return path == null ? null : Uri.file(path).toString();
  }

  /// 全局默认封面 `file://` 地址；null = 显示 Molia 标志。
  String? get defaultCoverUrl {
    final path = _defaultCover?.path;
    return path == null ? null : Uri.file(path).toString();
  }

  /// 按原始曲目键查询自定义封面（`TrackRowModel.coverKey` 入口）。
  String? trackCoverUrlForKey(String? coverKey) {
    if (coverKey == null || coverKey.isEmpty) return null;
    final entry = _tracks[normalizeCoverKey(coverKey)];
    return entry == null ? null : Uri.file(entry.path).toString();
  }

  /// 曲目封面：自定义优先，否则原始封面（不含默认封面）。
  ///
  /// 取色链路只认这条（默认封面是占位，不参与取色 / 下载 / 标签）。
  String? resolveTrackCover(Track? track) => resolveTrackCoverForId(
        track?.id,
        originalUrl: track?.artwork?.uri.toString(),
      );

  /// 按 [TrackId] 解析曲目封面（自定义优先，否则原始 URL）。
  String? resolveTrackCoverForId(TrackId? id, {String? originalUrl}) {
    final custom = id == null ? null : trackCoverUrl(id);
    return custom ?? _nonEmpty(originalUrl);
  }

  /// 按字符串曲目键解析曲目封面（自定义优先，否则原始 URL）。
  String? resolveTrackCoverForKey(String? coverKey, {String? originalUrl}) =>
      trackCoverUrlForKey(coverKey) ?? _nonEmpty(originalUrl);

  /// 展示封面：自定义 → 原始封面 → 全局默认封面。
  String? resolveForDisplay(Track? track) => resolveForDisplayById(
        track?.id,
        originalUrl: track?.artwork?.uri.toString(),
      );

  /// 按 [TrackId] 解析展示封面（见 [resolveForDisplay]）。
  String? resolveForDisplayById(TrackId? id, {String? originalUrl}) =>
      resolveTrackCoverForId(id, originalUrl: originalUrl) ?? defaultCoverUrl;

  /// 按字符串曲目键解析展示封面（见 [resolveForDisplay]）。
  String? resolveForDisplayForKey(String? coverKey, {String? originalUrl}) =>
      resolveTrackCoverForKey(coverKey, originalUrl: originalUrl) ??
      defaultCoverUrl;

  /// 读取曲目自定义封面字节（不存在 / 不可读返回 null）。
  Future<Uint8List?> readTrackCover(TrackId id) =>
      _readFile(trackCoverPath(id));

  /// 读取全局默认封面字节（不存在 / 不可读返回 null）。
  Future<Uint8List?> readDefaultCover() => _readFile(_defaultCover?.path);

  /// 保存曲目封面（[bytes] 应已由 `CoverImageCodec` 归一化）。
  Future<void> setTrackCover(TrackId id, Uint8List bytes) async {
    final key = coverKeyOf(id);
    final old = _tracks[key];
    final entry = await _writeEntry(
      filePrefix: 'track_${_shortHash(key)}',
      bytes: bytes,
    );
    _tracks[key] = entry;
    try {
      await _persist();
    } catch (e) {
      // 落盘失败：回滚内存与文件，避免「本次会话有效、重启消失」的假成功。
      if (old == null) {
        _tracks.remove(key);
      } else {
        _tracks[key] = old;
      }
      await _deleteQuietly(entry.path);
      rethrow;
    }
    if (old != null && old.path != entry.path) {
      await _deleteQuietly(old.path);
    }
    _notify(
      CustomCoverChange(
        kind: CustomCoverChangeKind.track,
        trackId: id,
        path: entry.path,
      ),
    );
  }

  /// 恢复曲目原始封面（没有自定义封面时为空操作）。
  Future<void> resetTrackCover(TrackId id) async {
    final key = coverKeyOf(id);
    final old = _tracks.remove(key);
    if (old == null) return;
    try {
      await _persist();
    } catch (e) {
      _tracks[key] = old;
      rethrow;
    }
    await _deleteQuietly(old.path);
    _notify(CustomCoverChange(kind: CustomCoverChangeKind.track, trackId: id));
  }

  /// 保存全局默认封面（[bytes] 应已由 `CoverImageCodec` 归一化）。
  Future<void> setDefaultCover(Uint8List bytes) async {
    final old = _defaultCover;
    final entry = await _writeEntry(filePrefix: 'default', bytes: bytes);
    _defaultCover = entry;
    try {
      await _persist();
    } catch (e) {
      _defaultCover = old;
      await _deleteQuietly(entry.path);
      rethrow;
    }
    if (old != null && old.path != entry.path) {
      await _deleteQuietly(old.path);
    }
    _notify(
      CustomCoverChange(
        kind: CustomCoverChangeKind.defaultCover,
        path: entry.path,
      ),
    );
  }

  /// 恢复默认封面为 Molia 标志（没有自定义默认封面时为空操作）。
  Future<void> resetDefaultCover() async {
    final old = _defaultCover;
    if (old == null) return;
    _defaultCover = null;
    try {
      await _persist();
    } catch (e) {
      _defaultCover = old;
      rethrow;
    }
    await _deleteQuietly(old.path);
    _notify(const CustomCoverChange(kind: CustomCoverChangeKind.defaultCover));
  }

  /// 换源时把旧曲目的自定义封面复制到新曲目键（非破坏性，旧封面保留）。
  ///
  /// 返回是否复制成功；源没有自定义封面时为空操作。文件 / 索引错误只记
  /// 日志——换源本身已经成功，封面跟随是增强项。
  Future<bool> carryOver(Track oldTrack, Track newTrack) async {
    final oldKey = coverKeyOf(oldTrack.id);
    final newKey = coverKeyOf(newTrack.id);
    if (oldKey == newKey) return false;
    final source = _tracks[oldKey];
    if (source == null) return false;
    try {
      final bytes = await File(source.path).readAsBytes();
      if (bytes.isEmpty) return false;
      await setTrackCover(newTrack.id, bytes);
      return true;
    } catch (e) {
      debugPrint('[Molia] 换源复制自定义封面失败: $e');
      return false;
    }
  }

  Future<CustomCoverEntry> _writeEntry({
    required String filePrefix,
    required Uint8List bytes,
  }) async {
    final directory = await _coverDirectory();
    final stamp = _clock().microsecondsSinceEpoch;
    final name = '${filePrefix}_${stamp}_${_writeSequence++}.jpg';
    final file = File('${directory.path}/$name');
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
    return CustomCoverEntry(
      path: file.path,
      hash: sha256.convert(bytes).toString(),
      updatedAt: _clock().millisecondsSinceEpoch,
    );
  }

  Future<Directory> _coverDirectory() async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/$directoryName');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> _persist() async {
    final prefs = await _preferences();
    await prefs.setString(
      prefsKey,
      jsonEncode({
        'version': 1,
        'tracks': {
          for (final entry in _tracks.entries) entry.key: entry.value.toJson(),
        },
        if (_defaultCover != null) 'default': _defaultCover!.toJson(),
      }),
    );
  }

  Future<bool> _fileExists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> _readFile(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败只留下不可达的残留文件，不影响当前选择。
    }
  }

  void _bumpRevision() {
    revision.value = revision.value + 1;
  }

  void _notify(CustomCoverChange change) {
    _bumpRevision();
    for (final listener in List<void Function(CustomCoverChange)>.of(
      _changeListeners,
    )) {
      listener(change);
    }
  }

  static String _shortHash(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 12);

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}
