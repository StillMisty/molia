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
///   注册 [addChangeListener] 刷新当前播放 / 主题 / 系统媒体；
/// - 同步面（`CoverSyncAdapter`）经 [trackEntries] / [defaultEntry] 枚举，
///   经 [applySyncedTrackCover] 等写入远端结果；远端写入**不**触发
///   [onLocalChange]，避免同步回环。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/files/app_data_directory.dart';
import '../../domain/models/track.dart';
import 'cover_image_format.dart';
import 'cover_resolution.dart' as cover_resolution;

/// 自定义封面变化类型（组合根按它决定刷新哪些展示面）。
enum CustomCoverChangeKind {
  /// 单曲封面替换 / 重置。
  track,

  /// 全局默认封面替换 / 重置。
  defaultCover,

  /// 列表封面替换 / 重置。
  playlist,
}

/// 一次自定义封面变化。
@immutable
class CustomCoverChange {
  const CustomCoverChange({
    required this.kind,
    this.trackId,
    this.path,
    this.playlistKey,
  });

  final CustomCoverChangeKind kind;

  /// 单曲封面所属曲目；默认封面 / 列表封面变化时为 null。
  final TrackId? trackId;

  /// 列表封面键（`playlist:<syncId>`）；仅 [CustomCoverChangeKind.playlist]。
  final String? playlistKey;

  /// 新文件的绝对路径；重置时为 null。
  final String? path;

  bool get isDefaultCover => kind == CustomCoverChangeKind.defaultCover;

  bool get isPlaylist => kind == CustomCoverChangeKind.playlist;
}

/// 索引条目（持久化形状）。
@immutable
class CustomCoverEntry {
  const CustomCoverEntry({
    required this.path,
    required this.hash,
    required this.updatedAt,
    this.format = CoverImageFormat.jpeg,
  }) : assert(path != '');

  /// 封面文件绝对路径。
  final String path;

  /// 归一化后图片字节的 SHA-256（同步 / 备份等后续用途的稳定标识）。
  final String hash;

  /// 写入时间（毫秒时间戳）。
  final int updatedAt;

  /// 文件格式；老索引没有该字段时按路径扩展名推断，再兜底 JPEG。
  final CoverImageFormat format;

  String get mimeType => format.mimeType;
  String get extension => format.extension;

  Map<String, Object?> toJson() => {
    'path': path,
    'hash': hash,
    'updatedAt': updatedAt,
    'format': format.name,
  };

  static CustomCoverEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final hash = raw['hash'];
    final updatedAt = raw['updatedAt'];
    if (path is! String || path.isEmpty) return null;
    final storedFormat = raw['format'];
    CoverImageFormat? format;
    for (final value in CoverImageFormat.values) {
      if (value.name == storedFormat) {
        format = value;
        break;
      }
    }
    final dot = path.lastIndexOf('.');
    return CustomCoverEntry(
      path: path,
      hash: hash is String ? hash : '',
      updatedAt: updatedAt is int ? updatedAt : 0,
      format:
          format ??
          CoverImageFormat.fromExtension(
            dot < 0 ? null : path.substring(dot + 1),
          ) ??
          CoverImageFormat.jpeg,
    );
  }
}

/// 自定义封面存储：本进程唯一实例由组合根构造（`local_data_stack.dart`），
/// 再经 Provider（UI）与构造参数（下载 / 同步 / 取色）向下传递。
///
/// 只负责写入 / 持久化 / 同步落地与只读索引；「哪张封面优先」由
/// [resolution]（`cover_resolution.dart`）决定，UI / 下载 / 取色不再调用
/// 存储里的解析方法。
class CustomCoverStore implements cover_resolution.CoverIndex {
  CustomCoverStore({
    Future<SharedPreferences> Function()? preferences,
    Future<Directory> Function()? supportDirectory,
    Future<Directory?> Function()? legacyDirectory,
    DateTime Function()? clock,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _supportDirectory = supportDirectory ?? appDataDirectory,
       _legacyDirectory = legacyDirectory ?? legacyAppDataDirectory,
       _migrateLegacy = supportDirectory == null || legacyDirectory != null,
       _clock = clock ?? DateTime.now;

  /// 本存储的封面解析器（唯一解析入口；组合根与 widget 适配器共用）。
  late final cover_resolution.CoverResolver resolution =
      cover_resolution.CoverResolver(this);

  static const String prefsKey = 'custom_cover_index_v1';
  static const String directoryName = 'custom_covers';

  /// 单张封面可进入同步记录的字节上限（归一化产物通常远小于此）。
  ///
  /// 动图 WebP 需要比静态 JPEG 更宽的预算；归一化会按同一上限逐级降参数，
  /// 正常动图不会被截成静态图。base64 后约 2MB，仍低于增量日志 8MB 窗口。
  /// 只有既有本地文件 / 异常远端记录才会超过该值：超限跳过同步，本地封面
  /// 继续可用；接收侧用同一上限拒绝异常远端记录。
  static const int maxSyncBytes = kCoverSyncMaxBytes;

  final Future<SharedPreferences> Function() _preferences;
  final Future<Directory> Function() _supportDirectory;
  final Future<Directory?> Function() _legacyDirectory;

  /// 只有生产默认目录或显式注入旧目录时才迁移（测试注入新目录不碰 Roaming）。
  final bool _migrateLegacy;
  final DateTime Function() _clock;

  /// UI 订阅通道：任何替换 / 重置都会自增。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 仅本地写入（替换 / 重置 / 换源复制）时回调；远端同步应用不触发。
  ///
  /// 组合根用它给 `SyncCategory.covers` 标脏，保证远端落地不会形成同步回环。
  void Function(CustomCoverChange change)? onLocalChange;

  final List<void Function(CustomCoverChange)> _changeListeners = [];
  final Map<String, CustomCoverEntry> _tracks = {};
  final Map<String, CustomCoverEntry> _playlists = {};
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
      // Windows：先把旧 Roaming 目录的封面文件复制到 LocalAppData，并把
      // prefs 索引里的旧 base 路径改写掉；否则下面的「剔除丢失文件」会把
      // 用户封面全部剪掉。复制失败的文件保留旧路径（旧文件仍在，可继续用）。
      final support = await _supportDirectory();
      if (_migrateLegacy) await _migrateLegacyDirectory(support);
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
          final playlists = decoded['playlists'];
          if (playlists is Map) {
            for (final entry in playlists.entries) {
              final parsed = CustomCoverEntry.fromJson(entry.value);
              if (parsed != null) _playlists[entry.key.toString()] = parsed;
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
    for (final entry in _playlists.entries.toList()) {
      if (!await _fileExists(entry.value.path)) {
        _playlists.remove(entry.key);
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

  /// Windows 旧目录（Roaming）→ LocalAppData：复制封面并改写索引路径。
  ///
  /// 只在存在旧目录且与新目录不同时执行；复制失败只记日志，旧文件保留，
  /// 索引里对应路径不改写（文件仍可读），下次启动继续尝试。
  Future<void> _migrateLegacyDirectory(Directory support) async {
    final legacy = await _legacyDirectory();
    if (legacy == null) return;
    if (p.normalize(p.absolute(legacy.path)) ==
        p.normalize(p.absolute(support.path))) {
      return;
    }
    await migrateLegacyDirectoryIfNeeded(
      targetDirectory: support,
      relativePath: directoryName,
      legacyDirectory: legacy,
    );
    await _rewriteLegacyIndexPaths(legacy, support);
  }

  /// 把索引里的旧 base 路径改成新 base（目标文件不存在则保留旧路径）。
  Future<void> _rewriteLegacyIndexPaths(
    Directory legacy,
    Directory support,
  ) async {
    try {
      final prefs = await _preferences();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final oldBase = p.join(legacy.path, directoryName);
      final newBase = p.join(support.path, directoryName);

      Future<String?> rewrite(Object? value) async {
        if (value is! String || !p.isWithin(oldBase, value)) return null;
        final candidate = p.join(newBase, p.relative(value, from: oldBase));
        return await _fileExists(candidate) ? candidate : null;
      }

      var changed = false;
      final tracks = decoded['tracks'];
      if (tracks is Map) {
        for (final entry in tracks.entries) {
          final item = entry.value;
          if (item is! Map) continue;
          final path = await rewrite(item['path']);
          if (path != null && path != item['path']) {
            item['path'] = path;
            changed = true;
          }
        }
      }
      final playlists = decoded['playlists'];
      if (playlists is Map) {
        for (final entry in playlists.entries) {
          final item = entry.value;
          if (item is! Map) continue;
          final path = await rewrite(item['path']);
          if (path != null && path != item['path']) {
            item['path'] = path;
            changed = true;
          }
        }
      }
      final defaultCover = decoded['default'];
      if (defaultCover is Map) {
        final path = await rewrite(defaultCover['path']);
        if (path != null && path != defaultCover['path']) {
          defaultCover['path'] = path;
          changed = true;
        }
      }
      if (changed) {
        final written = await prefs.setString(prefsKey, jsonEncode(decoded));
        if (written) {
          debugPrint('[Molia] 自定义封面索引已迁移到 LocalAppData');
        } else {
          // 平台拒绝：索引仍是旧路径（文件已复制），下次启动重试改写。
          debugPrint('[Molia] 自定义封面索引迁移写回被平台拒绝，下次启动重试');
        }
      }
    } catch (e) {
      debugPrint('[Molia] 迁移自定义封面索引失败（保留旧路径）：$e');
    }
  }

  /// 注册变化回调（返回取消函数）。
  void Function() addChangeListener(void Function(CustomCoverChange) listener) {
    _changeListeners.add(listener);
    return () => _changeListeners.remove(listener);
  }

  /// 只订阅 revision（解析模块的变更信号；不区分本地 / 远端写入）。
  @override
  void Function() addRevisionListener(void Function() listener) {
    revision.addListener(listener);
    return () => revision.removeListener(listener);
  }

  /// 规范曲目键：委托 `cover_resolution.dart`（规则只此一份）。
  static String coverKeyOf(TrackId id) => cover_resolution.coverKeyOf(id);

  /// 字符串形态的规范化（委托解析模块）。
  static String normalizeCoverKey(String key) =>
      cover_resolution.normalizeCoverKey(key);

  /// 曲目自定义封面文件路径（未设置为 null）。
  String? trackCoverPath(TrackId id) {
    final entry = _tracks[coverKeyOf(id)];
    return entry?.path;
  }

  /// 列表自定义封面文件路径（未设置为 null）。
  String? playlistCoverPath(String key) => _playlists[key]?.path;

  /// 列表自定义封面 `file://` 地址（未设置为 null）。
  String? playlistCoverUrl(String key) {
    final path = playlistCoverPath(key);
    return path == null ? null : Uri.file(path).toString();
  }

  /// 规范化封面键 → 自定义封面 `file://` 地址（[resolution.CoverIndex]）。
  ///
  /// 传入键必须已规范化；字符串入口的 `local:` 剥离由 [CoverResolver] 做。
  /// 列表键（`playlist:<syncId>`）与曲目键共用同一块只读解析面，键空间
  /// 互不重叠。
  @override
  String? customCoverUrlForKey(String key) {
    final entry = _tracks[key] ?? _playlists[key];
    return entry == null ? null : Uri.file(entry.path).toString();
  }

  /// 曲目自定义封面 `file://` 地址（未设置为 null）。
  String? trackCoverUrl(TrackId id) {
    final path = trackCoverPath(id);
    return path == null ? null : Uri.file(path).toString();
  }

  /// 全局默认封面 `file://` 地址；null = 显示 Molia 标志。
  @override
  String? get defaultCoverUrl {
    final path = _defaultCover?.path;
    return path == null ? null : Uri.file(path).toString();
  }

  /// 当前曲目封面索引（键 = 规范化封面键；只读快照）。
  Map<String, CustomCoverEntry> get trackEntries => Map.unmodifiable(_tracks);

  /// 当前列表封面索引（键 = `playlist:<syncId>`；只读快照）。
  Map<String, CustomCoverEntry> get playlistEntries =>
      Map.unmodifiable(_playlists);

  /// 指定封面键的索引条目（未设置为 null）。
  CustomCoverEntry? trackEntry(String key) => _tracks[key];

  /// 指定列表封面键的索引条目（未设置为 null）。
  CustomCoverEntry? playlistEntry(String key) => _playlists[key];

  /// 全局默认封面索引条目（未设置为 null）。
  CustomCoverEntry? get defaultEntry => _defaultCover;

  /// 读取曲目自定义封面字节（不存在 / 不可读返回 null）。
  Future<Uint8List?> readTrackCover(TrackId id) =>
      _readFile(trackCoverPath(id));

  /// 按封面键读取曲目封面字节（不存在 / 不可读返回 null）。
  @override
  Future<Uint8List?> readTrackCoverByKey(String key) =>
      _readFile(_tracks[key]?.path);

  /// 按任意封面键读取字节（曲目 / 列表；同步适配器按索引键读取）。
  Future<Uint8List?> readCoverBytesByKey(String key) =>
      _readFile((_tracks[key] ?? _playlists[key])?.path);

  /// 按列表封面键读取字节（不存在 / 不可读返回 null）。
  Future<Uint8List?> readPlaylistCover(String key) =>
      _readFile(_playlists[key]?.path);

  /// 读取全局默认封面字节（不存在 / 不可读返回 null）。
  Future<Uint8List?> readDefaultCover() => _readFile(_defaultCover?.path);

  /// 图片字节是否可进入同步记录（大小 + 魔数；不在这里解码整图）。
  ///
  /// 新选图统一是 WebP；既有本地封面可能是 JPEG / PNG / GIF，只要 Flutter
  /// 能稳定解码就照常同步。扩展名 / MIME 由字节识别，不信任记录声明；AVIF
  /// 等平台相关格式不接受，避免另一台设备打不开。
  static bool canSyncImageBytes(Uint8List bytes) =>
      CoverImageFormats.detectSyncable(bytes, maxBytes: maxSyncBytes) != null;

  /// 保存曲目封面（[bytes] 应已由 `CoverImageCodec` 归一化）。
  Future<void> setTrackCover(TrackId id, Uint8List bytes) async {
    final key = coverKeyOf(id);
    final entry = await _writeEntry(
      filePrefix: 'track_${_shortHash(key)}',
      bytes: bytes,
    );
    await _commitTrackEntry(key, entry, trackId: id, local: true);
  }

  /// 恢复曲目原始封面（没有自定义封面时为空操作）。
  Future<void> resetTrackCover(TrackId id) async {
    final key = coverKeyOf(id);
    await _removeTrackEntry(key, trackId: id, local: true);
  }

  /// 保存全局默认封面（[bytes] 应已由 `CoverImageCodec` 归一化）。
  Future<void> setDefaultCover(Uint8List bytes) async {
    final entry = await _writeEntry(filePrefix: 'default', bytes: bytes);
    await _commitDefaultEntry(entry, local: true);
  }

  /// 恢复默认封面为 Molia 标志（没有自定义默认封面时为空操作）。
  Future<void> resetDefaultCover() => _removeDefaultEntry(local: true);

  /// 保存列表封面（[bytes] 应已由 `CoverImageCodec` 归一化）。
  ///
  /// [key] 是稳定封面键（`playlist:<syncId>`），调用方负责先补齐 syncId。
  Future<void> setPlaylistCover(String key, Uint8List bytes) async {
    if (key.isEmpty) return;
    final entry = await _writeEntry(
      filePrefix: 'playlist_${_shortHash(key)}',
      bytes: bytes,
    );
    await _commitPlaylistEntry(key, entry, local: true);
  }

  /// 恢复列表封面为空（没有自定义封面时为空操作）。
  Future<void> resetPlaylistCover(String key) =>
      _removePlaylistEntry(key, local: true);

  /// 应用远端列表封面（同步 / 备份导入）：写文件 + 索引，不触发本地回调。
  Future<void> applySyncedPlaylistCover(String key, Uint8List bytes) async {
    if (key.isEmpty || bytes.isEmpty) return;
    final entry = await _writeEntry(
      filePrefix: 'playlist_${_shortHash(key)}',
      bytes: bytes,
    );
    await _commitPlaylistEntry(key, entry, local: false);
  }

  /// 应用远端列表封面删除（同步 / 备份导入）；不存在时为空操作。
  Future<void> applySyncedPlaylistDelete(String key) =>
      _removePlaylistEntry(key, local: false);

  /// 应用远端曲目封面（同步 / 备份导入）：写文件 + 索引，不触发本地变更回调。
  Future<void> applySyncedTrackCover(String key, Uint8List bytes) async {
    if (key.isEmpty || bytes.isEmpty) return;
    final entry = await _writeEntry(
      filePrefix: 'track_${_shortHash(key)}',
      bytes: bytes,
    );
    await _commitTrackEntry(
      key,
      entry,
      // 远端记录只有封面键，没有可靠的 TrackId（`local:/path` 会在第一个
      // `:` 处误拆）；变化的 trackId 没有消费方，统一传 null。
      trackId: null,
      local: false,
    );
  }

  /// 应用远端曲目封面删除（同步 / 备份导入）；不存在时为空操作。
  Future<void> applySyncedTrackDelete(String key) =>
      _removeTrackEntry(key, trackId: null, local: false);

  /// 应用远端默认封面（同步 / 备份导入），不触发本地变更回调。
  Future<void> applySyncedDefaultCover(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    final entry = await _writeEntry(filePrefix: 'default', bytes: bytes);
    await _commitDefaultEntry(entry, local: false);
  }

  /// 应用远端默认封面删除（同步 / 备份导入）。
  Future<void> applySyncedDefaultDelete() => _removeDefaultEntry(local: false);

  /// 本地身份迁移：批量把旧封面键改写成新键（文件 / 哈希 / 更新时间不变）。
  ///
  /// 只移动索引键；新键已有用户封面时保留新键、旧键按孤儿留下（不覆盖用户
  /// 选择）。一次持久化、一次 revision 自增；失败回滚内存并上抛。导入封面
  /// 不再进入同步，因此这里不触发本地变更回调（不标脏 covers 类别）。
  Future<int> migrateTrackCoverKeys(Map<String, String> renames) async {
    final moves = <String, String>{};
    for (final entry in renames.entries) {
      final oldKey = entry.key;
      final newKey = entry.value;
      if (oldKey == newKey) continue;
      if (!_tracks.containsKey(oldKey)) continue;
      if (_tracks.containsKey(newKey)) continue;
      moves[oldKey] = newKey;
    }
    if (moves.isEmpty) return 0;
    final previous = <String, CustomCoverEntry?>{
      for (final oldKey in moves.keys) oldKey: _tracks[oldKey],
      for (final newKey in moves.values) newKey: _tracks[newKey],
    };
    for (final move in moves.entries) {
      final entry = _tracks.remove(move.key);
      if (entry != null) _tracks[move.value] = entry;
    }
    try {
      await _persist();
    } catch (e) {
      for (final entry in previous.entries) {
        final value = entry.value;
        if (value == null) {
          _tracks.remove(entry.key);
        } else {
          _tracks[entry.key] = value;
        }
      }
      rethrow;
    }
    revision.value++;
    return moves.length;
  }

  /// 写入曲目索引并持久化；失败回滚内存与文件。
  Future<void> _commitTrackEntry(
    String key,
    CustomCoverEntry entry, {
    required TrackId? trackId,
    required bool local,
  }) async {
    final old = _tracks[key];
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
        trackId: trackId,
        path: entry.path,
      ),
      local: local,
    );
  }

  /// 删除曲目索引 / 文件并持久化；失败回滚内存。
  Future<void> _removeTrackEntry(
    String key, {
    required TrackId? trackId,
    required bool local,
  }) async {
    final old = _tracks.remove(key);
    if (old == null) return;
    try {
      await _persist();
    } catch (e) {
      _tracks[key] = old;
      rethrow;
    }
    await _deleteQuietly(old.path);
    _notify(
      CustomCoverChange(kind: CustomCoverChangeKind.track, trackId: trackId),
      local: local,
    );
  }

  /// 写入列表封面索引并持久化；失败回滚内存与文件。
  Future<void> _commitPlaylistEntry(
    String key,
    CustomCoverEntry entry, {
    required bool local,
  }) async {
    final old = _playlists[key];
    _playlists[key] = entry;
    try {
      await _persist();
    } catch (e) {
      if (old == null) {
        _playlists.remove(key);
      } else {
        _playlists[key] = old;
      }
      await _deleteQuietly(entry.path);
      rethrow;
    }
    if (old != null && old.path != entry.path) {
      await _deleteQuietly(old.path);
    }
    _notify(
      CustomCoverChange(
        kind: CustomCoverChangeKind.playlist,
        playlistKey: key,
        path: entry.path,
      ),
      local: local,
    );
  }

  /// 删除列表封面索引 / 文件并持久化；失败回滚内存。
  Future<void> _removePlaylistEntry(String key, {required bool local}) async {
    final old = _playlists.remove(key);
    if (old == null) return;
    try {
      await _persist();
    } catch (e) {
      _playlists[key] = old;
      rethrow;
    }
    await _deleteQuietly(old.path);
    _notify(
      CustomCoverChange(kind: CustomCoverChangeKind.playlist, playlistKey: key),
      local: local,
    );
  }

  /// 写入默认封面索引并持久化；失败回滚内存与文件。
  Future<void> _commitDefaultEntry(
    CustomCoverEntry entry, {
    required bool local,
  }) async {
    final old = _defaultCover;
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
      local: local,
    );
  }

  /// 删除默认封面索引 / 文件并持久化；失败回滚内存。
  Future<void> _removeDefaultEntry({required bool local}) async {
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
    _notify(
      const CustomCoverChange(kind: CustomCoverChangeKind.defaultCover),
      local: local,
    );
  }

  /// 换源时把旧曲目的自定义封面复制到新曲目键（非破坏性，旧封面保留）。
  ///
  /// 返回是否复制成功；源没有自定义封面、或新曲目键已有用户封面时为空操作
  ///（不能拿旧曲目的封面覆盖用户已经给新曲目选好的封面）。文件 / 索引错误
  /// 只记日志——换源本身已经成功，封面跟随是增强项。
  Future<bool> carryOver(Track oldTrack, Track newTrack) async {
    final oldKey = coverKeyOf(oldTrack.id);
    final newKey = coverKeyOf(newTrack.id);
    if (oldKey == newKey) return false;
    if (_tracks.containsKey(newKey)) return false;
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
    // 扩展名跟内容走：远端可能发来 WebP，既有本地封面也可能是 JPEG /
    // PNG / GIF。未知字节只可能是测试或损坏文件，按 JPEG 落盘保持旧行为
    //（同步面会先做格式校验，不会把未知字节发出去）。
    final format =
        CoverImageFormats.detect(bytes)?.format ?? CoverImageFormat.jpeg;
    final directory = await _coverDirectory();
    final stamp = _clock().microsecondsSinceEpoch;
    final name =
        '${filePrefix}_${stamp}_${_writeSequence++}.${format.extension}';
    final file = File('${directory.path}/$name');
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
    return CustomCoverEntry(
      path: file.path,
      hash: sha256.convert(bytes).toString(),
      updatedAt: _clock().millisecondsSinceEpoch,
      format: format,
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
        'playlists': {
          for (final entry in _playlists.entries)
            entry.key: entry.value.toJson(),
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

  void _notify(CustomCoverChange change, {required bool local}) {
    _bumpRevision();
    if (local) onLocalChange?.call(change);
    for (final listener in List<void Function(CustomCoverChange)>.of(
      _changeListeners,
    )) {
      listener(change);
    }
  }

  static String _shortHash(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 12);
}
