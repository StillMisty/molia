/// 播放模式（列表循环 / 顺序播放 / 单曲循环 / 随机播放）。
///
/// 枚举顺序即播放模式按钮与系统媒体动作的切换顺序；持久化按 [name]，
/// 与枚举下标无关。
enum PlayMode {
  /// 列表循环：按队列顺序播完最后一首后回到第一首继续。
  listLoop,

  /// 顺序播放：按队列顺序播完最后一首后停止。
  sequential,

  /// 单曲循环。
  singleRepeat,

  /// 随机播放：每轮洗牌，轮末重洗。
  shuffle;

  /// 循环切换到的下一个模式（App 内与系统媒体会话共用）。
  PlayMode get next => switch (this) {
        PlayMode.listLoop => PlayMode.sequential,
        PlayMode.sequential => PlayMode.singleRepeat,
        PlayMode.singleRepeat => PlayMode.shuffle,
        PlayMode.shuffle => PlayMode.listLoop,
      };
}
