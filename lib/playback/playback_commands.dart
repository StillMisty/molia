/// 播放命令面：UI（provider）与系统媒体会话共用的写入命令。
///
/// **为什么单独成接口**：系统媒体会话只该把通知 / 耳机键 / 锁屏动作翻译成
/// 命令，不该知道恢复态与 live 的分叉、也不该自己判断「什么时候落盘」。
/// 这些规则只属于 [PlaybackCommandPort] 的唯一实现
/// `PlaybackSessionCoordinator`；handler 只依赖本接口，测试可以注入记录型
/// 实现而不用拉起整条播放链路。
library;

import '../domain/models/track.dart';
import '../models/play_mode.dart';

/// 命令真正改变的 UI 领域。
///
/// provider 只按变化域决定通知 / 失效，不再把「命令在哪个阶段处理」翻译成
/// 通知类别——阶段是协调者的内部事实，调用方只关心结果。
enum PlaybackDomain {
  /// 曲目面：当前曲目 / 播放态 / 模式 / 进度（UI 的快照 + position 通道）。
  track,

  /// 队列面：队列内容 / 下标（恢复态接管时与曲目面一起变化）。
  queue,
}

/// 换源的作用范围：同一个实现按范围决定是否跟随恢复态会话。
///
/// 自动换源由真实播放失败触发，只该改 live 队列；库内 / 手动换源是用户对
/// 「这首歌」的决定，恢复态下也要同步改写保存的会话，否则冷启动恢复的是旧来源。
enum PlaybackReplaceScope {
  /// 只改真实播放队列（恢复态 / 无曲目 = 空操作）。
  liveOnly,

  /// 真实播放队列与恢复态保存会话都改（各自命中才处理）。
  liveAndRestored,
}

/// 一条播放命令的落地结果。
///
/// [changed] 只包含**真正发生变化**的领域：空操作（越界 / 未命中 / 无会话）
/// 返回 [none]。provider 据此按类别通知（track 16ms / queue 300ms 节流），
/// 不需要再理解恢复态与 live 的差别。
class PlaybackCommandOutcome {
  const PlaybackCommandOutcome({
    this.changed = const <PlaybackDomain>{},
    this.committed = true,
  });

  /// 空操作：没有状态变化，也没有需要落盘的内容。
  static const PlaybackCommandOutcome none = PlaybackCommandOutcome();

  /// 只有曲目面变化（播放 / 暂停 / 切歌 / 进度 / 模式）。
  static const PlaybackCommandOutcome trackOnly =
      PlaybackCommandOutcome(changed: {PlaybackDomain.track});

  /// 曲目面与队列面都变化（恢复态接管 / 换源）。
  static const PlaybackCommandOutcome trackAndQueue = PlaybackCommandOutcome(
    changed: {PlaybackDomain.track, PlaybackDomain.queue},
  );

  /// 变化的 UI 领域；空集表示空操作。
  final Set<PlaybackDomain> changed;

  /// 命令返回时会话是否已经提交到本地存储。
  ///
  /// 协调者的命令都 await 写队列排空（ADR-0010：系统 / UI 命令返回前已提交），
  /// 因此生产路径恒为 true。实现若让命令先返回、写仍在途，应返回 false，
  /// 调用方需要自行等 `pendingWrite`——这是「返回早于提交」的唯一表达方式。
  final bool committed;

  bool get hasChanges => changed.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is PlaybackCommandOutcome &&
      other.committed == committed &&
      other.changed.length == changed.length &&
      other.changed.containsAll(changed);

  @override
  int get hashCode => Object.hash(committed, Object.hashAllUnordered(changed));

  @override
  String toString() =>
      'PlaybackCommandOutcome(changed: $changed, committed: $committed)';
}

/// 播放写入口：所有会改变播放状态的命令都从这里进。
///
/// 读路径不在这里：系统媒体会话读 `MediaSessionReadModel`，UI 仍读
/// `PlaybackFacade` 快照。每条命令返回 [PlaybackCommandOutcome]：调用方按
/// 变化领域刷新 UI，按 [PlaybackCommandOutcome.committed] 判断返回时机。
abstract interface class PlaybackCommandPort {
  /// 播放（恢复态 = 重新取链并跳回保存进度；live = 已暂停时才起播）。
  Future<PlaybackCommandOutcome> play();

  /// 暂停（恢复态没有真实播放，空操作）。
  Future<PlaybackCommandOutcome> pause();

  /// 播放 / 暂停切换（UI 按钮语义）。
  Future<PlaybackCommandOutcome> togglePlayPause();

  /// 下一首（恢复态从下一下标立即恢复播放，越界空操作）。
  Future<PlaybackCommandOutcome> skipToNext();

  /// 上一首（恢复态从上一下标立即恢复播放，越界空操作）。
  Future<PlaybackCommandOutcome> skipToPrevious();

  /// 播放队列中的指定下标（系统媒体队列跳转）。
  Future<PlaybackCommandOutcome> playQueueIndex(int index);

  /// 把队列中 [trackUri] 的曲目原地替换为 [newTrack]（自动换源写回）。
  ///
  /// 只有 live 处理（[PlaybackReplaceScope.liveOnly]）：自动换源由真实播放
  /// 失败触发，恢复态没有真实队列可换。恢复态 / 无曲目 / 未命中都返回
  /// [PlaybackCommandOutcome.none]；live 返回前保证换源结果已写进会话
  /// （重开应用恢复的是新来源，而不是过期直链）。
  Future<PlaybackCommandOutcome> replaceQueueTrack(
    String trackUri,
    Track newTrack,
  );

  /// 跳转进度（恢复态只改保存进度并落盘；live 转发并强制落盘）。
  Future<PlaybackCommandOutcome> seekToPosition(Duration position);

  /// 设置播放模式（恢复态同步改写保存的会话）。
  Future<PlaybackCommandOutcome> setPlayMode(PlayMode mode);

  /// 循环到下一个播放模式（通知 / 锁屏的播放顺序动作）。
  Future<PlaybackCommandOutcome> togglePlayMode();

  /// 停止播放但保留可恢复的会话（系统媒体停止键；与 UI 的
  /// `stopPlayback` 不同——后者是「本次会话结束」并清空持久化）。
  Future<PlaybackCommandOutcome> stop();
}
