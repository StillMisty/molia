import 'dart:async';

import 'package:flutter_media_session/flutter_media_session.dart';
import 'package:molia/playback/media_session_backend.dart';

/// 记录型媒体会话后端：单测断言元数据 / 状态 / 动作映射，不触碰平台通道。
class FakeMediaSessionBackend implements MediaSessionBackend {
  FakeMediaSessionBackend();

  final StreamController<MediaAction> _actions =
      StreamController<MediaAction>.broadcast();

  int activateCalls = 0;
  int deactivateCalls = 0;
  final List<MediaMetadata> metadataUpdates = [];
  final List<PlaybackState> stateUpdates = [];
  final List<Set<MediaAction>> actionUpdates = [];

  MediaMetadata? get lastMetadata =>
      metadataUpdates.isEmpty ? null : metadataUpdates.last;
  PlaybackState? get lastState =>
      stateUpdates.isEmpty ? null : stateUpdates.last;
  Set<MediaAction>? get lastActions =>
      actionUpdates.isEmpty ? null : actionUpdates.last;

  /// 播放顺序自定义动作（按名字查找，便于断言图标 / 文案）。
  MediaAction? get playModeAction {
    for (final action in lastActions ?? const <MediaAction>{}) {
      if (action.name == 'lx.playMode') return action;
    }
    return null;
  }

  /// 收藏自定义动作（同上）。
  MediaAction? get favoriteAction {
    for (final action in lastActions ?? const <MediaAction>{}) {
      if (action.name == 'lx.favorite') return action;
    }
    return null;
  }

  @override
  Future<void> activate() async {
    activateCalls++;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls++;
  }

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {
    metadataUpdates.add(metadata);
  }

  @override
  Future<void> updatePlaybackState(PlaybackState state) async {
    stateUpdates.add(state);
  }

  @override
  Future<void> updateAvailableActions(Set<MediaAction> actions) async {
    actionUpdates.add(Set<MediaAction>.unmodifiable(actions));
  }

  @override
  Stream<MediaAction> get actions => _actions.stream;

  /// 模拟系统控制（通知 / 锁屏 / 耳机键 / 媒体浮层）。
  void emit(MediaAction action) => _actions.add(action);

  Future<void> dispose() => _actions.close();
}
