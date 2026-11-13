/// 听歌同步的纯规则：资格、阈值与会话判定。
///
/// 这里不碰播放内核、网络与存储；`ScrobbleService` 只负责把播放快照 /
/// 进度喂进来，按本文件的结论决定「发不发、发什么」。
library;

import 'dart:math' as math;

import '../models/scrobble.dart';

/// 一次播放会话（一首歌从开始到被替换 / 停止）。
///
/// 会话身份只由「曲目开始播放」决定：暂停、恢复、前后拖动都不新建会话，
/// 因此同一遍播放最多产生一条 scrobble。
class ScrobbleSession {
  ScrobbleSession({required this.track, required this.startedAt});

  final ScrobbleTrack track;

  /// 本次播放的开始时间（now-playing 与 scrobble 共用这个时间戳）。
  final DateTime startedAt;

  /// 已到达过的最远播放位置。
  ///
  /// 只前进不后退：向后拖动不会把阈值重置，因此不会产生第二条 scrobble；
  /// 暂停期间位置不变，恢复后继续累计。
  Duration _maxPosition = Duration.zero;

  bool _scrobbled = false;

  Duration get maxPosition => _maxPosition;

  /// 是否已经产出过 scrobble（同一会话只产出一次）。
  bool get hasScrobbled => _scrobbled;

  /// 本条会话的 scrobble 阈值。
  Duration get threshold => ScrobbleRules.thresholdFor(track.duration);

  /// 喂入一个播放位置；达到阈值时返回一条 scrobble 事件，否则 null。
  ///
  /// 只接受非负位置；位置回退（seek backward）不会撤销已到达的进度。
  ScrobbleEvent? onPosition(Duration position) {
    if (_scrobbled || position <= Duration.zero) return null;
    if (position > _maxPosition) _maxPosition = position;
    if (!ScrobbleRules.reachedThreshold(
      maxPosition: _maxPosition,
      duration: track.duration,
    )) {
      return null;
    }
    _scrobbled = true;
    return ScrobbleRules.scrobbleEvent(track: track, startedAt: startedAt);
  }

  /// 本条会话的 now-playing 事件。
  ScrobbleEvent nowPlayingEvent() =>
      ScrobbleRules.nowPlayingEvent(track: track, startedAt: startedAt);
}

/// 纯规则集合（无状态，便于单独测边界）。
abstract final class ScrobbleRules {
  /// 最短可上报时长：更短的曲目永远不 scrobble，也不发 now-playing。
  static const Duration minDuration = Duration(seconds: 30);

  /// 阈值上限：长曲目最多播放四分钟即计入。
  static const Duration maxThreshold = Duration(minutes: 4);

  /// 阈值比例：时长的 50%。
  static const double thresholdRatio = 0.5;

  /// 是否具备上报资格：有标题和歌手，且时长达到最短限制。
  static bool isEligible(ScrobbleTrack track) =>
      track.title.trim().isNotEmpty &&
      track.artist.trim().isNotEmpty &&
      track.duration >= minDuration;

  /// 阈值 = min(时长 × 50%, 4 分钟)。
  ///
  /// 时长未知 / 为 0 时返回 [maxThreshold]（等长曲目按最长规则），调用方
  /// 仍需先过 [isEligible]。
  static Duration thresholdFor(Duration duration) {
    if (duration <= Duration.zero) return maxThreshold;
    final half = Duration(
      milliseconds: (duration.inMilliseconds * thresholdRatio).round(),
    );
    return half < maxThreshold ? half : maxThreshold;
  }

  /// 是否到达阈值（按本次会话到达过的最远位置计）。
  static bool reachedThreshold({
    required Duration maxPosition,
    required Duration duration,
  }) => maxPosition >= thresholdFor(duration);

  /// 构造 scrobble 事件；调用方负责先过 [isEligible]。
  static ScrobbleEvent scrobbleEvent({
    required ScrobbleTrack track,
    required DateTime startedAt,
  }) => ScrobbleEvent(
    id: eventId(
      track: track,
      startedAt: startedAt,
      kind: ScrobbleEventKind.scrobble,
    ),
    target: ScrobbleTarget.listenBrainz, // 服务在入队时按目标复制改写
    kind: ScrobbleEventKind.scrobble,
    listen: ScrobbleListen(track: track, startedAt: startedAt),
    createdAt: startedAt,
  );

  /// 构造 now-playing 事件；调用方负责先过 [isEligible]。
  static ScrobbleEvent nowPlayingEvent({
    required ScrobbleTrack track,
    required DateTime startedAt,
  }) => ScrobbleEvent(
    id: eventId(
      track: track,
      startedAt: startedAt,
      kind: ScrobbleEventKind.nowPlaying,
    ),
    target: ScrobbleTarget.listenBrainz,
    kind: ScrobbleEventKind.nowPlaying,
    listen: ScrobbleListen(track: track, startedAt: startedAt),
    createdAt: startedAt,
  );

  /// 会话内稳定 id：同一曲目 + 同一开始时间 + 事件类型唯一。
  static String eventId({
    required ScrobbleTrack track,
    required DateTime startedAt,
    required ScrobbleEventKind kind,
  }) {
    final hash = Object.hash(
      track.title,
      track.artist,
      track.album,
      startedAt.millisecondsSinceEpoch,
      kind,
    );
    return '${startedAt.millisecondsSinceEpoch}-${hash & 0x7fffffff}';
  }

  /// 退避时长：指数增长（2^n 秒）并加 ±20% 抖动，封顶 30 分钟。
  ///
  /// [jitter] 传 0..1 的随机值（测试可固定），默认取 0.5（无抖动）。
  static Duration backoffFor(int attempts, {double jitter = 0.5}) {
    final exp = math.min(attempts, 11); // 2^11 秒 ≈ 34 分钟，封顶后无意义
    final baseSeconds = math.pow(2, exp).toDouble();
    final factor = 0.8 + 0.4 * jitter.clamp(0.0, 1.0);
    final seconds = (baseSeconds * factor).clamp(1.0, 1800.0);
    return Duration(milliseconds: (seconds * 1000).round());
  }
}
