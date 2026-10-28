/// 下载提交日志：rename 前落一条 pending 记录，DB 落库后删除。
///
/// 为什么不写数据库：这里只需要「文件已就位、记录还没落库」的极短窗口，
/// 加表 / 迁移会牵动 drift schema；单条 JSON 也便于在启动时逐条恢复 / 清理。
///
/// 为什么放应用支持目录而不是下载根：用户可能改保存位置或清空公共下载目录，
/// 提交日志不能跟着丢；同时它也不是用户文件，不应出现在「下载」文件夹。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../data/downloads/download_storage.dart';
import '../../domain/models/download.dart';

/// 文件型下载提交日志（每个原音源曲目键一个 marker）。
class DownloadJournal {
  DownloadJournal(this._storage);

  final DownloadStorage _storage;
  final Logger _logger = Logger('molia.download_journal');
  bool _unavailableLogged = false;

  /// 写一条 pending 记录（原子替换同名 marker）。
  ///
  /// 返回 false 表示这次提交没有崩溃保护（目录不可用 / 编码失败 / 写临时
  /// 文件或 rename 失败）。调用方必须在 rename 前中止，不能把「没有提交
  /// 日志的 rename」当成成功——否则崩溃恢复保证失效。
  Future<bool> write(DownloadedTrack record) async {
    final root = await _journalRoot();
    if (root == null) return false;
    final target = _markerPath(root, record.key);
    final tmp = '$target.tmp';
    String content;
    try {
      content = jsonEncode(_encode(record));
    } catch (e) {
      _logger.warning('下载日志编码失败（${record.key}）: $e');
      await _storage.deleteQuietly(tmp);
      return false;
    }
    try {
      await _storage.writeString(tmp, content);
      // 部分平台 rename 不覆盖已有文件：先删旧目标再改名。
      await _storage.deleteQuietly(target);
      await _storage.rename(tmp, target);
      return true;
    } catch (e) {
      _logger.warning('下载日志写入失败（${record.key}）: $e');
      await _storage.deleteQuietly(tmp);
      return false;
    }
  }

  /// 读取全部有效 marker；顺手清理 `.tmp` 与损坏 JSON。
  Future<List<({String markerPath, DownloadedTrack record})>> readAll() async {
    final root = await _journalRoot();
    if (root == null) return const [];
    try {
      final paths = await _storage.listFiles(root);
      final entries = <({String markerPath, DownloadedTrack record})>[];
      for (final path in paths) {
        if (path.endsWith('.tmp')) {
          await _storage.deleteQuietly(path);
          continue;
        }
        if (!path.endsWith('.json')) continue;
        final text = await _storage.readString(path);
        if (text == null) {
          await _storage.deleteQuietly(path);
          continue;
        }
        final record = _decode(text);
        if (record == null) {
          await _storage.deleteQuietly(path);
          continue;
        }
        entries.add((markerPath: path, record: record));
      }
      return entries;
    } catch (e) {
      _logger.warning('下载日志扫描失败: $e');
      return const [];
    }
  }

  /// 删除某个曲目键对应的 marker（含残留 tmp）。
  Future<void> remove(String key) async {
    final root = await _journalRoot();
    if (root == null) return;
    final target = _markerPath(root, key);
    await _storage.deleteQuietly(target);
    await _storage.deleteQuietly('$target.tmp');
  }

  /// 删除读取时拿到的 marker。
  Future<void> removePath(String markerPath) async {
    await _storage.deleteQuietly(markerPath);
  }

  Future<String?> _journalRoot() async {
    try {
      final root = await _storage.journalRoot();
      if (root == null && !_unavailableLogged) {
        _unavailableLogged = true;
        _logger.warning('下载日志目录不可用：本次运行无崩溃恢复');
      }
      return root;
    } catch (e) {
      _logger.warning('下载日志目录不可用: $e');
      return null;
    }
  }

  static String _markerPath(String root, String key) =>
      p.join(root, '${crypto.md5.convert(utf8.encode(key))}.json');

  static Map<String, dynamic> _encode(DownloadedTrack record) => {
    'originSourceKey': record.originSourceKey,
    'originSongId': record.originSongId,
    'title': record.title,
    'artist': record.artist,
    'album': record.album,
    'coverUrl': record.coverUrl,
    'durationMs': record.durationMs,
    'raw': record.raw,
    'quality': record.quality,
    'filePath': record.filePath,
    'sizeBytes': record.sizeBytes,
    'lyricPath': record.lyricPath,
    'coverPath': record.coverPath,
    'publicUri': record.publicUri,
    'imported': record.imported,
    'downloadedAt': record.downloadedAt,
  };

  static DownloadedTrack? _decode(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      final sourceKey = _string(json['originSourceKey']);
      final songId = _string(json['originSongId']);
      if (sourceKey == null || songId == null) return null;
      final rawValue = json['raw'];
      final raw = rawValue is Map
          ? Map<String, dynamic>.from(rawValue)
          : const <String, dynamic>{};
      return DownloadedTrack(
        originSourceKey: sourceKey,
        originSongId: songId,
        title: _string(json['title']) ?? '',
        artist: _string(json['artist']) ?? '',
        album: _string(json['album']) ?? '',
        coverUrl: _string(json['coverUrl']),
        durationMs: _int(json['durationMs']),
        raw: raw,
        quality: _string(json['quality']) ?? '',
        filePath: _string(json['filePath']),
        sizeBytes: _int(json['sizeBytes']) ?? 0,
        lyricPath: _string(json['lyricPath']),
        coverPath: _string(json['coverPath']),
        publicUri: _string(json['publicUri']),
        imported: json['imported'] == true,
        downloadedAt: _int(json['downloadedAt']) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static String? _string(Object? value) => value is String ? value : null;

  static int? _int(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : null);
}
