/// 切歌会话（cover swap session）。
///
/// 收拢封面堆叠模块中「一次拖动 / 一次切歌」从开始到落位的全部可变状态：
/// 起止身份、方向、旧邻位/历史身份、阶段、6 秒兜底计时器与方向判定的
/// 「变化前」提示。会话只承载状态与语义；唯一一根进度控制器与对账落位后
/// 的源侧淡入控制器仍归 `player_cover_deck.dart` 的 State 持有。
library;

import 'dart:async';

import '../domain/models/track.dart';

/// 会话阶段。
///
/// 注意：是否「正在演出动画」仍由进度控制器判定（拖动回弹、快速连切共享
/// 同一根控制器）；本阶段只描述切歌机械所处的状态。
enum CoverSwapPhase {
  /// 无活动会话：稳态；拖动回弹动画期间也回到本阶段。
  idle,

  /// 拖动跟手中：进度由手指位移反解曲线写入，中心位显示
  /// [CoverSwapSession.to]。
  preview,

  /// 已提交：松手达标，进度从当前值续走到落位，等待后端把 current 换成
  /// 目标；期间忽略新的拖动，收到曲目变化（或兜底超时）后对账复位。
  committed,

  /// 完成中：即时切歌的入场动画（会话身份保留到落位）。
  settling,

  /// 对账校正：提交后到位曲目与预览目标不一致（随机目标 / 失败恢复 /
  /// 列表变化）时，中心封面以 220ms 原位交叉淡化校正到实际曲目，
  /// 随后按新快照重建槽位并回 idle。
  correcting,
}

/// 一次切歌（拖动/即时）的会话状态。
///
/// 语义约定：
/// - [phase] 是拖动机械的唯一真相：`preview`/`committed` 时中心位由 [to]
///   驱动（跟手或提交等待），渲染不依赖散落的布尔字段；
/// - [from]/[to]/[oldNeighbor]/[direction] 只在动画期间参与渲染；空闲帧
///   在会话真正结束（[phase] 为 idle）后才把 [from] 清空——settling 检测帧
///   必须保留刚建立的滑出身份，否则滑出卡全程不渲染、结束时直接 pop。
/// - [animatedTrackId] 是切歌检测基准：快照 current 与它不同才开启新会话。
class CoverSwapSession {
  /// 上一首非空展示曲目（[from] 的来源；快照 current 为 null 时不更新）。
  Track? seenTrack;

  /// 已进入动画身份的展示曲目 id（切歌检测基准）。
  String? animatedTrackId;

  /// 滑出的旧当前封面（拖动/切歌动画期间参与渲染）。
  Track? from;

  /// 会话目标：拖动/提交时为预览曲目；即时切歌时为进场曲目。
  ///
  /// 拖动开始时解析并固定，不能在渲染时重读 `snapshot.next`：提交后后端会
  /// 先推「新的下一首」，重读会让中心封面闪成再下一首。
  Track? to;

  /// 方向反转时让位的旧邻位（从另一侧淡出）。
  Track? oldNeighbor;

  /// 播放历史最近一首（左邻位；向后入场/向后拖动的旧邻位身份）。
  Track? previous;

  /// 空闲帧缓存的下一首（向后拖动时旧邻位身份）。
  Track? lastNext;

  /// 动画方向：1 = 向前（向左滑出），-1 = 向后。
  int direction = 1;

  /// 会话阶段，见 [CoverSwapPhase]。
  CoverSwapPhase phase = CoverSwapPhase.idle;

  /// 手指是否仍在屏上（区分「跟手预览」与「松手后等待切歌」）。
  bool dragActive = false;

  /// 拖动提交的 6 秒兜底计时器（取链失败等不能永远停在邻位预览）。
  Timer? pendingTimer;

  /// 方向判定「变化前」的上一首提示（history 末位 = 播放顺序最近一首）。
  ///
  /// 方向纯函数消费的是变化前的提示：变化后快照的 next/history 已经翻页，
  /// 无法代表用户实际来的方向。空闲帧与每次切歌解析后刷新。
  Track? prevHint;

  /// 方向判定「变化前」的下一首提示（快照 next）。
  Track? nextHint;

  /// 方向判定「变化前」当前曲目的队列下标（-1 = 未知）。
  int hintIndex = -1;

  /// 旧封面 URL：新封面未加载完成时作为占位，避免黑块闪一下。
  String? placeholderUrl;

  /// 中心位是否由会话目标 [to] 驱动：拖动跟手或提交等待。
  bool get previewActive =>
      phase == CoverSwapPhase.preview || phase == CoverSwapPhase.committed;

  /// 是否已提交切歌、等待后端对账。
  bool get awaitingReconcile => phase == CoverSwapPhase.committed;
}
