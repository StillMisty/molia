/// 音乐文件夹监听：文件系统事件只是「防抖后重新扫描」的触发器。
///
/// 为什么不是真相来源：网络卷 / macOS FSEvents 会丢事件或风暴；监听失败、
/// 事件溢出都静默降级为启动 / 手动扫描。事件本身不逐文件导入。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 目录事件流工厂（测试注入假事件流；生产用 `Directory.watch`）。
typedef FolderEventStream = Stream<FileSystemEvent> Function(String root);

class MusicFolderWatcher {
  MusicFolderWatcher({
    FolderEventStream? watch,
    this.debounce = const Duration(seconds: 2),
    required this.onTrigger,
  }) : _watch = watch ?? _defaultWatch;

  final FolderEventStream _watch;
  final Duration debounce;

  /// 防抖后触发一次增量扫描；[paths] 为事件里能定位到的文件路径（null =
  /// 无法定位 / 事件溢出，整树增量）。扫描在跑时只记一个 pending。
  final Future<void> Function(Set<String>? paths) onTrigger;

  final Map<String, StreamSubscription<FileSystemEvent>> _subscriptions = {};
  Timer? _timer;
  bool _running = false;
  bool _pending = false;
  final Set<String> _pendingPaths = {};
  bool _overflow = false;

  /// 单次防抖合并的路径上限；超过即按「无法定位」整树增量。
  static const int _maxPendingPaths = 64;

  static Stream<FileSystemEvent> _defaultWatch(String root) =>
      Directory(root).watch(recursive: true);

  /// 开始监听给定根目录；重复根忽略，监听失败静默跳过（降级为手动扫描）。
  void start(Iterable<String> roots) {
    for (final root in roots) {
      if (_subscriptions.containsKey(root)) continue;
      try {
        _subscriptions[root] = _watch(root).listen(
          (event) {
            if (_pendingPaths.length < _maxPendingPaths) {
              _pendingPaths.add(event.path);
            } else {
              _overflow = true;
            }
            _schedule();
          },
          onError: (Object error) {
            debugPrint('[Molia] 音乐文件夹监听失败（降级为手动扫描）: $error');
          },
          cancelOnError: true,
        );
      } catch (e) {
        debugPrint('[Molia] 音乐文件夹监听无法启动（降级为手动扫描）: $e');
      }
    }
  }

  /// 停止全部监听并取消待触发的防抖。
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final subscriptions = _subscriptions.values.toList();
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, _fire);
  }

  Future<void> _fire() async {
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    final paths = _overflow || _pendingPaths.isEmpty
        ? null
        : Set<String>.of(_pendingPaths);
    _pendingPaths.clear();
    _overflow = false;
    try {
      await onTrigger(paths);
    } finally {
      _running = false;
      if (_pending) {
        _pending = false;
        _schedule();
      }
    }
  }
}
