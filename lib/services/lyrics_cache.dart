import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show md5;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/files/app_data_directory.dart';
import 'cache_storage.dart' show CacheUsage;
import 'lyrics/lyric_provider.dart' show LyricCacheData;

/// 歌词缓存（键 / 读写 / 用量 / 清理）的唯一实现。
///
/// 存储形态由构造方式**显式选择**：
/// - 默认（[LyricsCache.new]，仅 [prefs] 或没有参数）：保持 SharedPreferences
///   行为，不调用 `path_provider`，也不做任何文件 IO。
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
/// 文件后端行为（目录解析成功即为文件模式）：
/// - 文件是唯一副本：读取只看文件、写入只写文件、用量只统计文件，一律不碰
///   prefs；文件缺失 / 损坏按未命中处理；
/// - 目录解析失败（没有可用的文件后端）时才整体回退 prefs：读写、用量与清理
///   都走 prefs 的 `lyrics_cache_{trackId}` 键。
class LyricsCache {
  /// [directory] 优先于 [_directoryResolver]；两者都为空时只走 prefs。
  LyricsCache({
    SharedPreferences? prefs,
    Directory? directory,
    this._directoryResolver,
  })  : _prefsOverride = prefs,
        _directoryOverride = directory;

  /// 生产组合根：显式启用 `<appSupport>/lyrics_cache` 文件后端。
  ///
  /// 目录解析保持惰性（首次读写 / 统计才调用 `path_provider`），不阻塞首帧；
  /// 解析失败自动回退 prefs。普通 [LyricsCache] 构造不会走文件后端。
  factory LyricsCache.appSupport({SharedPreferences? prefs}) => LyricsCache(
        prefs: prefs,
        directoryResolver: resolveAppSupportLyricsDirectory,
      );

  static const String keyPrefix = 'lyrics_cache_';

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
  /// 文件模式只看文件：文件缺失或损坏一律按未命中，不回退 prefs（旧条目可能
  /// 更早，回退会绕过 TTL 判断返回过期歌词）。
  Future<LyricCacheData?> read(String trackId) async {
    final directory = await _directoryOrNull();
    if (directory != null) {
      final file = File(_filePath(directory, trackId));
      try {
        if (!await file.exists()) return null;
        return _decode(await file.readAsString());
      } catch (_) {
        // 文件存在但读失败（权限 / 并发替换）：按未命中处理。
        return null;
      }
    }

    final prefs = await _prefsOrNull();
    final raw = prefs?.getString('$keyPrefix$trackId');
    return raw == null ? null : _decode(raw);
  }

  /// 写入一条歌词：文件模式只写文件，没有文件后端时写 prefs。
  Future<void> write(String trackId, LyricCacheData data) async {
    final raw = json.encode(data.toJson());
    final directory = await _directoryOrNull();
    if (directory != null) {
      // 文件是唯一副本：写入失败按未持久化处理（歌词可再取），不回退 prefs。
      await _writeFile(directory, trackId, raw);
      return;
    }

    final prefs = await _prefsOrNull();
    try {
      await prefs?.setString('$keyPrefix$trackId', raw);
    } catch (_) {
      // prefs 不可用：按未持久化处理，上层下次会重新取词。
    }
  }

  /// 歌词分区用量：文件模式统计目录，没有文件后端时统计 prefs 规范键。
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
    return CacheUsage(bytes: scan.bytes, count: scan.count);
  }

  /// 单曲歌词缓存占用（与 [usage] 同一后端口径）。
  Future<CacheUsage> usageOf(String trackId) async {
    final directory = await _directoryOrNull();
    if (directory != null) {
      try {
        final file = File(_filePath(directory, trackId));
        if (!await file.exists()) return CacheUsage.zero;
        return CacheUsage(bytes: await file.length(), count: 1);
      } catch (_) {
        // 文件被并发删除 / 不可读：该部分按 0 计。
        return CacheUsage.zero;
      }
    }

    final prefs = await _prefsOrNull();
    final raw = prefs?.getString('$keyPrefix$trackId');
    if (raw == null) return CacheUsage.zero;
    return CacheUsage(bytes: utf8.encode(raw).length, count: 1);
  }

  /// 删除单曲歌词缓存：文件模式删文件，没有文件后端时删 prefs 规范键。
  Future<void> remove(String trackId) async {
    final directory = await _directoryOrNull();
    if (directory != null) {
      try {
        final file = File(_filePath(directory, trackId));
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 文件可能已被其它清理路径删掉：按已删除处理。
      }
      return;
    }

    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    try {
      await prefs.remove('$keyPrefix$trackId');
    } catch (_) {
      // prefs 不可用时保持静默：调用方只关心「尽量清理」。
    }
  }

  /// 清除歌词分区：文件模式删目录内文件，没有文件后端时清 prefs 规范键。
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
        // 目录不可读：按已清空处理（歌词缓存可再取）。
      }
      return;
    }

    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final keys =
        prefs.getKeys().where((key) => key.startsWith(keyPrefix)).toList();
    for (final key in keys) {
      try {
        await prefs.remove(key);
      } catch (_) {
        // 同上：单个键删除失败不阻断整体清理。
      }
    }
  }

  /// prefs 后端用量（只统计规范键）。
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

  /// 解析失败（损坏 / 格式不符）一律按未命中。
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
    final temp = File(
      '${target.path}.$pid.'
      '${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await directory.create(recursive: true);
      // 不 fsync：歌词是「可再取」的派生数据，掉电 / 强杀丢一条缓存远好过
      // 让每次取词都等一次落盘。实测 WSL2（ext4）单次 flush 会把
      // lyrics.fetch 从数毫秒推到 200–350ms，正好卡在切歌展示路径上。
      // 临时文件 + rename 仍保证读者只会看到完整文件。
      await temp.writeAsString(raw, flush: false);
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
    final support = await appDataDirectory();
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
