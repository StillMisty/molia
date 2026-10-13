import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../domain/models/track.dart';
import 'artwork_cache.dart';

/// 图片预加载管理器：优先级队列、并发控制与 LRU 去重。
class ImagePreloadManager {
  static final ImagePreloadManager _instance = ImagePreloadManager._internal();
  factory ImagePreloadManager() => _instance;
  ImagePreloadManager._internal();

  final Logger _logger = Logger('molia.image_preload_manager');

  /// 已缓存的图片 URL（LRU 缓存）
  final LinkedHashMap<String, DateTime> _cachedUrls = LinkedHashMap();

  final Set<String> _loadingUrls = {};

  final List<_PreloadTask> _queue = [];

  static const int _maxCacheSize = 100;

  static const int _maxConcurrent = 3;

  int _currentConcurrent = 0;

  /// 入队预加载单张图片（内部使用）；[priority] 数值越大越优先。
  void _enqueue(
    String? url,
    BuildContext context, {
    int priority = 0,
  }) {
    if (url == null || url.isEmpty) return;
    if (_cachedUrls.containsKey(url)) return;
    if (_loadingUrls.contains(url)) return;

    _queue.add(_PreloadTask(url: url, priority: priority, context: context));
    _queue.sort((a, b) => b.priority.compareTo(a.priority));

    _processQueue();
  }

  /// 预加载当前播放相关的图片
  Future<void> preloadPlaybackImages({
    required BuildContext context,
    String? currentAlbumArt,
    String? previousAlbumArt,
    String? nextAlbumArt,
    List<String?>? queueAlbumArts,
  }) async {
    // 先收集任务再统一入队：避免在 async gap 之后使用 context。
    final tasks = <({String url, int priority})>[];

    if (currentAlbumArt != null) {
      tasks.add((url: currentAlbumArt, priority: 100));
    }

    if (nextAlbumArt != null) {
      tasks.add((url: nextAlbumArt, priority: 90));
    }

    if (previousAlbumArt != null) {
      tasks.add((url: previousAlbumArt, priority: 80));
    }

    if (queueAlbumArts != null) {
      for (var i = 0; i < queueAlbumArts.length && i < 5; i++) {
        final url = queueAlbumArts[i];
        if (url != null) {
          tasks.add((url: url, priority: 70 - i * 10));
        }
      }
    }

    for (final task in tasks) {
      _enqueue(task.url, context, priority: task.priority);
    }
  }

  void _processQueue() {
    while (_currentConcurrent < _maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);

      if (_cachedUrls.containsKey(task.url) || _loadingUrls.contains(task.url)) {
        continue;
      }

      _currentConcurrent++;
      _loadingUrls.add(task.url);

      _loadImage(task).then((_) {
        _currentConcurrent--;
        _loadingUrls.remove(task.url);
        _processQueue();
      }).catchError((e) {
        _currentConcurrent--;
        _loadingUrls.remove(task.url);
        _logger.warning('预加载图片失败: ${task.url}, 错误: $e');
        _processQueue();
      });
    }
  }

  Future<void> _loadImage(_PreloadTask task) async {
    if (!task.context.mounted) return;

    final imageProvider = await artworkImageProvider(task.url);
    if (!task.context.mounted) return;
    await precacheImage(imageProvider, task.context);

    _addToCache(task.url);
  }

  void _addToCache(String url) {
    // 如果已存在，先移除（为了更新 LRU 顺序）
    _cachedUrls.remove(url);

    _cachedUrls[url] = DateTime.now();

    while (_cachedUrls.length > _maxCacheSize) {
      _cachedUrls.remove(_cachedUrls.keys.first);
    }
  }
}

class _PreloadTask {
  final String url;
  final int priority;
  final BuildContext context;

  _PreloadTask({
    required this.url,
    required this.priority,
    required this.context,
  });
}

/// 专辑封面预加载策略
class AlbumArtPreloadStrategy {
  final ImagePreloadManager _manager = ImagePreloadManager();

  /// 从领域曲目提取封面 URL（无封面返回 null）。
  String? albumArtOf(Track? track) {
    final artwork = track?.artwork;
    if (artwork == null) return null;
    final url = artwork.uri.toString();
    return url.isEmpty ? null : url;
  }

  /// 预加载播放相关的封面
  Future<void> preloadForPlayback({
    required BuildContext context,
    Track? currentTrack,
    Track? nextTrack,
    List<Track>? upcomingTracks,
  }) async {
    final queueArts =
        upcomingTracks?.take(5).map(albumArtOf).toList();

    await _manager.preloadPlaybackImages(
      context: context,
      currentAlbumArt: albumArtOf(currentTrack),
      nextAlbumArt: albumArtOf(nextTrack),
      queueAlbumArts: queueArts,
    );
  }
}
