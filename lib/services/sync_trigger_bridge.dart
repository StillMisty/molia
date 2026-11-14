import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/settings/settings_key.dart';
import '../data/settings/settings_registry.dart';
import '../domain/models/device_sync.dart';
import '../services/covers/custom_cover_store.dart';
import '../services/playback_session_store.dart';
import '../sources/source_manager.dart';

/// 一次本地变更的同步语义：类别 + 是否排即时轮次。
@immutable
class SyncChange {
  const SyncChange({this.categories, this.immediate = true});

  /// null = 标记全部启用类别（与 `SyncScheduler.notifyLocalChange` 一致）。
  final Set<SyncCategory>? categories;

  /// false = 只标记待发、不续期活跃窗口（高频写入如会话进度）。
  final bool immediate;
}

/// 本地变更入队回调（生产 = `SyncScheduler.notifyLocalChange`）。
typedef SyncChangeSink = void Function({
  Set<SyncCategory>? categories,
  bool immediate,
});

/// 同步触发桥：**唯一**持有「数据变更 → 调度器」订阅与回调钩子的 owner。
///
/// 资料库 / 统计流、音源 `ChangeNotifier`、设置写入钩子、脚本导入 / 删除钩子、
/// 会话落盘与封面写入的注册都收在这一处；`dispose()` 取消流订阅，并把所有
/// 回调钩子恢复为绑前值。
///
/// 只转发变更事实，不决定何时跑轮次（仍是 [SyncScheduler] 的策略）。
class SyncTriggerBridge {
  SyncTriggerBridge({required SyncChangeSink localChange})
    : _sink = localChange;

  final SyncChangeSink _sink;
  final List<StreamSubscription<SyncChange>> _subscriptions = [];
  final List<void Function()> _restores = [];
  bool _disposed = false;

  /// 把一条类型化变更流接到调度器。
  void attach(Stream<SyncChange> changes) {
    if (_disposed) return;
    _subscriptions.add(
      changes.listen(
        (change) => localChange(
          categories: change.categories,
          immediate: change.immediate,
        ),
      ),
    );
  }

  /// 直接标记一次本地变更；回调型触发源（设置 / 会话 / 封面）统一走这里。
  void localChange({Set<SyncCategory>? categories, bool immediate = true}) {
    if (_disposed) return;
    _sink(categories: categories, immediate: immediate);
  }

  /// 音源仓库变化（导入 / 删除 / 激活）→ 音源类别。
  void bindSourceManager(SourceManager sourceManager) {
    void onChange() => localChange(categories: const {SyncCategory.sources});
    sourceManager.addListener(onChange);
    _restores.add(() => sourceManager.removeListener(onChange));
  }

  /// 设置 / 凭证写入：先调用绑前钩子，再标记类别并交给调用方追加增量日志。
  ///
  /// `SettingsRegistry.onWrite` 只允许绑定一次：链式绑定必须显式解绑旧钩子，
  /// 再由 wrapper 调用 `previous`，否则 previous 非空时 setter 会 assert /
  /// 抛错。恢复时同样先解绑 wrapper 再写回 previous（previous 为 null 或非空
  /// 都沿用 setter 的既有语义），不会静默吞掉已有订阅者。
  void bindSettingsWrites(
    SettingsRegistry settings, {
    required void Function(SettingsKey<Object?> key) onKeyWritten,
  }) {
    final previous = settings.onWrite;
    settings.onWrite = null;
    settings.onWrite = (key) {
      previous?.call(key);
      localChange(categories: {key.category});
      onKeyWritten(key);
    };
    _restores.add(() {
      settings.onWrite = null;
      settings.onWrite = previous;
    });
  }

  /// 脚本导入 / 删除回调：先调用绑前回调，再交给调用方追加增量日志；
  /// 音源类别标记由 [bindSourceManager] 的监听统一发出。
  void bindScriptWrites(
    SourceManager sourceManager, {
    required void Function(String id) onScriptWritten,
    required void Function(String id) onScriptRemoved,
  }) {
    final previousWritten = sourceManager.onScriptWritten;
    final previousRemoved = sourceManager.onScriptRemoved;
    sourceManager.onScriptWritten = (id) {
      previousWritten?.call(id);
      onScriptWritten(id);
    };
    sourceManager.onScriptRemoved = (id) {
      previousRemoved?.call(id);
      onScriptRemoved(id);
    };
    _restores.add(() {
      sourceManager.onScriptWritten = previousWritten;
      sourceManager.onScriptRemoved = previousRemoved;
    });
  }

  /// 播放会话落盘：先调用绑前回调，再标记待发（高频进度只标记、不排即时
  /// 轮次），最后交给适配器记账。
  void bindSessionSaves(
    PlaybackSessionStore store, {
    required void Function() onSaved,
  }) {
    final previous = store.onSaved;
    store.onSaved = () {
      previous?.call();
      localChange(categories: const {SyncCategory.session}, immediate: false);
      onSaved();
    };
    _restores.add(() => store.onSaved = previous);
  }

  /// 本地封面写入：先调用绑前回调，再标记封面类别（远端应用不走
  /// `onLocalChange`，不会回环）。
  void bindLocalCoverChanges(CustomCoverStore covers) {
    final previous = covers.onLocalChange;
    covers.onLocalChange = (change) {
      previous?.call(change);
      localChange(categories: const {SyncCategory.covers});
    };
    _restores.add(() => covers.onLocalChange = previous);
  }

  /// 取消全部流订阅并恢复回调钩子；重复调用安全。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    // 逆序恢复：同一钩子被多层包装时最后绑定的先摘。
    for (final restore in _restores.reversed) {
      restore();
    }
    _restores.clear();
  }
}
