import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:logger/logger.dart';

import '../domain/models/track.dart';
import 'artwork_cache.dart';

/// 图片预加载管理器
///
/// 功能:
/// - 智能图片预加载队列
/// - LRU 缓存管理
/// - 并发控制
/// - 优先级队列
class ImagePreloadManager {
  static final ImagePreloadManager _instance = ImagePreloadManager._internal();
  factory ImagePreloadManager() => _instance;
  ImagePreloadManager._internal();

  final Logger _logger = Logger();

  /// 已缓存的图片 URL（LRU 缓存）
  final LinkedHashMap<String, DateTime> _cachedUrls = LinkedHashMap();

  /// 正在加载的图片 URL
  final Set<String> _loadingUrls = {};

  /// 预加载队列（优先级队列）
  final List<_PreloadTask> _queue = [];

  /// 最大缓存数量
  static const int _maxCacheSize = 100;

  /// 最大并发加载数
  static const int _maxConcurrent = 3;

  /// 当前并发数
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
  ///
  /// 包括：当前曲目、上一首、下一首、队列前几首
  Future<void> preloadPlaybackImages({
    required BuildContext context,
    String? currentAlbumArt,
    String? previousAlbumArt,
    String? nextAlbumArt,
    List<String?>? queueAlbumArts,
  }) async {
    // 收集所有需要预加载的任务，然后一次性添加到队列
    // 这样避免在 async gaps 中使用 context
    final tasks = <({String url, int priority})>[];

    // 当前曲目最高优先级
    if (currentAlbumArt != null) {
      tasks.add((url: currentAlbumArt, priority: 100));
    }

    // 下一首次高优先级
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

    // 同步添加所有任务
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
        _logger.w('预加载图片失败: ${task.url}, 错误: $e');
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
///
/// 根据播放状态智能预加载相关专辑封面
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
