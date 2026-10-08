import 'dart:async';

import '../../domain/models/source.dart' as domain;
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../domain/ports/source_registry.dart';
import '../../sources/source_manager.dart';
import 'manager_catalog_source.dart';

/// `SourceManager` → 领域 `SourceRegistry` 适配器（阶段 2，施工图 §2.3.3）。
///
/// 职责：
/// - `descriptors`：由 `manager.searchableSources` 映射（顺序即用户排序结果，
///   `order` 为列表下标，0 起）；`lx_source_order` 的读写完全由 manager 承担；
/// - `byKey`/`forTrack`：懒创建并缓存 [SourceManagerMusicSource]（按 key 单例）；
/// - `changes`：把 manager 的 ChangeNotifier 通知转发为广播流；
/// - `refresh`：仅广播一次变更（manager 状态变化本就自动通知），供外部
///   状态（登录态等）变化后强制消费方重读描述列表。
///
/// 说明：`byKey` 对当前不在 `searchableSources` 中的 key 也会返回适配器，
/// 以便播放队列中“源已停用”的曲目仍能路由到 manager 并得到可读错误；
/// 只有空 key 返回 null。
class SourceRegistryImpl implements SourceRegistry {
  SourceRegistryImpl(this._manager) {
    _manager.addListener(_onManagerChanged);
  }

  final SourceManager _manager;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final Map<String, SourceManagerMusicSource> _sources = {};

  bool _disposed = false;

  @override
  List<domain.SourceDescriptor> get descriptors {
    final options = _manager.searchableSources;
    return [
      for (var index = 0; index < options.length; index++)
        domain.SourceDescriptor(
          key: options[index].key,
          displayName: options[index].name,
          kind: _kindOf(options[index].kind),
          capabilities: _manager.capabilitiesFor(options[index].key),
          enabled: true,
          order: index,
        ),
    ];
  }

  @override
  MusicSource? byKey(String key) {
    if (key.isEmpty) return null;
    return _sources.putIfAbsent(
      key,
      () => SourceManagerMusicSource(key, _manager),
    );
  }

  @override
  MusicSource? forTrack(Track track) => byKey(track.id.sourceKey);

  @override
  Future<void> refresh() async {
    _emitChange();
  }

  @override
  Future<void> setOrder(List<String> keys) => _manager.setSourceOrder(keys);

  @override
  Stream<void> get changes => _changes.stream;

  /// 释放监听与变更流（manager 由 composition root 管理，不在此 dispose）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _manager.removeListener(_onManagerChanged);
    _changes.close();
  }

  void _onManagerChanged() => _emitChange();

  void _emitChange() {
    if (!_changes.isClosed) _changes.add(null);
  }

  domain.SourceKind _kindOf(SourceKind kind) {
    switch (kind) {
      case SourceKind.builtin:
        return domain.SourceKind.builtin;
      case SourceKind.lx:
        return domain.SourceKind.lx;
      case SourceKind.anyListen:
        return domain.SourceKind.anyListen;
    }
  }
}
