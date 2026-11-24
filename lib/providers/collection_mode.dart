/// 曲库聚合浏览的展示模式（专辑 / 歌手）。
///
/// 设备本地 UI 状态：持久化到偏好，不登记设置注册表、不参与同步。
/// 只服务「曲库」合集；收藏 / 历史 / 本地歌曲 / 自建列表不再有模式切换。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../app/bootstrap/runtime_providers.dart';
import '../data/settings/device_settings.dart';
import '../data/settings/device_settings_keys.dart';

part 'collection_mode.g.dart';

enum CollectionMode { albums, artists }

/// 曲库浏览模式的不可变快照。
@immutable
class CollectionModeState {
  const CollectionModeState({required this.mode, required this.isLoaded});

  final CollectionMode mode;
  final bool isLoaded;

  CollectionModeState copyWith({CollectionMode? mode, bool? isLoaded}) =>
      CollectionModeState(
        mode: mode ?? this.mode,
        isLoaded: isLoaded ?? this.isLoaded,
      );
}

@Riverpod(keepAlive: true, name: 'collectionModeProvider')
class CollectionModeStore extends _$CollectionModeStore {
  static const String prefsKey = kLibraryBrowseModeKeyName;

  late final DeviceSettings _settings;

  @override
  CollectionModeState build() {
    _settings = ref.watch(deviceSettingsProvider);
    unawaited(_load());
    return const CollectionModeState(
      mode: CollectionMode.albums,
      isLoaded: false,
    );
  }

  Future<void> _load() async {
    final raw = await _settings.read(kLibraryBrowseModeKey);
    final mode = CollectionMode.values.firstWhere(
      (mode) => mode.name == raw,
      orElse: () => CollectionMode.albums,
    );
    state = state.copyWith(mode: mode, isLoaded: true);
  }

  Future<void> load() => _load();

  Future<void> setMode(CollectionMode mode) async {
    if (state.mode == mode) return;
    state = state.copyWith(mode: mode);
    await _settings.write(kLibraryBrowseModeKey, mode.name);
  }
}
