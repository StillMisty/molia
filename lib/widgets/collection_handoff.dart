/// 合集动作的曲目交接适配：把 [CollectionHandoff] 端口接到 TrackHandoff。
///
/// 为什么单独一层：`collection_actions.dart` 属于 providers 层，命令编排必须
/// 不依赖 BuildContext / widgets，才能在纯 Dart 单测里用假端口断言；而播放 /
/// 加入列表的唯一编排（TrackHandoff）本身需要 context 与 provider。这里只做
/// 「端口 → 既有实现」的适配，不复制队列 / 洗牌 / 上下文名逻辑。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../providers/collection_actions.dart';
import 'track_handoff.dart';

/// [CollectionHandoff] 的生产实现：唯一编排仍在 `track_handoff.dart`。
final class TrackHandoffCollectionHandoff implements CollectionHandoff {
  /// [random] 只用于随机播放起点（测试注入固定种子；生产不传）。
  TrackHandoffCollectionHandoff(this._context, {math.Random? random})
      : _handoff = TrackHandoff(random: random);

  final BuildContext _context;
  final TrackHandoff _handoff;

  @override
  Future<void> play(
    List<Track> tracks, {
    required int startIndex,
    required bool shuffle,
    required String contextName,
  }) =>
      _handoff.play(
        _context,
        tracks,
        startIndex: startIndex,
        shuffle: shuffle,
        contextName: contextName,
      );

  @override
  Future<bool> addToLibrary(
    List<PlaylistTrack> tracks, {
    required bool includeFavorites,
    required bool includeHistory,
  }) =>
      _handoff.addPlaylistTracksToLibrary(
        _context,
        tracks,
        includeFavorites: includeFavorites,
        includeHistory: includeHistory,
      );
}
