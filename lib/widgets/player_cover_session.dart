/// 切歌会话（cover swap session）。
///
/// 收拢封面堆叠模块中「一次拖动 / 一次切歌」从开始到落位的全部状态与时机：
/// 阶段迁移、起止身份、方向判定提示、对账与 6 秒兜底。会话只决定「什么时候」，
/// 一切渲染与播放效果经 [CoverSwapHost] 意图接口交给封面堆叠模块执行
/// （控制器编排、post-frame 调度、播放命令都在宿主侧）。
///
/// 唯一快照入口是 [CoverSwapSession.observe]：切歌检测、空闲缓存（左槽身份 /
/// 下一首 / 方向提示）与预览目标都从它派生——调用方不再各刷一半，ghost 方向
/// 那类「缓存只在空闲帧刷新」的漂移因此没有落脚点。
///
/// 只在离散迁移时 [CoverSwapSession.notifyListeners]（build 读取阶段与身份）；
/// 拖动跟手的逐帧进度不进会话——它由宿主控制器持有并自行通知。
library;

import 'package:flutter/foundation.dart';

import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../models/play_mode.dart';
import 'cover_appearance.dart';
import 'player_cover_swap.dart';

/// 封面 URL / 稳定 key 与外观词汇定义在 `cover_appearance.dart`（会话只消费）。
export 'cover_appearance.dart' show artworkUrlOf, trackKeyOf;

/// 会话阶段。
///
/// 注意：是否「正在演出动画」仍由宿主的进度控制器判定（拖动回弹、快速连切
/// 共用同一根控制器）；本阶段只描述切歌机械所处的状态。
enum CoverSwapPhase {
  /// 无活动会话：稳态；拖动回弹动画期间也回到本阶段。
  idle,

  /// 拖动跟手中：进度由手指位移反解曲线写入，中心位显示会话目标。
  preview,

  /// 已提交：松手达标，进度续走到落位，等待后端把 current 换成目标；
  /// 期间忽略新的拖动，收到曲目变化（或兜底超时）后对账复位。
  committed,

  /// 完成中：即时切歌的入场动画（会话身份保留到落位）。
  settling,

  /// 对账校正：提交后到位曲目与预览目标不一致（随机目标 / 失败恢复 /
  /// 列表变化）时，中心封面以原位交叉淡化校正到实际曲目，随后回 idle。
  correcting,
}

/// 会话向宿主发出的效果意图。
///
/// 宿主是封面堆叠模块（唯一生产实现），测试用记录型假宿主验证调用序列——
/// 会话的时机语义因此可以脱离 widget 树断言。
abstract interface class CoverSwapHost {
  /// 进度弹簧是否仍在动画（空闲缓存刷新的门控；弹簧尾部也算）。
  bool get progressAnimating;

  /// 拖动跟手：停掉弹簧（若在播）并把进度写成手指位置。
  void previewProgress(double progress);

  /// 提交落位：从当前进度续走到 1（带手势速度），并给出提交反馈。
  void land({required double progressVelocity});

  /// 撤下预览回弹：进度退回 0（带手势速度；不可见时直接落位）。
  void releasePreview({double progressVelocity = 0});

  /// 即时切歌入场：停掉旧校正、把进度钉回起点，post-frame 起播入场。
  void startSettle();

  /// 拖动中切歌落位：动画不接管，交还手指驱动。
  void settleDuringDrag();

  /// 拖动提交对账匹配：源侧新身份补一个纯透明度淡入。
  void settleCommit();

  /// 拖动提交对账不匹配：中心封面原位交叉淡化校正到实际曲目。
  void crossfadeCorrection();

  /// 槽位身份接管：会话窗口已把左右槽位演到位，渲染侧直接对齐快照
  /// （不补身份淡换，避免以过期身份当淡出起点的幽灵淡出）。
  void adoptSteadySlots();

  /// 全部动画立即落位到稳态（不做过渡）。
  ///
  /// [adoptTrack] 非空时中心封面身份直接接管该曲目（隐藏态切歌：快照已换，
  /// 但父级还没按新曲目重建）。
  void hardReset({Track? adoptTrack});

  /// 请求后端切歌（方向 = 会话方向）。
  void requestSkip(int direction);

  /// 展示曲目切换联动回调（切换帧的 post-frame 触发）。
  void notifySwapped(bool duringDrag);

  /// 武装提交兜底计时器（超时回调 [CoverSwapSession.timeoutFired]）。
  void armTimeout(Duration duration);

  /// 取消兜底计时器。
  void disarmTimeout();
}

/// 一次切歌（拖动/即时）的会话状态机。
class CoverSwapSession extends ChangeNotifier {
  CoverSwapSession({required CoverSwapHost host}) : _host = host;

  /// 提交等待的兜底时限：取链失败等情况下不能永远停在邻位预览。
  static const Duration commitTimeout = Duration(seconds: 6);

  final CoverSwapHost _host;

  /// 最近一次摄入的播放快照（[observe] 写入；派生左槽身份与预览目标）。
  PlaybackSnapshot? _snapshot;

  CoverSwapPhase _phase = CoverSwapPhase.idle;

  /// 动画方向：1 = 向前（向左滑出），-1 = 向后。
  int _direction = 1;

  /// 滑出的旧当前封面（拖动/切歌动画期间参与渲染）。
  Track? _from;

  /// 会话目标：拖动/提交时为预览曲目；即时切歌时为进场曲目。
  ///
  /// 拖动开始时解析并固定，不能在渲染时重读 `snapshot.next`：提交后后端会
  /// 先推「新的下一首」，重读会让中心封面闪成再下一首。
  Track? _to;

  /// 方向反转时让位的旧邻位（从另一侧淡出）。
  Track? _oldNeighbor;

  /// 左槽「上一首」身份：快照解析好的 [PlaybackSnapshot.previous]
  /// （播放顺序最近一首 → 队列前一位；同 id 已排除）。
  Track? _previous;

  /// 空闲帧缓存的下一首（向后拖动时的旧邻位身份）。
  Track? _lastNext;

  /// 旧封面 URL：新封面未加载完成时作为占位，避免黑块闪一下。
  String? _placeholderUrl;

  /// 上一首非空展示曲目（滑出身份的来源；快照 current 为 null 时不更新）。
  Track? _seenTrack;

  /// 已进入动画身份的展示曲目 id（切歌检测基准）。
  String? _animatedTrackId;

  /// 手指是否仍在屏上（区分「跟手预览」与「松手后等待切歌」）。
  bool _dragActive = false;

  /// 页面可见性（TickerMode）：隐藏时切歌直接落位、不播动画。
  bool _visible = true;

  /// 提交过渡尚未落位时的对账结果：落位后再开始校正（校正必须从稳态起步，
  /// 否则旧预览卡会从半途位置跳回中心）。
  bool _correctionDeferred = false;

  /// 方向判定「变化前」的上一首提示（快照 previous = 播放顺序最近一首）。
  ///
  /// 方向纯函数消费的是变化前的提示：变化后快照的 next/previous 已经翻页，
  /// 无法代表用户实际来的方向。空闲帧与每次切歌解析后刷新。
  Track? _prevHint;

  /// 方向判定「变化前」的下一首提示（快照 next）。
  Track? _nextHint;

  /// 方向判定「变化前」当前曲目的队列下标（-1 = 未知）。
  int _hintIndex = -1;

  // ── 只读视图（build 与手势门控读取） ─────────────────────

  CoverSwapPhase get phase => _phase;
  int get direction => _direction;
  Track? get from => _from;
  Track? get to => _to;
  Track? get oldNeighbor => _oldNeighbor;
  Track? get previous => _previous;
  String? get placeholderUrl => _placeholderUrl;
  String? get animatedTrackId => _animatedTrackId;
  bool get visible => _visible;
  bool get dragActive => _dragActive;

  /// 中心位是否由会话目标驱动：拖动跟手或提交等待。
  bool get previewActive =>
      _phase == CoverSwapPhase.preview || _phase == CoverSwapPhase.committed;

  /// 是否已提交切歌、等待后端对账。
  bool get awaitingReconcile => _phase == CoverSwapPhase.committed;

  // ── 输入 ───────────────────────────────────────────────

  /// 页面可见性（TickerMode）翻转：任一方向都立即落位到稳态。
  ///
  /// 隐藏期间 ticker 被静音：会话若冻结在中间进度，回到播放页时动画会从冻结
  /// 进度重播（或跳到结尾），而顶栏⇄播放页飞行在点击那一刻抓取的封面锚点正是
  /// 这个中间布局——飞行会先落在错误位置再被动画带走。因此两个方向都立即
  /// 落位，保证锚点始终是稳态矩形。
  void setVisible(bool value) {
    if (value == _visible) return;
    _visible = value;
    _abandon();
    notifyListeners();
    _host.hardReset();
    _host.adoptSteadySlots();
  }

  /// 摄入播放快照（快照通知 / 首帧绑定 / provider 换绑的唯一入口）。
  ///
  /// 返回本次是否检测到展示曲目切换（deck 据此决定是否走空闲视觉刷新）。
  bool observe({
    required PlaybackSnapshot snapshot,
    required Track? displayTrack,
  }) {
    _snapshot = snapshot;
    // 展示身份取 current，缺失时回退父级解析的 displayTrack（冷启动恢复态）。
    final track = snapshot.current ?? displayTrack;
    final id = trackKeyOf(track);
    if (id == null || id == _animatedTrackId) {
      _refreshIdleCache();
      return false;
    }
    _swapTo(id: id, track: track!, snapshot: snapshot);
    _refreshIdleCache();
    return true;
  }

  /// 横滑开始：提交等待 / 对账校正期间不接受新手势。
  ///
  /// 一次拖动只对应一次切歌；校正期间放行会把中心从中间态跳回旧预览目标
  /// （校正被弃）。返回本次手势是否被会话接受。
  bool dragStart() {
    if (awaitingReconcile || _phase == CoverSwapPhase.correcting) return false;
    _dragActive = true;
    return true;
  }

  /// 拖动跟手：中心位换预览目标封面、按滑动距离过渡（与切歌动画同一进度）。
  ///
  /// [delta] 是手指位移（正负定方向，左滑 = 下一首），[progress] 是宿主按
  /// 布局换算好的动画进度（位移曲线不需要会话知道封面尺寸）。
  void dragUpdate({required double delta, required double progress}) {
    if (!_dragActive) return;
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final int dir = delta < 0 ? 1 : -1;
    final Track? target = _previewTargetFor(dir, snapshot);

    if (target == null) {
      // 无可切换目标：拖动起点就是边界时不进入预览（松手也不提交）；
      // 预览已激活期间同向重解析为 null（列表变化，如 next 变空）时保持
      // 会话目标、进度冻结，不撤下预览（松手后按提交/对账路径收尾）；
      // 反向拖回边界才撤下预览回弹。
      if (_phase == CoverSwapPhase.preview && dir != _direction) {
        releasePreview();
      }
      return;
    }

    bool changed = false;
    if (!previewActive) {
      _phase = CoverSwapPhase.preview;
      changed = true;
    }
    if (dir != _direction || _from == null) {
      _direction = dir;
      // 拖动预览里「滑出」的是当前封面；反向侧旧邻位让位。
      _from = _seenTrack;
      _oldNeighbor = dir == 1 ? _previous : _lastNext;
      changed = true;
    }
    if (_to?.id != target.id) {
      _to = target;
      changed = true;
    }
    if (changed) notifyListeners();
    _host.previewProgress(progress);
  }

  /// 松手：本次拖动结束；提交或回弹由调用方按手势判定续接。
  void dragEnd() {
    _dragActive = false;
  }

  /// 手势取消（系统打断 / 指针取消）：已提交的预览不因手势取消而撤下，
  /// 继续等后端对账（超时有兜底）。
  void dragCancel() {
    if (!_dragActive) return;
    _dragActive = false;
    if (!awaitingReconcile) releasePreview();
  }

  /// 松手达标：提交切歌，从当前进度续走落位并请求后端切歌。
  ///
  /// 进入「已提交等待对账」后预览保持，直到曲目真正切换（取链可能需要几百
  /// 毫秒）——否则动画跑完会先回落成旧封面、再跳成新封面，看起来像卡住。
  void commit({required double progressVelocity}) {
    if (!previewActive || _to == null) return;
    _phase = CoverSwapPhase.committed;
    notifyListeners();
    _host.land(progressVelocity: progressVelocity);
    _host.armTimeout(commitTimeout);
    _host.requestSkip(_direction);
  }

  /// 撤下拖动/提交预览并回弹到稳态（不切歌）。
  void releasePreview({double progressVelocity = 0}) {
    if (!previewActive) return;
    _phase = CoverSwapPhase.idle;
    _to = null;
    notifyListeners();
    _host.disarmTimeout();
    _host.releasePreview(progressVelocity: progressVelocity);
  }

  /// 提交兜底超时（宿主计时器回调）：撤下预览回弹。
  void timeoutFired() {
    if (!awaitingReconcile) return;
    releasePreview();
  }

  /// 进度弹簧落位（宿主在 completed 时回调）。
  void progressCompleted() {
    if (_phase == CoverSwapPhase.settling) {
      // 即时切歌：会话到此结束（视觉已由控制器最后一帧画完）。
      _phase = CoverSwapPhase.idle;
      _to = null;
      notifyListeners();
      _host.adoptSteadySlots();
      return;
    }
    if (_phase == CoverSwapPhase.committed && _correctionDeferred) {
      // 提交过渡落位：对账到别的曲目时现在才开始校正（预览卡已滑到中心，
      // 从稳态起步，无半途位移跳变）。
      final snapshot = _snapshot;
      if (snapshot != null) _startCorrection(snapshot);
      return;
    }
    if (_phase == CoverSwapPhase.idle) {
      // 拖动回弹落位：回弹期间快照可能变化，对齐槽位身份跟踪，
      // 避免下一次身份变化以过期身份为淡出起点（幽灵淡出）。
      _host.adoptSteadySlots();
    }
  }

  /// 对账校正走完（宿主在校正控制器 completed 时回调）。
  void correctionCompleted() {
    if (_phase != CoverSwapPhase.correcting) return;
    _phase = CoverSwapPhase.idle;
    _to = null;
    _from = null;
    notifyListeners();
    _host.adoptSteadySlots();
  }

  // ── 内部迁移 ───────────────────────────────────────────

  /// 检测到展示曲目切换：拖动提交走对账；隐藏态直接落位；其余播入场动画。
  void _swapTo({
    required String id,
    required Track track,
    required PlaybackSnapshot snapshot,
  }) {
    _animatedTrackId = id;
    final Track? oldTrack = _seenTrack;
    _seenTrack = track;

    if (!_visible) {
      // 页面不可见：切歌不播动画，直接落位（ticker 被 TickerMode 静音，冻结的
      // 中间进度会在回到播放页时重播、并把飞行锚点带偏）；父级联动照发。
      _abandon(adoptTrack: track);
      notifyListeners();
      _host.hardReset(adoptTrack: track);
      _host.adoptSteadySlots();
      _host.notifySwapped(false);
      return;
    }

    if (awaitingReconcile) {
      _host.disarmTimeout();
      if (_to?.id.uri == id) {
        _settleCommit(snapshot);
        return;
      }
      // 不匹配（随机目标 / 失败恢复 / 列表变化落到别的曲目）：等提交过渡
      // 落位后再校正（从稳态起步）；过渡已在尾部时立即校正。
      if (_host.progressAnimating) {
        _correctionDeferred = true;
        return;
      }
      _startCorrection(snapshot);
      return;
    }

    // 方向判定：用「变化前」缓存的提示 + 新快照信息调纯函数（规则与优先级
    // 见 player_cover_swap.dart）。据此，队列点选/跳转也能得到真实方向。
    final int resolved = resolveCoverSwapDirection(
      from: oldTrack,
      to: track,
      prevHint: _prevHint,
      nextHint: _nextHint,
      queue: snapshot.queue,
      oldIndex: _hintIndex,
      newIndex: snapshot.currentIndex,
      shuffle: snapshot.mode == PlayMode.shuffle,
    );
    // 拖动预览进行中时，阶段与预览目标归拖动会话（切歌只更新身份供拖动继续
    // 驱动）；其余情况进入即时切歌的「完成中」。
    final bool duringDrag = previewActive;
    if (!duringDrag) {
      _correctionDeferred = false;
      // 新会话先把进度钉在起点：检测帧就画在 p=0（与稳态的源槽位卡一致），
      // 而不是先画落位态、动画启动后再回跳。钉值会同步触发一次 completed，
      // 此时阶段仍未切换，[progressCompleted] 的守卫会忽略它。
      _host.startSettle();
      _phase = CoverSwapPhase.settling;
      _to = track;
    }
    _direction = resolved == coverSwapBackward ? -1 : 1;
    _oldNeighbor = resolved == coverSwapBackward ? _lastNext : _previous;
    // 新快照即下一次切歌的「变化前」基准（快速连切时动画中不会有空闲帧）。
    _cacheDirectionHints(snapshot);
    _previous = snapshot.previous;
    _from = oldTrack;
    // 旧封面作为切歌动画中未加载完成时的占位，避免黑块闪一下。
    _placeholderUrl = artworkUrlOf(oldTrack) ?? _placeholderUrl;
    _host.disarmTimeout();
    if (duringDrag) _host.settleDuringDrag();
    notifyListeners();
  }

  /// 拖动提交对账匹配：无缝落位到目标曲目。
  void _settleCommit(PlaybackSnapshot snapshot) {
    _phase = CoverSwapPhase.idle;
    _to = null;
    _previous = snapshot.previous;
    // 对账后新快照即下一次切歌的「变化前」基准。
    _cacheDirectionHints(snapshot);
    notifyListeners();
    // 槽位身份已由切歌窗口演到位：接管对齐，空闲期不补淡换。
    _host.adoptSteadySlots();
    _host.settleCommit();
  }

  /// 开始对账校正：中心封面从预览目标原位淡化到实际曲目。
  void _startCorrection(PlaybackSnapshot snapshot) {
    _correctionDeferred = false;
    _phase = CoverSwapPhase.correcting;
    _previous = snapshot.previous;
    // 对账后新快照即下一次切歌的「变化前」基准。
    _cacheDirectionHints(snapshot);
    notifyListeners();
    // 槽位身份按新快照稳态接管，空闲期不把校正前的身份当成淡出起点。
    _host.adoptSteadySlots();
    _host.crossfadeCorrection();
  }

  /// 立即落位到稳态：清掉会话窗口（拖动/提交/过渡/校正）与缓存身份。
  void _abandon({Track? adoptTrack}) {
    _dragActive = false;
    _phase = CoverSwapPhase.idle;
    _to = null;
    _from = null;
    _correctionDeferred = false;
    _host.disarmTimeout();
    if (adoptTrack != null) {
      _placeholderUrl = artworkUrlOf(adoptTrack) ?? _placeholderUrl;
    }
    final snapshot = _snapshot;
    if (snapshot != null) {
      _lastNext = snapshot.next;
      _previous = snapshot.previous;
      _cacheDirectionHints(snapshot);
    }
  }

  /// 空闲缓存刷新：下一首身份、左槽身份、滑出身份清理与方向判定提示。
  ///
  /// 方向纯函数消费「变化前」提示，必须来自最近一次稳态快照，快速连切的
  /// 方向基准才不漂移；会话窗口（拖动/提交/过渡）期间不刷新，由窗口自己
  /// 对齐。只清真正结束（idle）的会话：settling 检测帧（动画尚未在
  /// post-frame 启动）必须保留刚建立的滑出身份，否则滑出卡全程不渲染。
  void _refreshIdleCache() {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    if (_host.progressAnimating || previewActive) return;
    final Track? previous = snapshot.previous;
    final bool previousChanged = previous?.id != _previous?.id;
    _lastNext = snapshot.next;
    _previous = previous;
    if (_phase == CoverSwapPhase.idle) _from = null;
    _cacheDirectionHints(snapshot);
    if (previousChanged) notifyListeners();
  }

  /// 缓存「变化前」的方向判定提示（空闲缓存刷新与每次切歌解析后调用）。
  void _cacheDirectionHints(PlaybackSnapshot snapshot) {
    _prevHint = snapshot.previous;
    _nextHint = snapshot.next;
    _hintIndex = snapshot.currentIndex;
  }

  /// 本次拖动方向对应的预览目标；无目标（队列到头 / 无可回退曲目）返回 null。
  ///
  /// 两个方向都直接读快照解析好的身份（服务侧已保证与实际的
  /// `skipToNext` / `skipToPrevious` 同源，且上一首已排除与当前同 id）。
  Track? _previewTargetFor(int dir, PlaybackSnapshot snapshot) {
    final Track? target = dir == 1
        ? snapshot.next
        : (dir == -1 ? snapshot.previous : null);
    return target;
  }
}
