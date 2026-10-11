import 'dart:async';

import 'package:flutter/foundation.dart';

/// 分类通知节流器 - 支持按类别独立节流
///
/// 例如：播放进度更新 vs 曲目切换
class CategorizedNotifyThrottler {
  final VoidCallback notifyCallback;
  final Map<String, Duration> categoryIntervals;
  final Duration defaultInterval;

  final Map<String, DateTime> _lastNotifyTimes = {};
  final Map<String, Timer?> _pendingTimers = {};
  final Map<String, bool> _hasPendingNotifications = {};

  CategorizedNotifyThrottler({
    required this.notifyCallback,
    this.categoryIntervals = const {},
    this.defaultInterval = const Duration(milliseconds: 50),
  });

  void notify(String category) {
    final now = DateTime.now();
    final interval = categoryIntervals[category] ?? defaultInterval;
    final lastTime = _lastNotifyTimes[category];

    if (lastTime == null || now.difference(lastTime) >= interval) {
      _executeNotify(category, now);
      return;
    }

    _hasPendingNotifications[category] = true;
    _pendingTimers[category] ??= Timer(
      interval - now.difference(lastTime),
      () {
        if (_hasPendingNotifications[category] == true) {
          _executeNotify(category, DateTime.now());
        }
        _pendingTimers[category] = null;
      },
    );
  }

  void _executeNotify(String category, DateTime time) {
    _lastNotifyTimes[category] = time;
    _hasPendingNotifications[category] = false;
    notifyCallback();
  }

  void dispose() {
    for (final timer in _pendingTimers.values) {
      timer?.cancel();
    }
    _pendingTimers.clear();
    _hasPendingNotifications.clear();
  }
}
