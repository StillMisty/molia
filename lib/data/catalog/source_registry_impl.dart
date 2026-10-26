import 'dart:async';

import '../../domain/models/source.dart' as domain;
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../domain/ports/source_registry.dart';
import '../../sources/source_manager.dart';
import 'local_music_source.dart';
import 'manager_catalog_source.dart';

/// `SourceManager` → 领域 `SourceRegistry` 适配器。
///
/// 职责：
/// - `descriptors`：由 `manager.sourceProfiles.searchable` 映射（顺序即用户
///   排序结果，`order` 为列表下标，0 起；能力位直接取画像，不再二次推导）；
///   `lx_source_order` 的读写完全由 manager 承担；
/// - `byKey`/`forTrack`：懒创建并缓存 [SourceManagerMusicSource]（按 key 单例）；
///   `local` key 特殊路由到 [LocalMusicSource]（本地下载副本，manager 不认识）；
/// - `changes`：把 manager 的 ChangeNotifier 通知转发为广播流；
/// - `refresh`：仅广播一次变更（manager 状态变化本就自动通知），供外部
///   状态（登录态等）变化后强制消费方重读描述列表。
///
/// 说明：`byKey` 对当前不在 `searchableSources` 中的 key 也会返回适配器，
/// 以便播放队列中“源已停用”的曲目仍能路由到 manager 并得到可读错误；
/// 只有空 key 返回 null。
class SourceRegistryImpl implements SourceRegistry {
  SourceRegistryImpl(this._manager, {LocalMusicSource? localSource}) {
    _manager.addListener(_onManagerChanged);
    _localSource = localSource ?? LocalMusicSource();
  }

  final SourceManager _manager;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final Map<String, SourceManagerMusicSource> _sources = {};

  /// 本地下载音源（`local` key 唯一实例）。
  late final LocalMusicSource _localSource;

  bool _disposed = false;

  @override
  List<domain.SourceDescriptor> get descriptors {
    // 一次快照同时给出顺序与能力位：避免列表来自 channels、能力又来自
    // capabilitiesFor 的二次读取在状态切换时对不上。
    final profiles = _manager.sourceProfiles.searchable;
    return [
      for (var index = 0; index < profiles.length; index++)
        domain.SourceDescriptor(
          key: profiles[index].key,
          displayName: profiles[index].displayName,
          kind: _kindOf(profiles[index].kind),
          capabilities: profiles[index].capabilities,
          enabled: true,
          order: index,
        ),
    ];
  }

  @override
  Set<String> get enabledChannelKeys => {
        for (final profile in _manager.sourceProfiles.channels)
          if (profile.enabled) profile.key,
      };

  @override
  MusicSource? byKey(String key) {
    if (key.isEmpty) return null;
    // 本地下载副本：manager 不认识该 key，直接返回本地音源
    //（否则会被懒造成 SourceManagerMusicSource 并撞 manager 报错）。
    if (key == LocalMusicSource.sourceKey) return _localSource;
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
