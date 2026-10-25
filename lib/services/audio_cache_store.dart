/// 音频缓存目录约定的唯一实现：文件名、完整判据、索引、命中、清扫。
///
/// 为什么单独成模块：这些约定过去散落在 `CacheService`（命名 / 索引 / 清扫）、
/// `TrackLocalDataService`（命中音质）与 `DownloadService`（命中探测）
/// 三处，任何一处改动都可能让写入侧与读取侧再次分叉。历史上写入侧把
/// `SourceTrack.id`（`{sourceKey}:{songId}` 复合 id）当成 songId 写文件名，
/// 读取侧按 `TrackId.id`（raw songId）查找——两侧永不同名，「缓存 = 已下载」
/// 整条链（信息页状态、下载弹层标记、转存、离线取链、本地歌曲缓存行）静默
/// 失效（见 ADR-0008 背景）。现在文件名只有 [keyForSource]（写入侧）与
/// [keyForTrack]（读取侧）两个出口，两侧同名是硬约束，由回归测试断言。
///
/// 与 `CacheService` 的分工：本模块只承接磁盘约定，**策略面**（音频开关、
/// 容量上限、`protectAge`、revision 通知、分区用量与清理、封面 / 歌词）留在
/// `CacheService`。平台文件操作走 [CacheStorage] seam（`dart:io` 只在实现
/// 层），因此模块可注入假件单测。
library;

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../domain/models/track.dart';
import '../sources/source_track.dart';
import 'cache_types.dart';

/// 文件存在探测（[AudioCacheStore.hitPathForTrack] 用）。
///
/// 调用方提供自己的文件系统视图：缓存栈读 [CacheStorage]，下载 / 转存链路读
/// 自己的下载存储——两套 seam 在生产环境指向同一文件系统，在测试里可以
/// 各自独立。
typedef AudioCacheFileProbe = Future<bool> Function(String path);

/// 音频缓存目录约定（`CacheStorage` 之上的唯一磁盘约定实现）。
class AudioCacheStore {
  AudioCacheStore({required CacheStorage storage}) : _storage = storage;

  /// 目录解析 / 列举 / 删除的平台实现；目录不可用时返回 null / 空表。
  final CacheStorage _storage;

  final Logger _logger = Logger('molia.audio_cache_store');

  // 命名（纯函数，无 IO）

  /// 单曲音频缓存文件名（**写入侧唯一入口**）：由 `SourceTrack` 派生。
  ///
  /// `songId` 必须用 [SourceTrack.songId]（与 `TrackId.id` 同源）；用
  /// `SourceTrack.id`（含 sourceKey 的复合 id）写出来的文件没有任何读取
  /// 路径能匹配到，等于没缓存。
  static String keyForSource(SourceTrack track, {String quality = ''}) =>
      key(sourceKey: track.sourceKey, songId: track.songId, quality: quality);

  /// 单曲音频缓存文件名（**读取侧唯一入口**）：由领域 `Track` 派生。
  static String keyForTrack(Track track, {String quality = ''}) =>
      key(sourceKey: track.id.sourceKey, songId: track.id.id, quality: quality);

  /// 单曲音频缓存文件名前缀（`{sourceKey}_{songId}_`，同一替换规则）。
  ///
  /// 音质在文件名末尾，因此该前缀命中同一曲目的所有音质变体。
  /// 与 [key] 的截断/哈希后缀兼容：前缀始终位于文件名开头
  /// （截断发生在替换后，且哈希后缀追加在末尾）。
  static String keyPrefix({required String sourceKey, required String songId}) {
    final prefix = _sanitize('${sourceKey}_${songId}_');
    return prefix.length > _maxKeyLength
        ? prefix.substring(0, _maxKeyLength)
        : prefix;
  }

  /// 单曲音频缓存前缀（命中该曲目所有音质变体）：由领域 `Track` 派生。
  static String keyPrefixForTrack(Track track) =>
      keyPrefix(sourceKey: track.id.sourceKey, songId: track.id.id);

  /// 生成音频缓存文件名：`sourceKey_songId_quality`（quality 未知用 auto）。
  ///
  /// 非文件名字符（`:`、`/` 等）替换为 `_`；发生替换时追加原串哈希后缀，
  /// 避免 `a:b` 与 `a_b` 这类不同 key 映射到同一文件名。
  static String key({
    required String sourceKey,
    required String songId,
    String quality = 'auto',
  }) {
    final effectiveQuality = quality.trim().isEmpty ? 'auto' : quality.trim();
    final raw = '${sourceKey}_${songId}_$effectiveQuality';
    final sanitized = _sanitize(raw);
    if (sanitized == raw) return raw;
    final truncated = sanitized.length > _maxKeyLength
        ? sanitized.substring(0, _maxKeyLength)
        : sanitized;
    final hash = raw.hashCode.toUnsigned(32).toRadixString(16);
    return '${truncated}_$hash';
  }

  /// 文件名是否为完整可播放的音频缓存。
  ///
  /// 半成品（[audioCachePartSuffix] / [audioCachePredownloadSuffix]）与 MIME
  /// 边车（[audioCacheMimeSuffix]）不是可播放缓存，一律排除：占用展示、命中
  /// 探测、「缓存曲目」列表共用这一口径，避免出现「缓存页说命中、播放 /
  /// 转存却拿不到文件」的两套答案。
  static bool isCompleteFileName(String name) {
    final lower = name.toLowerCase();
    return !lower.endsWith(audioCachePartSuffix) &&
        !lower.endsWith(audioCachePredownloadSuffix) &&
        !lower.endsWith(audioCacheMimeSuffix);
  }

  /// 文件名安全字符集：与 [key] 同一替换规则。
  static String _sanitize(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// 替换后文件名的最大长度（超出截断，见 [key]）。
  static const int _maxKeyLength = 100;

  // 目录与索引

  /// 音频缓存目录（持久）；目录不可用返回 null。
  Future<String?> directoryPath() => _safeDir(_storage.audioCacheDir);

  /// 音频缓存目录原始列举（含半成品 / 边车）；不可用 / 失败返回空表。
  Future<Map<String, int>> files() async {
    final dir = await directoryPath();
    if (dir == null) return const {};
    try {
      return await _storage.listFiles(dir);
    } catch (e) {
      _logger.warning('音频缓存列举失败: $e');
      return const {};
    }
  }

  /// 音频缓存索引（**只含完整可播放文件**：文件名 → 字节数）。
  ///
  /// 一次目录列举，供「缓存曲目」列表（[keyPrefix] 前缀匹配）、单曲占用与
  /// [cachedQualitiesForTrack] 复用（避免逐曲探测）。
  Future<Map<String, int>> index() async => (await splitIndex()).$1;

  /// 一次目录列举，切分完整文件索引与半成品 / 边车索引。
  ///
  /// 批量读曲（[usageForTrackInFiles]）用：一次列举服务多曲，避免逐曲重列
  /// 目录。
  Future<(Map<String, int>, Map<String, int>)> splitIndex() async {
    final files = await this.files();
    final complete = <String, int>{};
    final partials = <String, int>{};
    for (final entry in files.entries) {
      (isCompleteFileName(entry.key) ? complete : partials)[entry.key] =
          entry.value;
    }
    return (complete, partials);
  }

  /// 单曲音频缓存占用（所有音质变体；只认完整文件）。
  Future<CacheUsage> usageForTrack({
    required String sourceKey,
    required String songId,
  }) async =>
      usageForTrackInFiles(await index(), sourceKey: sourceKey, songId: songId);

  /// 从已列举的文件表统计单曲占用（批量读曲复用同一次列举）。
  static CacheUsage usageForTrackInFiles(
    Map<String, int> files, {
    required String sourceKey,
    required String songId,
  }) =>
      _usageMatching(files, keyPrefix(sourceKey: sourceKey, songId: songId));

  /// 单曲音频缓存「写入中」占用（半成品 / 边车）。
  ///
  /// 只用于占用展示解释（「有占用、但还不能离线播放」）；命中判定不看它。
  Future<CacheUsage> writingUsageForTrack({
    required String sourceKey,
    required String songId,
  }) async =>
      usageForTrackInFiles(
        (await splitIndex()).$2,
        sourceKey: sourceKey,
        songId: songId,
      );

  /// 前缀匹配统计（文件名 → 字节数）。
  static CacheUsage _usageMatching(Map<String, int> files, String prefix) {
    var bytes = 0;
    var count = 0;
    for (final entry in files.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      bytes += entry.value;
      count++;
    }
    return CacheUsage(bytes: bytes, count: count);
  }

  /// 命中完整缓存的音质（按 [Track.qualities] 顺序，去重）。
  ///
  /// [index] 为完整文件索引（`index()` 的输出）：半成品不在其中，所以「还在
  /// 写、尚未落成」不会被算作命中；同名 `.part` 复查兼容按原始列举传入的
  /// 调用方。状态展示与转存 / 离线播放共用这一判据，不会各说各话。
  static List<String> cachedQualitiesForTrack(
    Track track,
    Map<String, int> index,
  ) {
    final result = <String>[];
    for (final quality in track.qualities) {
      final type = quality.type;
      if (type.isEmpty || result.contains(type)) continue;
      final name = keyForTrack(track, quality: type);
      final size = index[name];
      if (size == null || size <= 0) continue;
      if (index.containsKey('$name$audioCachePartSuffix')) continue;
      result.add(type);
    }
    return result;
  }

  /// 完整缓存的命中路径：命中返回 `dir/name`，未命中 / 仍在写入返回 null。
  ///
  /// 命中 = 正式文件存在**且**没有同名 `.part` 半成品：有 `.part` 说明文件
  /// 还没落成（just_audio 边下载边写），现在拷贝 / 播放会读到截断数据。
  /// `.mime` 边车只是元数据，不阻止命中。
  ///
  /// [fileExists] 由调用方给，与随后真正读取该文件的操作同一视图（下载 /
  /// 转存链路的拷贝走自己的下载存储）。
  Future<String?> hitPathForTrack(
    Track track, {
    required String quality,
    required AudioCacheFileProbe fileExists,
  }) async {
    final dir = await directoryPath();
    if (dir == null) return null;
    final path = p.join(dir, keyForTrack(track, quality: quality));
    if (!await fileExists(path)) return null;
    if (await fileExists('$path$audioCachePartSuffix')) return null;
    return path;
  }

  // 清理

  /// 清理单曲音频缓存（所有音质变体，含半成品）。
  ///
  /// [protectAge] 内修改过的文件视为正在写入（边播边缓存）跳过，结果里的
  /// `skipped` 用于区分「本来没缓存」与「播放中暂不能删」。
  Future<CacheDeleteResult> clearForTrack({
    required String sourceKey,
    required String songId,
    Duration protectAge = Duration.zero,
  }) async {
    final dir = await directoryPath();
    if (dir == null) return const CacheDeleteResult();
    try {
      return await _storage.deleteMatching(
        dir,
        prefix: keyPrefix(sourceKey: sourceKey, songId: songId),
        protectAge: protectAge,
      );
    } catch (e) {
      _logger.warning('单曲音频缓存清理失败: $e');
      return const CacheDeleteResult();
    }
  }

  /// 清扫音频缓存目录里的半成品（`.part` / `.predl`），返回删除数量。
  ///
  /// 半成品的写法只存在于本进程（just_audio 边下载边写 / 字节预取）：
  /// 重启后残留的不可能是活动下载，留着只会白占 LRU 额度。
  /// `.mime` 是完整文件的边车，随完整文件一起处理，不在这里单独删。
  Future<int> cleanupPartials() async {
    final dir = await directoryPath();
    if (dir == null) return 0;
    try {
      return await _storage.deleteWhere(
        dir,
        test: (name) {
          final lower = name.toLowerCase();
          return lower.endsWith(audioCachePartSuffix) ||
              lower.endsWith(audioCachePredownloadSuffix);
        },
      );
    } catch (e) {
      _logger.warning('音频缓存半成品清扫失败: $e');
      return 0;
    }
  }

  /// 目录解析失败（平台通道缺失 / 测试假件）按不可用处理。
  Future<String?> _safeDir(Future<String?> Function() resolve) async {
    try {
      return await resolve();
    } catch (_) {
      return null;
    }
  }
}
