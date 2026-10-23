import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show md5;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache_storage.dart' show CacheUsage;
import 'lyrics/lyric_provider.dart' show LyricCacheData;

/// 歌词缓存（键 / 读写 / 用量 / 清理）的唯一实现。
///
/// 存储形态由构造方式**显式选择**：
/// - 默认（[LyricsCache.new]，仅 [prefs] 或没有参数）：保持旧版
///   SharedPreferences 行为，不调用 `path_provider`，也不做任何文件 IO。
///   widget 测试的 fake async 等不到平台通道 / 文件 Future，默认启用文件后端
///   会让 `pumpAndSettle` 超时；目录不可用的降级平台也依赖这条回退路径。
/// - 文件后端（[LyricsCache.appSupport]，或显式传 [directory] /
///   [directoryResolver]）：`<appSupport>/lyrics_cache/` 下一条歌词一个文件，
///   文件名取 `trackId` 的 md5（曲目 id 可能含 `:`、`/` 且长度不可控），内容
///   与 [LyricCacheData.toJson] 一致。生产组合根显式接入（见
///   `lib/app/bootstrap/local_data_stack.dart`）。
///
/// 生产为什么用文件而不是 prefs：
/// - prefs 每次 `setString` 都会把整份偏好文件重新序列化落盘，歌词写入发生在
///   每次取词 / 手动选词，曲目一多就是持续的整文件写放大；
/// - prefs 的读取/统计没有按条目的长度信息，[usage] 只能把每条歌词字符串重新
///   UTF-8 编码一遍，整个扫描都压在 UI isolate 上。
///
/// 文件后端行为：
/// - 旧版规范键 `lyrics_cache_{trackId}` 在首次命中时迁移成文件（成功后才删旧
///   键，失败则继续用 prefs）；文件损坏时按未命中处理，绝不回退到可能过期的
///   旧 prefs 条目；
/// - 历史版本在歌词搜索页额外写过一份 `manual_lyrics_cache_*` 重复键：
///   读取一律不碰，[remove] / [clear] 时连同历史键一起清除。
class LyricsCache {
  /// [directory] 优先于 [directoryResolver]；两者都为空时只走 prefs。
  LyricsCache({
    SharedPreferences? prefs,
    Directory? directory,
    Future<Directory?> Function()? directoryResolver,
  })  : _prefsOverride = prefs,
        _directoryOverride = directory,
        _directoryResolver = directoryResolver;

  /// 生产组合根：显式启用 `<appSupport>/lyrics_cache` 文件后端。
  ///
  /// 目录解析保持惰性（首次读写 / 统计才调用 `path_provider`），不阻塞首帧；
  /// 解析失败自动回退 prefs。普通 [LyricsCache] 构造不会走文件后端。
  factory LyricsCache.appSupport({SharedPreferences? prefs}) => LyricsCache(
        prefs: prefs,
        directoryResolver: resolveAppSupportLyricsDirectory,
      );

  static const String keyPrefix = 'lyrics_cache_';

  /// 历史遗留的重复键前缀（只清不读）。
  static const String legacyManualKeyPrefix = 'manual_lyrics_cache_';

  /// 歌词缓存子目录名（位于应用支持目录下）。
  static const String directoryName = 'lyrics_cache';

  final SharedPreferences? _prefsOverride;
  final Directory? _directoryOverride;
  final Future<Directory?> Function()? _directoryResolver;
  SharedPreferences? _prefs;

  /// 目录解析结果只算一次：解析失败后本实例按 prefs 回退，避免每次读写都
  /// 重新调用 path_provider。
  Future<Directory?>? _directoryFuture;

  /// 读取条目；不存在 / 损坏 / 存储不可用时返回 null（按未命中处理）。
  ///
  /// 文件存在但内容损坏时直接返回 null：旧 prefs 条目可能是更早的版本，
  /// 回退会绕过 TTL 判断返回过期歌词。
  Future<LyricCacheData?> read(String trackId) async {
    final directory = await _directoryOrNull();
    if (directory != null) {
      final file = File(_filePath(directory, trackId));
      try {
        if (await file.exists()) {
          return _decode(await file.readAsString());
        }
      } catch (_) {
        // 文件存在但读失败（权限 / 并发替换）：按未命中处理，不回退 prefs。
        return null;
      }
    }

    // 文件不存在：检查旧版规范键并尽力迁移。迁移失败（目录不可写等）时保留
    // prefs 条目，下次仍可命中，不会丢歌词。
    final prefs = await _prefsOrNull();
    final key = '$keyPrefix$trackId';
    final raw = prefs?.getString(key);
    if (raw == null) return null;
    final data = _decode(raw);
    if (data == null) return null;
    if (directory != null && await _writeFile(directory, trackId, raw)) {
      try {
        await prefs?.remove(key);
      } catch (_) {
        // 删除旧键失败不影响本次读取；下次命中文件后不会再走迁移。
      }
    }
    return data;
  }

  /// 写入一条歌词：优先文件，文件后端不可用时回退 prefs。
  Future<void> write(String trackId, LyricCacheData data) async {
    final raw = json.encode(data.toJson());
    final directory = await _directoryOrNull();
    if (directory != null && await _writeFile(directory, trackId, raw)) {
      // 文件成为权威副本后清掉同曲目的旧规范键，避免 [usage] 在迁移窗口
      // 双算；历史 manual 键不在这里动（写路径不该扩大 prefs 的整文件重写，
      // [remove] / [clear] 负责清理）。
      final prefs = await _prefsOrNull();
      final key = '$keyPrefix$trackId';
      if (prefs != null && prefs.containsKey(key)) {
        try {
          await prefs.remove(key);
        } catch (_) {
          // 旧键清理失败只是多算一份占用，不影响文件读取。
        }
      }
      return;
    }

    final prefs = await _prefsOrNull();
    try {
      await prefs?.setString('$keyPrefix$trackId', raw);
    } catch (_) {
      // prefs 与目录都不可用：按未持久化处理，上层下次会重新取词。
    }
  }

  /// 歌词分区用量（文件 + 尚未迁移的旧版规范键）。
  ///
  /// 目录扫描是 O(文件数) 的串行 IO，丢给短命 isolate；闭包只捕获路径字符串，
  /// 不把 [Directory] / plugin 状态带进子 isolate。
  Future<CacheUsage> usage() async {
    final directory = await _directoryOrNull();
    if (directory == null) return _prefsUsage();

    final path = directory.path;
    _LyricsDirScan scan;
    try {
      scan = await Isolate.run(() => _scanLyricsDir(path));
    } catch (_) {
      // 平台不支持短命 isolate：退回主 isolate 同步扫描（正确性优先）。
      scan = _scanLyricsDir(path);
    }
    // 迁移是逐条懒执行的，旧规范键可能还在：不把它们算进去会让缓存页在
    // 升级后的第一轮展示里明显少算。
    return CacheUsage(bytes: scan.bytes, count: scan.count) +
        await _prefsUsage();
  }

  /// 单曲歌词缓存占用（文件 + 尚未迁移的旧规范键，与 [usage] 同一口径）。
  Future<CacheUsage> usageOf(String trackId) async {
    var usage = CacheUsage.zero;
    final directory = await _directoryOrNull();
    if (directory != null) {
      try {
        final file = File(_filePath(directory, trackId));
        if (await file.exists()) {
          usage += CacheUsage(bytes: await file.length(), count: 1);
        }
      } catch (_) {
        // 文件被并发删除 / 不可读：该部分按 0 计。
      }
    }

    final prefs = await _prefsOrNull();
    final raw = prefs?.getString('$keyPrefix$trackId');
    if (raw != null) {
      usage += CacheUsage(bytes: utf8.encode(raw).length, count: 1);
    }
    return usage;
  }

  /// 删除单曲歌词缓存：文件 + 规范键 + 历史重复键（后者只清不读）。
  Future<void> remove(String trackId) async {
    final directory = await _directoryOrNull();
    if (directory != null) {
      try {
        final file = File(_filePath(directory, trackId));
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 文件可能已被其它清理路径删掉：继续清 prefs 键。
      }
    }

    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    try {
      await prefs.remove('$keyPrefix$trackId');
      await prefs.remove('$legacyManualKeyPrefix$trackId');
    } catch (_) {
      // prefs 不可用时保持静默：调用方只关心「尽量清理」。
    }
  }

  /// 清除歌词分区：目录内文件 + 规范键 + 历史重复键。
  ///
  /// 保留目录本身（与音频 / 封面分区一致）；单个文件已不存在或删除失败时
  /// 跳过，不让清理中断。
  Future<void> clear() async {
    final directory = await _directoryOrNull();
    if (directory != null) {
      try {
        if (await directory.exists()) {
          await for (final entity in directory.list(followLinks: false)) {
            if (entity is! File) continue;
            try {
              await entity.delete();
            } catch (_) {
              // 文件已被并发删除 / 被占用：继续清理其余条目。
            }
          }
        }
      } catch (_) {
        // 目录不可读：至少把 prefs 里的旧条目清掉。
      }
    }

    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final keys = prefs
        .getKeys()
        .where((key) =>
            key.startsWith(keyPrefix) || key.startsWith(legacyManualKeyPrefix))
        .toList();
    for (final key in keys) {
      try {
        await prefs.remove(key);
      } catch (_) {
        // 同上：单个键删除失败不阻断整体清理。
      }
    }
  }

  /// 旧版 prefs 用量（只统计规范键；历史重复键不算用量）。
  Future<CacheUsage> _prefsUsage() async {
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

  /// 解析失败（损坏 / 旧格式不兼容）一律按未命中。
  LyricCacheData? _decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      return LyricCacheData.fromJson(json.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// 文件写入成功返回 true。
  ///
  /// 先写同目录临时文件再 rename：rename 在同一文件系统内是原子的，进程被杀
  /// / 断电最多留下一个 `.tmp`，正式文件名下永远是完整 JSON，不会读到半截。
  Future<bool> _writeFile(
    Directory directory,
    String trackId,
    String raw,
  ) async {
    final target = File(_filePath(directory, trackId));
    // 临时名带 pid + 时间戳：同一曲目被并发写入时各自写自己的临时文件，
    // 不会互相截断（固定 `.tmp` 在 rename 交错时可能把半截内容搬到正式名）。
    final temp = File('${target.path}.$pid.'
        '${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await directory.create(recursive: true);
      await temp.writeAsString(raw, flush: true);
      await temp.rename(target.path);
      return true;
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 临时文件清理失败不影响回退结果。
      }
      return false;
    }
  }

  static String _filePath(Directory directory, String trackId) {
    // md5 固定 32 位十六进制，天然避开路径分隔符、冒号（Windows 非法）与
    // 文件名长度上限；碰撞概率对本地缓存可忽略。
    final name = md5.convert(utf8.encode(trackId)).toString();
    return _joinPath(directory.path, '$name.json');
  }

  static String _joinPath(String base, String name) {
    final separator = Platform.pathSeparator;
    return base.endsWith(separator) ? '$base$name' : '$base$separator$name';
  }

  Future<Directory?> _directoryOrNull() {
    final override = _directoryOverride;
    if (override != null) return Future<Directory?>.value(override);
    final resolver = _directoryResolver;
    // 没有显式 resolver：默认实例只走 prefs，连 path_provider 都不碰。
    if (resolver == null) return Future<Directory?>.value(null);
    return _directoryFuture ??= _resolveDirectory(resolver);
  }

  Future<Directory?> _resolveDirectory(
    Future<Directory?> Function() resolver,
  ) async {
    try {
      return await resolver();
    } catch (_) {
      // resolver 自己失败（path_provider 不可用 / 平台通道异常）：回退 prefs。
      return null;
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

/// 生产组合根使用：返回 `<appSupport>/lyrics_cache`（惰性解析）。
///
/// 只解析路径，不主动创建目录（首次写入时由 [_writeFile] 创建）；path_provider
/// 不可用或解析失败返回 null，由 [LyricsCache] 回退 prefs。
///
/// 不要把它设为 [LyricsCache] 的默认解析器：widget 测试的 fake async 下平台通道
/// Future 可能永远不完成。
Future<Directory?> resolveAppSupportLyricsDirectory() async {
  try {
    final support = await getApplicationSupportDirectory();
    return Directory(
      LyricsCache._joinPath(support.path, LyricsCache.directoryName),
    );
  } catch (_) {
    // path_provider 不可用（单元测试 / 极简平台）：调用方回退 prefs。
    return null;
  }
}

/// 歌词目录扫描结果：字节数 / 文件数。
///
/// 只回传基础类型（`int`），可安全跨 isolate 发送。
typedef _LyricsDirScan = ({int bytes, int count});

/// 扫描歌词目录（在短命 isolate 或降级的主 isolate 中执行，必须是顶层函数）。
///
/// 失败语义：
/// - 目录不存在 / 不可读：按空结果处理；
/// - 单个文件取大小失败（正被删除 / 替换）：跳过该文件。
_LyricsDirScan _scanLyricsDir(String path) {
  final directory = Directory(path);
  if (!directory.existsSync()) return (bytes: 0, count: 0);

  var bytes = 0;
  var count = 0;
  try {
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! File) continue;
      try {
        bytes += entity.lengthSync();
        count++;
      } catch (_) {
        // 并发删除 / 替换：跳过单个文件。
      }
    }
  } catch (_) {
    // 目录权限或并发删除：返回已扫描到的部分。
  }
  return (bytes: bytes, count: count);
}
