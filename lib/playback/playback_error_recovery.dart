/// 播放失败恢复策略：取链缓存失效 → 同源重试一次 → 自动换源。
///
/// **为什么单独成模块**：重试次数、换源守卫与 provenance 只随恢复策略变化，
/// 与 UI 快照投影无关。收进这里之后，策略可以用记录型 [PlaybackCommandPort]
/// 直接测试，不必拉起 facade / 协调者 / 设置 / messenger。
///
/// 写入只经 [PlaybackCommandPort]（`playQueueIndex` / `replaceQueueTrack`）：
/// 阶段路由与「命令返回前已提交」仍由唯一实现（会话协调者）负责，这里不持有
/// 第二个会话写入口，也不直接碰 facade。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../data/catalog/catalog_service.dart';
import '../domain/models/failure.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../services/diagnostics/failure_ring_buffer.dart';
import '../services/source_swap/source_swap_settings.dart';
import 'playback_commands.dart';

final _logger = Logger('molia.playback_error_recovery');

/// 自动换源解析器：在其它音源严格找回同一首歌（组合根注入）。
///
/// [excludeSourceKeys] 为已尝试来源（provenance，由 [PlaybackErrorRecovery]
/// 维护）。
typedef AutoSourceSwapResolver = Future<Track?> Function(
  Track track, {
  required Set<String> excludeSourceKeys,
});

/// 自动换源成功后同步曲目级本地数据（如自定义封面）。
typedef AutoSourceSwapTrackHook = Future<void> Function(
  Track oldTrack,
  Track newTrack,
);

/// 读取当前真实播放快照（重试后判定 / 换源前复查当前曲目）。
typedef PlaybackSnapshotReader = PlaybackSnapshot Function();

/// 播放失败恢复：同一曲目只同源重试一次，仍失败则跨源严格找回并静默换源。
///
/// 状态（已重试曲目、已尝试来源、并发换源集合）与播放器生命周期一致，由
/// 组合根持有的 provider 创建；这里没有订阅，也不需要释放。
class PlaybackErrorRecovery {
  PlaybackErrorRecovery({
    required this._commands,
    required this._readSnapshot,
    required this._onOutcome,
    this._catalogService,
    this._autoSwapSettings,
    this._autoSwapResolver,
    this._onAutoSourceSwapped,
    this._failures,
    this._channelDisplayName,
    this.provenanceCap = 64,
  });

  final PlaybackCommandPort _commands;
  final PlaybackSnapshotReader _readSnapshot;
  final void Function(PlaybackCommandOutcome outcome) _onOutcome;

  /// 取链缓存失效入口（播放失败时按 sourceKey 失效，下一次播放重试）。
  final CatalogService? _catalogService;

  /// 自动换源开关（设置 › 播放，默认开）；null = 关闭该能力。
  final SourceSwapSettings? _autoSwapSettings;

  /// 自动换源解析器（组合根注入 `AutoSourceSwapService.findMatch`）。
  final AutoSourceSwapResolver? _autoSwapResolver;

  /// 自动换源成功后的本地数据钩子（自定义封面跟随）。
  final AutoSourceSwapTrackHook? _onAutoSourceSwapped;

  /// 最近失败记录（类型化，不含 message / 响应正文）。
  final FailureRecorder? _failures;
  final String Function(String sourceKey)? _channelDisplayName;

  /// provenance 的条目上限：每个曲目一条已尝试来源集合，防止长期泄漏。
  final int provenanceCap;

  /// 已自动重试过的曲目 key（同一操作只重试一次，避免失败循环）。
  String? _retriedTrackKey;

  /// 每个曲目 uri 的**已尝试来源**（含种子源；换源后的候选继承并追加自身
  /// 来源），级联每个来源至多一次、有界；cap 防止长期泄漏。
  final Map<String, Set<String>> _triedSources = {};

  /// 正在自动换源的曲目 uri（防并发重复触发）。
  final Set<String> _swapping = {};

  /// 上一次已写入最近失败的曲目 + 失败身份；同一错误反复通知只记一次。
  String? _lastRecordedFailure;

  /// 处理一帧失败快照：失效失败曲目的取链缓存，自动重试一次；重试仍失败
  /// （或重试成功后再次失败）→ 尝试自动换源。
  ///
  /// 同一曲目 key 只做一次同源重试（[_retriedTrackKey] 守卫），失败不缓存，
  /// 下一次播放自然会重新取链，不会形成失败循环。自动换源的级联有界见
  /// [_tryAutoSourceSwap]。
  void onPlaybackError(PlaybackSnapshot snapshot) {
    final failure = snapshot.error;
    final track = snapshot.current;
    if (failure == null || track == null) {
      _lastRecordedFailure = null;
      return;
    }
    if (snapshot.currentIndex < 0) return;

    // 失败即失效该曲目的取链缓存（失败本身不入缓存，下次播放重新取链）。
    // 只清这一首：一条过期 URL 不应让同音源其它曲目全部重新取链。
    _catalogService?.invalidateResolveForTrack(track);
    final failureKey =
        '${track.id.uri}|${failure.kind.name}|${failure.l10nKey}|'
        '${failure.retryable}|${failure.message}';
    if (failureKey != _lastRecordedFailure) {
      _lastRecordedFailure = failureKey;
      _failures?.recordFailure(
        failure: failure,
        channelKey: track.id.sourceKey,
        channelDisplayName:
            _channelDisplayName?.call(track.id.sourceKey) ?? track.id.sourceKey,
      );
    }

    final key = track.id.uri;
    if (_retriedTrackKey != key) {
      _retriedTrackKey = key;
      final index = snapshot.currentIndex;
      unawaited(_retryOnce(track, index));
      return;
    }

    // 同源重试已发生过（重试成功后中途再失败等）：直接尝试自动换源。
    unawaited(_tryAutoSourceSwap(track, failure));
  }

  /// 切换音质后允许再次同源重试：这是一次新的取链动作，不是同一失败的重试
  /// 循环，否则换到坏档位后连一次重试机会都没有。
  void resetRetryGuard() {
    _retriedTrackKey = null;
  }

  /// 在微任务里重试：让当前快照通知先走完，避免在监听回调内同步再入命令。
  Future<void> _retryOnce(Track track, int index) =>
      Future<void>.microtask(() async {
        try {
          // 重试也是一次会话命令：阶段路由与「返回前已提交」交给协调者。
          await _commands.playQueueIndex(index);
        } catch (e) {
          _logger.severe('播放失败自动重试失败', e);
        }
        // 重试仍失败（错误快照可能值未变、不会再触发入口）→ 自动换源。
        _maybeAutoSwapAfterRetry(track);
      });

  /// 同源重试完成后的判定：错误仍在且仍是同一首 → 尝试自动换源。
  void _maybeAutoSwapAfterRetry(Track track) {
    final state = _readSnapshot();
    final failure = state.error;
    if (failure == null) return;
    if (state.current?.id.uri != track.id.uri) return;
    unawaited(_tryAutoSourceSwap(track, failure));
  }

  /// 自动换源：跨音源严格找回同一首并原地替换队列曲目（静默，对齐 LX）。
  ///
  /// 守卫：
  /// - 开关关闭 / 未注入解析器 / 本地文件 / cancelled·unsupported 失败 → 跳过；
  /// - provenance（[_triedSources]）记录已尝试来源，候选继承后追加自身来源：
  ///   级联每个来源至多一次、必然收敛；
  /// - [_swapping] 防并发重复；换源前复查当前曲目仍是失败的那首。
  Future<void> _tryAutoSourceSwap(Track track, SourceFailure failure) async {
    final settings = _autoSwapSettings;
    final resolver = _autoSwapResolver;
    if (settings == null || resolver == null || !settings.autoEnabled) return;
    if (track.origin == TrackOrigin.localFile) return;
    if (failure.kind == FailureKind.cancelled ||
        failure.kind == FailureKind.unsupported) {
      return;
    }
    final uri = track.id.uri;
    if (!_swapping.add(uri)) return;
    try {
      final tried = _triedSources[uri] ?? <String>{};
      tried.add(track.id.sourceKey);
      final match = await resolver(track, excludeSourceKeys: tried);
      if (match == null || match.id.uri == uri) return;
      // 搜索期间可能已切歌 / 被手动换源：只替换仍是这首的当前曲目。
      if (_readSnapshot().current?.id.uri != uri) return;
      _rememberProvenance(match.id.uri, {...tried, match.id.sourceKey});
      // 队列替换是会话命令：live 转发与「返回前已写进会话」由协调者负责。
      final outcome = await _commands.replaceQueueTrack(uri, match);
      if (outcome.hasChanges) {
        try {
          await _onAutoSourceSwapped?.call(track, match);
        } catch (e) {
          _logger.warning('自动换源后同步本地数据失败: $e');
        }
      }
      _onOutcome(outcome);
    } catch (e) {
      _logger.warning('自动换源失败: $e');
    } finally {
      _swapping.remove(uri);
    }
  }

  void _rememberProvenance(String uri, Set<String> tried) {
    if (_triedSources.length >= provenanceCap) {
      _triedSources.remove(_triedSources.keys.first);
    }
    _triedSources[uri] = tried;
  }
}
