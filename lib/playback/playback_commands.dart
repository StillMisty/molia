/// 播放命令面：UI（provider）与系统媒体会话共用的写入命令。
///
/// **为什么单独成接口**：系统媒体会话只该把通知 / 耳机键 / 锁屏动作翻译成
/// 命令，不该知道恢复态与 live 的分叉、也不该自己判断「什么时候落盘」。
/// 这些规则只属于 [PlaybackCommandPort] 的唯一实现
/// `PlaybackSessionCoordinator`；handler 只依赖本接口，测试可以注入记录型
/// 实现而不用拉起整条播放链路。
library;

import '../models/play_mode.dart';

/// 命令由哪个阶段处理（调用方据此决定 UI 通知口径）。
///
/// provider 不再自己分叉恢复 / 真实，而是读这个结果——恢复态两处状态都要刷新
/// （曲目与队列都可能变），live 只有曲目 / 播放态变化，空操作不必通知。
enum PlaybackCommandRoute {
  /// 空操作（无会话 / 越界 / 未命中）：没有状态变化。
  none,

  /// 恢复态处理：命令作用于保存的会话，或借此完成恢复装载（交接到 live）。
  restored,

  /// live：命令转发给真实播放。
  live,
}

/// 播放写入口：所有会改变播放状态的命令都从这里进。
///
/// 读路径不在这里：系统媒体会话仍直接读 `LocalPlaybackService` 的当前曲目 /
/// 播放态 / 进度 / 模式，UI 仍读 `PlaybackFacade` 快照。
abstract interface class PlaybackCommandPort {
  /// 播放（恢复态 = 重新取链并跳回保存进度；live = 已暂停时才起播）。
  Future<PlaybackCommandRoute> play();

  /// 暂停（恢复态没有真实播放，空操作）。
  Future<PlaybackCommandRoute> pause();

  /// 播放 / 暂停切换（UI 按钮语义）。
  Future<PlaybackCommandRoute> togglePlayPause();

  /// 下一首（恢复态从下一下标立即恢复播放，越界空操作）。
  Future<PlaybackCommandRoute> skipToNext();

  /// 上一首（恢复态从上一下标立即恢复播放，越界空操作）。
  Future<PlaybackCommandRoute> skipToPrevious();

  /// 播放队列中的指定下标（系统媒体队列跳转）。
  Future<PlaybackCommandRoute> playQueueIndex(int index);

  /// 跳转进度（恢复态只改保存进度并落盘；live 转发并强制落盘）。
  Future<void> seekToPosition(Duration position);

  /// 设置播放模式（恢复态同步改写保存的会话）。
  Future<void> setPlayMode(PlayMode mode);

  /// 循环到下一个播放模式（通知 / 锁屏的播放顺序动作）。
  Future<void> togglePlayMode();

  /// 停止播放但保留可恢复的会话（系统媒体停止键；与 UI 的
  /// `stopPlayback` 不同——后者是「本次会话结束」并清空持久化）。
  Future<void> stop();
}
