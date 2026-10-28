/// 播放页封面堆叠模块（cover deck）。
///
/// 收拢完整播放器封面区的三封面堆叠渲染、横滑切歌的全部手势与动画效果；
/// 「一次切歌从开始到落位」的时机与状态归 [CoverSwapSession]——本模块同时
/// 是它的效果宿主（实现 [CoverSwapHost] 意图接口：控制器编排、post-frame
/// 调度与播放命令都在这里）。播放器（`player.dart`）只负责布局尺寸、
/// 顶栏/迷你共享飞行锚点与主题取色联动。
///
/// 槽位（slot）：左 = 上一首、中 = 当前（拖动/提交/回退时为预览目标）、
/// 右 = 下一首；切歌（swap）动画与拖动跟手共用模块内部同一条进度控制器；
/// 拖动/提交/对账/兜底等全部会话时机收敛在唯一一个 [CoverSwapSession] 中。
///
/// 切歌视觉：
/// - motor expressive spatial 弹簧（380/0.8）驱动进度 0→1；拖动跟手直接写
///   进度（画面=手指位移），松手按速度续跑吸附；
/// - 目标槽位旧身份与源槽位新身份按进度窗口交叉淡化（仅透明度、原位不动）；
///   拖动预览时源槽位提前显示目标之后的身份（前进 = upNext 的再下一首，
///   后退 = previousOfPrevious），三槽窗口随拖动连续滑动，不在落位后补图；
/// - 两张移动卡（旧中封 → 目标槽位、新中封 ← 源槽位）全程插值，透明度
///   1.0 ↔ 0.85 连续过渡（进场卡从 85% 起步，消除起手闪跳）；
/// - 松手未达标/取消/超时反向回退：预览目标身份保持到弹簧落位，回弹是
///   拖动预览的严格反向（否则目标槽位会闪成当前封面）；回拖/回弹期间
///   正在回位的当前封面压在上层，避免目标封面盖住当前封面。
///
/// 对账与会话外槽位更新：
/// - 提交对账到非预览曲目：进入 `correcting`，中心封面以 220ms 原位交叉淡化
///   校正（旧预览卡淡出、实际曲目卡淡入，无位移），随后按新快照重建槽位；
///   提交过渡尚未落位时先让它走完再校正（从稳态起步，避免半途起跳）；
/// - 提交对账匹配：预览已渲染的源侧身份与快照实际身份一致时连续接管，
///   不再重放 180ms 淡入；身份不一致 / 不可预测时才走兜底淡入；
/// - 空闲期槽位身份变化（加歌/删歌/开关随机/next 变空）：180ms 原位交叉
///   淡化（旧淡出、新淡入，变空则淡出为空），会话激活期间由会话窗口负责；
/// - 中心封面同 id、封面 URL 更新（音源补图）：250ms 交叉淡化换图；
/// - 左槽「上一首」= 快照 previous（播放顺序最近一首）→ 队列前一位 → 空
///   （排除与当前同 id），与后端 `skipToPrevious` 及拖动预览同源。
///
/// 切歌检测与空闲缓存由播放快照监听驱动：deck 把快照喂给
/// [CoverSwapSession.observe]（会话是身份/提示的唯一写入者），渲染侧只补
/// 空闲视觉（中心换图 / 槽位身份淡换），build 期间零写入。
///
/// 对外公开的最小面：
/// - [PlayerCoverDeck]：组件（槽位渲染 + 手势宿主 + 会话的效果宿主）；
/// - [trackKeyOf]（会话一侧定义、这里再导出）/
///   [buildDefaultArtwork] / [buildFallbackArtwork]：稳定身份与占位工具，
///   迷你条 / 飞行副本共用。封面「用哪一张」走
///   `services/covers/cover_resolution.dart`。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../providers/playback_provider.dart';
import '../services/covers/cover_resolution.dart';
import '../services/haptics.dart';
import '../theme/motion_policy.dart';
import '../utils/playback_cover_decode.dart';
import 'app_network_image.dart';
import 'cover_appearance.dart';
import 'cover_fallback.dart';
import 'player_cover_session.dart';
import 'player_morph.dart';
import 'track_artwork.dart';

/// 曲目封面 URL / 稳定 key 与卡片外观定义在
/// `cover_appearance.dart`（会话与渲染共用同一份归一化），这里再导出给
/// 迷你条 / 飞行副本 / 应用壳。占位构建器在 `cover_fallback.dart`（同一份
/// 实现，避免与 `now_playing_summary.dart` 形成循环 import）。
export 'cover_appearance.dart' show trackKeyOf;
export 'cover_fallback.dart' show buildDefaultArtwork, buildFallbackArtwork;

/// 完整播放器封面堆叠：三封面（槽位）渲染 + 横滑切歌手势 + 切歌会话状态。
///
/// 播放器只提供布局尺寸（[artDimension]/[stackDimension]/[stackHeight]）、
/// 共享飞行锚点（[morph]/[fullCoverKey]/[coverFlightActive]）与切歌联动回调
/// （[onTrackSwapped]）；封面 URL、占位、拖动、切歌、对账都归本模块。
class PlayerCoverDeck extends StatefulWidget {
  /// 封面区横向手势宿主 key：拖动期间 element 必须稳定（识别器不被
  /// dispose），同时供测试精确定位这一层手势。
  static const Key swipeHostKey = ValueKey('artworkSwipeHost');

  /// 中心槽位（进场）封面的语义 key：切歌中间帧从哪一侧入场是可观察行为，
  /// 对外用这个锚点定位中心封面（也供共享飞行之外的调试/断言使用）。
  static const Key centerCoverCardKey = ValueKey('coverSlotCenter');

  /// 滑出（旧中心）封面的语义 key：滑出卡是否参与切歌动画是可观察行为，
  /// 对外用这个锚点断言。对账校正期间它也是淡出中的旧预览卡。
  static const Key outgoingCoverCardKey = ValueKey('coverSlotOutgoing');

  /// 中心封面换图（同 id、URL 更新）时旧图卡片的语义 key：换图淡化是否
  /// 以「旧图淡出 + 新图淡入」表达，对外用这个锚点断言。
  static const Key outgoingArtworkCardKey = ValueKey('coverArtworkOutgoing');

  /// 左右槽位卡按身份（track id）的语义 key：空闲期身份交叉淡化时同一槽位
  /// 会并存新旧两张卡（旧淡出、新淡入），测试需要按身份分别定位并采样
  /// 透明度（不读私有字段）。
  static Key sideCoverCardKey({required bool left, required TrackId id}) =>
      ValueKey('coverSlot${left ? 'Left' : 'Right'}:${id.uri}');

  /// 中心封面按身份（track id）的语义 key：稳态中心、拖动/提交/回退的
  /// 预览目标与对账校正后的实际曲目都可观察（不读私有字段）。
  static Key centerCoverTrackKey(TrackId id) =>
      ValueKey('coverSlotCenter:${id.uri}');

  /// 封面堆叠容器（三封面的布局盒）的语义 key：堆叠尺寸是否落在播放器列 /
  /// 分栏内是可观察行为，对外用这个锚点断言。
  static const Key stackKey = ValueKey('coverDeckStack');

  const PlayerCoverDeck({
    super.key,
    required this.displayTrack,
    required this.artDimension,
    required this.stackDimension,
    required this.stackHeight,
    required this.fullCoverKey,
    this.isLargeScreen = false,
    this.morph,
    this.coverFlightActive = false,
    this.onTrackSwapped,
  });

  /// 展示曲目（播放器已按 `current ?? 最近播放` 回退解析）。
  final Track? displayTrack;

  /// 当前布局的封面边长（拖动跟手换算行程时需要）。
  final double artDimension;

  /// 堆叠容器尺寸（播放器按可用空间计算，本模块只负责渲染）。
  final double stackDimension;
  final double stackHeight;

  /// 主封面锚点：迷你 ⇄ 完整飞行抓取落点矩形用（播放器持有该 key）。
  final GlobalKey fullCoverKey;

  /// 大屏布局：拖动提交阈值（距离/速度）按屏型取不同值。
  final bool isLargeScreen;

  /// 顶栏共享飞行控制器：提供播放页封面锚点并同步隐藏状态。
  final PlayerMorphController? morph;

  /// 迷你 ⇄ 完整封面飞行进行中：主封面真身隐藏、新手势被忽略。
  final bool coverFlightActive;

  /// 展示曲目切换联动（切换帧的 post-frame 触发）：播放器借此清除进度
  /// 拖动残留并启动标题入场。[duringDrag] = 切换发生在拖动进行中，此时
  /// 跳过标题入场，让位给拖动预览。
  final void Function(bool duringDrag)? onTrackSwapped;

  @override
  State<PlayerCoverDeck> createState() => _PlayerCoverDeckState();
}

class _PlayerCoverDeckState extends State<PlayerCoverDeck>
    with TickerProviderStateMixin
    implements CoverSwapHost {
  /// 邻位稳态透明度；窗口淡出/淡入的端点值（p=0 / p=1 与稳态卡一致）。
  static const double _neighborOpacity = 0.85;

  /// 目标槽位旧身份淡出窗口终点：p ∈ [0, 0.4] 内 0.85 → 0（窗口内 easeOut）。
  static const double _oldNeighborFadeEnd = 0.4;

  /// 源槽位新身份淡入窗口起点：p ∈ [0.6, 1] 内 0 → 0.85（窗口内 easeInOut）。
  static const double _newNeighborFadeStart = 0.6;

  /// 拖动对账落位后源侧新身份的纯透明度淡入时长。
  static const Duration _reconcileFadeDuration = Duration(milliseconds: 180);

  /// 对账校正时长：到位曲目与预览目标不一致时，中心封面原位交叉淡化校正。
  static const Duration _reconcileCorrectionDuration = Duration(
    milliseconds: 220,
  );

  /// 空闲期槽位身份交叉淡化时长（原位、纯透明度）。
  static const Duration _slotIdentityFadeDuration = Duration(milliseconds: 180);

  /// 中心封面同 id 换图（音源补图）交叉淡化时长。
  static const Duration _artworkRefreshFadeDuration = Duration(
    milliseconds: 250,
  );

  /// 封面按压反馈：按下缩放比例；进/出走 M3E 按压弹簧（见控制器注释）。
  static const double _pressScale = 0.96;

  /// 移动卡在 Stack 中的稳定 key：回拖时绘制顺序翻转，靠它保持卡片
  /// element（图片 / 动画状态）不被按位置重建。
  static const Key _centerLayerKey = ValueKey('coverLayerCenter');
  static const Key _outgoingLayerKey = ValueKey('coverLayerOutgoing');
  static const Key _outgoingArtworkLayerKey = ValueKey(
    'coverLayerOutgoingArtwork',
  );

  /// 拖动方向反转的判定阈值（进度域）：超过它才把手势视为回拖。
  ///
  /// 只做「当前封面置顶」的层级切换，不改身份；阈值用来吃掉手指抖动，
  /// 同时按累计位移判定，慢速回拖也能在约 1% 行程内切过来。
  static const double _reverseHandoffProgress = 0.01;

  /// 连切接管的进度上限。
  ///
  /// 弹簧接近落位时中心卡已贴住中心，继续沿用 q 插值会让滑出卡在极短
  /// 剩余行程里扫过整侧槽（超高速滑行）；此时改成「上一段落位、新一段
  /// 从起点重播」的兜底。
  static const double _takeoverMaxProgress = 0.75;

  /// 接管后上一段滑出卡的离场窗口（占剩余行程的比例）。
  ///
  /// 它已经不在新会话的邻位窗口里，必须在接管开头快速淡出，否则会与
  /// 新 oldNeighbor 身份在同一槽位叠影。
  static const double _takeoverTailFadeSpan = 0.45;

  double? _dragStartX;
  double? _dragStartY;
  bool _isHorizontalDragConfirmed = false;
  double _dragDx = 0;

  /// 本次拖动最近一次方向切换时的进度锚点（回拖层级判定用）。
  double _previewTrendAnchor = 0;

  /// 拖动回拖/松手回弹时，正在回位的当前封面是否压在上层。
  ///
  /// 正向拖动与落位时目标封面在上；回拖时如果仍让中心预览目标压着当前
  /// 封面，视觉上就像下一首盖住了正在回来的当前封面。
  bool _outgoingCoverOnTop = false;

  /// 连切接管快照（弹簧途中再次切歌）。
  ///
  /// 上一段的中位卡此刻停在侧槽入场公式的中途；新会话必须以它当前视觉
  /// 为起点继续滑向目标槽，而不是按新会话的 `-offset*p` 重新绘制（那会
  /// 瞬间跳约一个侧槽宽）。
  _CoverHandoff? _handoff;

  /// 接管后被替换下来的更早滑出卡：各自从捕获位置继续向左离场并快速
  /// 淡出，避免「上一首残影」。只保留最近两层，够覆盖连续快滑。
  final List<_CoverHandoffTail> _handoffTails = <_CoverHandoffTail>[];

  /// 播放页侧邻位展开进度（壳层飞行驱动；deck 镜像一份供 Stack 子树重建）。
  late final ValueNotifier<double> _pageDeckReveal;

  /// 切歌会话状态机：拖动预览、提交等待、对账、兜底与方向提示的唯一持有者。
  ///
  /// 本 State 同时实现 [CoverSwapHost]：会话决定时机，这里编排控制器、
  /// post-frame 与播放命令（见各 @override 实现）。
  late final CoverSwapSession _session;

  /// 提交兜底计时器（会话经 [armTimeout] 武装、[disarmTimeout] 取消）。
  Timer? _pendingTimer;

  /// 已订阅的播放 Provider（运行时可能被替换，见 [_bindPlaybackIfNeeded]）。
  PlaybackProvider? _playback;

  /// 已订阅的封面解析器（换封面时中心 / 邻位立即换图）。
  CoverResolver? _covers;
  void Function()? _removeCoverListener;

  /// 当前解析器（挂载时从 Provider / 全局单例解析一次，随后由订阅换绑）。
  CoverResolver get _coverResolver => _covers!;

  /// 真实封面 URL（自定义 / 原始；默认封面只做展示兜底）。
  String? _realCoverUrlOf(Track? track) => _coverResolver.realOf(track).url;

  /// 页中心封面是否隐藏：顶栏⇄播放页飞行或迷你⇄完整飞行期间，真身由
  /// 飞行副本承接。直接乘进中心层的同一条 Opacity（不嵌套第二层，否则
  /// 「最近透明度」观测会失真，也会多一次合成）。
  bool get _pageCoverHidden =>
      (widget.morph?.pageHeaderHidden ?? false) || widget.coverFlightActive;

  /// 快照通知已排入微任务（同一批通知只对账一次）。
  bool _trackSyncScheduled = false;

  /// 唯一一根进度控制器：拖动跟手与切歌动画共用（不允许第二条视觉进度）。
  ///
  /// motor expressive spatial 弹簧（380/0.8）：拖动直接写进度（画面 = 手指
  /// 位移），松手由弹簧带速度续跑；透明度窗口从进度派生并截断 0..1
  /// （M3E 规范：effects 不过冲）。
  late SingleMotionController _coverController;

  /// 拖动对账落位后源侧新身份的纯透明度淡入；只在 idle 稳态渲染里作用于
  /// 会话方向的源侧槽位。
  ///
  /// 预览窗口已经渲染同一身份时从当前透明度接管（p=1 直接满值），只有身份
  /// 不一致 / 不可预测时才从 0 重放 180ms。
  late AnimationController _sourceNeighborFade;

  /// 对账校正控制器：0→1 期间中心旧预览卡淡出、实际曲目卡淡入（原位无位移）。
  late AnimationController _reconcileCorrection;

  /// 空闲槽位身份交叉淡化控制器：1 = 稳态；身份变化时 0 → 1。
  late AnimationController _slotIdentityFade;

  /// 中心封面换图控制器：1 = 稳态；同 id、URL 更新时 0 → 1。
  late AnimationController _artworkRefreshFade;

  /// 封面堆叠重绘源：切歌过渡 + 对账后的源侧淡入 + 校正/槽位淡换/换图。
  late final Listenable _coverStackAnimation;

  /// 中心封面当前身份与 URL（同 id 换图时 URL 是淡出起点；起点可以为空，
  /// 即「音源补图」：从无封面淡入到有封面）。
  String? _centerTrackId;
  String? _centerArtworkUrl;

  /// 中心封面是否正在换图（淡出起点 [_outgoingCenterArtworkUrl] 可以为空，
  /// 所以淡出卡是否渲染不能用「旧 URL 非空」判断）。
  bool _centerArtworkRefreshing = false;

  /// 中心封面淡出中的旧 URL（换图起点；无封面时为 null）。
  String? _outgoingCenterArtworkUrl;

  /// 空闲槽位身份跟踪：最近一次稳态渲染的身份（下一次变化的淡出起点）
  /// 与正在淡出的旧身份。
  Track? _leftSlotShown;
  Track? _rightSlotShown;
  Track? _leftSlotOutgoing;
  Track? _rightSlotOutgoing;

  /// 播放态中心封面轻微缩放（暂停时保持清晰，不做变暗）。
  /// motor expressive spatial 弹簧，暂停/播放来回切换带速度续跑。
  late SingleMotionController _playStateController;
  late Animation<double> _playStateScaleAnimation;

  /// 按压反馈控制器：0 = 未按、1 = 按到底（缩放 [_pressScale]）。
  ///
  /// M3E 按压弹簧（`M3EMotion.expressiveSpatialPress` 380/0.55）：按下即时、
  /// 抬起带轻微回弹。
  late SingleMotionController _pressController;

  /// 当前被按压的槽位；抬起回弹结束（[AnimationStatus.dismissed]）后清空。
  _DeckSlot? _pressedSlot;

  /// 中心封面缩放重绘源：播放态缩放 × 按压反馈。
  late final Listenable _centerScaleAnimation;

  @override
  void initState() {
    super.initState();
    _covers = coverResolverOf(context);
    _session = CoverSwapSession(host: this);
    _playStateController = SingleMotionController(
      motion: const MaterialSpringMotion.expressiveSpatialDefault(
        snapToEnd: true,
      ),
      vsync: this,
      initialValue: 0,
    );
    _playStateScaleAnimation = Tween<double>(
      begin: 0.98,
      end: 1.0,
    ).animate(_playStateController);

    _coverController = SingleMotionController(
      motion: const MaterialSpringMotion.expressiveSpatialDefault(
        snapToEnd: true,
      ),
      vsync: this,
      initialValue: 0,
    )..value = 1.0;

    _sourceNeighborFade = AnimationController(
      duration: _reconcileFadeDuration,
      vsync: this,
      value: 1.0,
    );
    _reconcileCorrection = AnimationController(
      duration: _reconcileCorrectionDuration,
      vsync: this,
      value: 1.0,
    );
    _slotIdentityFade = AnimationController(
      duration: _slotIdentityFadeDuration,
      vsync: this,
      value: 1.0,
    );
    _artworkRefreshFade = AnimationController(
      duration: _artworkRefreshFadeDuration,
      vsync: this,
      value: 1.0,
    );
    _pressController = SingleMotionController(
      motion: SpringMotion(
        M3EMotion.expressiveSpatialPress.toDescription(),
        snapToEnd: true,
      ),
      vsync: this,
      initialValue: 0,
    );
    _centerScaleAnimation = Listenable.merge([
      _playStateController,
      _pressController,
    ]);
    // 中心换图的淡出起点必须是「挂载时正在展示的 URL」：首个快照若只补了
    // 封面 URL（同 id），didUpdateWidget 才能识别为换图而不是首帧接管。
    _centerTrackId = trackKeyOf(widget.displayTrack);
    _centerArtworkUrl = _realCoverUrlOf(widget.displayTrack);
    // 邻位展开值镜像到本地 notifier：morph 的值监听只重建本 Stack 子树，
    // 不触发整个 deck（手势宿主 / 播放器列）逐帧 setState。
    _pageDeckReveal = ValueNotifier<double>(
      widget.morph?.pageDeckReveal.value ?? 1,
    );
    _coverStackAnimation = Listenable.merge([
      _session,
      _coverController,
      _sourceNeighborFade,
      _reconcileCorrection,
      _slotIdentityFade,
      _artworkRefreshFade,
      _pressController,
      _pageDeckReveal,
    ]);
    // 即时切歌落位即会话结束（完成中 → 空闲）；拖动提交由对账路径收尾。
    _coverController.addStatusListener(_handleCoverStatus);
    _reconcileCorrection.addStatusListener(_handleCorrectionStatus);
    _slotIdentityFade.addStatusListener(_handleSlotIdentityStatus);
    _artworkRefreshFade.addStatusListener(_handleArtworkRefreshStatus);
    _pressController.addStatusListener(_handlePressStatus);
    // 顶栏⇄播放页飞行期间中心封面隐藏，必须监听 morph 控制器重建真身。
    widget.morph?.addListener(_onMorphChanged);
    widget.morph?.pageDeckReveal.addListener(_onPageDeckRevealChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 快照监听：切歌检测完全由通知驱动（build 期间不判定切歌）。
    _bindPlaybackIfNeeded();
    // 自定义封面索引变化：同 id 换图走既有 250ms 中心淡化。
    _bindCoversIfNeeded();
    // 页面可见性（tab 切换）：任一方向翻转都立即落位。
    _syncTickerMode();
  }

  @override
  void didUpdateWidget(covariant PlayerCoverDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.morph != widget.morph) {
      oldWidget.morph?.removeListener(_onMorphChanged);
      widget.morph?.addListener(_onMorphChanged);
      oldWidget.morph?.pageDeckReveal.removeListener(_onPageDeckRevealChanged);
      widget.morph?.pageDeckReveal.addListener(_onPageDeckRevealChanged);
      _pageDeckReveal.value = widget.morph?.pageDeckReveal.value ?? 1;
    }
    // provider 可能被替换：父级重建时重新检查订阅（此时 widget.displayTrack
    // 已来自新快照）。
    _bindPlaybackIfNeeded();
    // 中心封面同 id、URL 更新（音源补图）：250ms 交叉淡化换图，不播切歌动画。
    _syncCenterArtwork(widget.displayTrack);
  }

  /// 订阅（或换绑）播放 Provider，并在换绑后同步一次会话身份。
  ///
  /// `context.read` 不建立依赖：本模块不因每次通知整树重建，只在检测到曲目
  /// 变化时 setState。provider 被替换时必须重新订阅，否则会话会停留在旧
  /// provider 的曲目上。
  void _bindPlaybackIfNeeded() {
    final playback = context.read<PlaybackProvider>();
    if (identical(playback, _playback)) return;
    _playback?.removeListener(_handlePlaybackChanged);
    _playback = playback;
    playback.addListener(_handlePlaybackChanged);
    // 首帧（或换 provider）：以 deck 实际展示的曲目建立/校正会话身份，
    // 并同步一次播放态缩放初始值。挂载时快照已有当前曲目（冷启动恢复 /
    // 系统媒体恢复）按稳态接管，不把「本来就在展示的曲目」当成切歌入场。
    final snapshot = playback.snapshot;
    _session.adoptInitial(snapshot);
    _session.observe(snapshot: snapshot, displayTrack: widget.displayTrack);
    // 渲染起点就是当前身份：槽位跟踪对齐，不补身份淡换。
    adoptSteadySlots();
    _syncPlayState(playback);
  }

  /// 订阅封面解析器：当前曲目换图 / 恢复原图后立即刷新中心与邻位。
  void _bindCoversIfNeeded() {
    final covers = coverResolverOf(context);
    if (identical(covers, _covers)) return;
    _removeCoverListener?.call();
    _covers = covers;
    _removeCoverListener = covers.addChangeListener(_onCustomCoverChanged);
  }

  void _onCustomCoverChanged() {
    if (!mounted) return;
    // 先走同 id 换图的淡化路径（transition 与中心身份都由它维护），再
    // setState 让邻位槽也按新索引重算（自定义封面可作用于上一首 / 下一首）。
    _syncCenterArtwork(widget.displayTrack);
    setState(() {});
  }

  /// 播放态中心封面缩放同步：播放 → 1.0、暂停 → 0.98。
  ///
  /// 由快照通知驱动（build 期间零写入），AnimatedBuilder 监听控制器重建。
  void _syncPlayState(PlaybackProvider playback) {
    if (!_session.visible) {
      // 不可见：直接落位（ticker 被静音，启动动画会冻结、回来再播）。
      _playStateController.value = playback.isPlaying ? 1.0 : 0.0;
      return;
    }
    _playStateController.animateTo(playback.isPlaying ? 1.0 : 0.0);
  }

  /// 页面可见性变化（TickerMode）→ 会话。
  ///
  /// 任一方向翻转都立即落位到稳态（理由见 [CoverSwapSession.setVisible]：
  /// 顶栏⇄播放页飞行抓到的锚点必须始终是稳态矩形）。
  void _syncTickerMode() {
    _session.setVisible(TickerMode.valuesOf(context).enabled);
  }

  // ── CoverSwapHost：会话的效果宿主 ────────────────────────
  //
  // 会话决定「什么时候」，这里决定「怎么做」：控制器编排、post-frame 调度、
  // 播放命令与父级联动都在这一侧；排序不变量（例如「settling 前先把进度钉回
  // 起点」）由会话的调用顺序 + 本侧实现共同持有。

  @override
  bool get progressAnimating => _coverController.isAnimating;

  @override
  void previewProgress(double progress) {
    // 手指接管进度：弹停在播的弹簧后直接写值（画面 = 手指位移）。
    if (_coverController.isAnimating) _coverController.stop(canceled: true);
    // 回拖层级：按「自上次切向以来的累计位移」判定，慢速回拖也能生效，
    // 同时避免单帧抖动来回换层。
    final double trend = progress - _previewTrendAnchor;
    if (trend > _reverseHandoffProgress) {
      _outgoingCoverOnTop = false;
      _previewTrendAnchor = progress;
    } else if (trend < -_reverseHandoffProgress) {
      _outgoingCoverOnTop = true;
      _previewTrendAnchor = progress;
    }
    _coverController.value = progress;
  }

  @override
  void land({required double progressVelocity}) {
    HapticsService.mediumImpact();
    // 提交落位：目标封面重新回到上层（与稳态一致）。
    _outgoingCoverOnTop = false;
    // 从当前拖动进度继续走到落位；带上手势速度（进度域，画面 = |dx| / range）。
    _coverController.animateTo(1, withVelocity: progressVelocity);
  }

  @override
  void releasePreview({double progressVelocity = 0}) {
    // 松手回弹：当前封面从下面回到中心，必须压在回退中的目标封面之上。
    _outgoingCoverOnTop = true;
    if (!_session.visible) {
      // 不可见：直接回位（ticker 被静音，弹簧会冻结在半途）。
      _coverController.value = 0;
      _session.returnCompleted();
      return;
    }
    // 回退期间保留预览目标身份（见 CoverSwapPhase.returning）：等弹簧自然
    // 走完再撤下预览视觉。只认 ticker 的自然完成——被新拖动/切歌取消时
    // `then` 不会触发；也不能监听 dismissed：直接写 value 也会发该状态。
    unawaited(
      _coverController.animateTo(0, withVelocity: progressVelocity).then((_) {
        if (!mounted) return;
        _session.returnCompleted();
      }),
    );
  }

  @override
  void startSettle({required int direction}) {
    // 即时切歌/快速连切：目标始终在上层。
    _outgoingCoverOnTop = false;
    // 上一个会话可能停在（或正在）校正：新切歌直接接管，停掉校正控制器。
    if (_reconcileCorrection.isAnimating) _reconcileCorrection.stop();
    final bool midFlight = _coverSwapMidFlight;
    final double p0 = _coverController.value.clamp(0.0, 1.0);
    // 连续接管只接受「同一方向 + 仍是上一段的完成中 + 未接近落位」：
    // 方向反转时两侧槽位语义对不上，接近落位时剩余行程太短，都走兜底。
    final bool canHandoff =
        midFlight &&
        _session.phase == CoverSwapPhase.settling &&
        direction == _session.direction &&
        p0 < _takeoverMaxProgress &&
        _session.to != null;
    if (canHandoff) {
      _captureHandoff(progress: p0, direction: direction);
    } else {
      // 安全兜底：等价于「上一段先落位，再从新一段起点重播」——上一段的
      // 进场卡在落位帧就位于中心，新一段 p=0 的滑出卡同样从中心起手，
      // 两张卡的身份/位置连续；方向反转时不做跨方向插值。
      _handoff = null;
      _handoffTails.clear();
      _coverController.stop(canceled: true);
      _coverController.value = 0;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTrackSwapped?.call(false);
      if (canHandoff) {
        // 从当前进度接着走：新会话的 q 把接管起点映射到剩余行程。
        _coverController.animateTo(1);
      } else {
        _coverController.animateTo(1, from: 0, withVelocity: 0);
      }
    });
  }

  /// 捕获连切接管状态：中心卡（上一段的进场卡）与上一段滑出卡。
  ///
  /// 新会话的滑出卡以中心卡捕获位置为起点，用 `q = (p - p0) / (1 - p0)`
  /// 连续插值到目标侧槽；新的中心卡继续沿用全局 `p` 的侧槽入场公式，
  /// 因此它在 p0 帧与旧中心卡完全重合，形成无缝接管。
  void _captureHandoff({required double progress, required int direction}) {
    final Track? centerTrack = _session.to;
    final Track? oldOutgoing = _session.from;
    // 链路中的上一段：若已是接管会话，它的滑出卡由 q 公式绘制，必须按
    // 当前渲染值捕获，不能再用新会话公式重算。
    final _CoverHandoff? previousHandoff = _handoff;
    if (previousHandoff != null) {
      final _HandoffVisual? visual = _handoffOutgoingVisual(
        progress,
        handoff: previousHandoff,
      );
      if (visual != null && visual.opacity > 0.01) {
        _handoffTails.add(
          _CoverHandoffTail(
            track: previousHandoff.centerTrack,
            p0: progress,
            direction: previousHandoff.direction,
            x: visual.x,
            scale: visual.scale,
            rotation: visual.rotation,
            opacity: visual.opacity,
          ),
        );
      }
    } else if (oldOutgoing != null) {
      // 上一段是常规滑出：中心运动公式在 p0 的值就是它此刻的视觉状态。
      _handoffTails.add(
        _CoverHandoffTail(
          track: oldOutgoing,
          p0: progress,
          direction: _session.direction,
          x: -widget.artDimension * 0.30 * _session.direction * progress,
          scale: 1.0 - 0.22 * progress,
          rotation: -0.05 * _session.direction * progress,
          opacity: 1.0 - 0.15 * progress,
        ),
      );
    }
    // 只保留最近两层离场卡（连续快滑的眼可见残影窗口）。
    while (_handoffTails.length > 2) {
      _handoffTails.removeAt(0);
    }
    _handoff = _CoverHandoff(
      p0: progress,
      direction: direction,
      centerTrack: centerTrack!,
    );
  }

  /// 接管会话中滑出卡的当前视觉（未接管时返回 null）。
  _HandoffVisual? _handoffOutgoingVisual(
    double progress, {
    _CoverHandoff? handoff,
  }) {
    final _CoverHandoff? value = handoff ?? _handoff;
    if (value == null) return null;
    final double sideOffset = widget.artDimension * 0.30;
    final double q = ((progress - value.p0) / (1 - value.p0)).clamp(0.0, 1.0);
    return _HandoffVisual(
      x: _lerp(
        value.direction * sideOffset * (1 - value.p0),
        -sideOffset * value.direction,
        q,
      ),
      scale: _lerp(0.78 + 0.22 * value.p0, 0.78, q),
      rotation: _lerp(
        0.05 * value.direction * (1 - value.p0),
        -0.05 * value.direction,
        q,
      ),
      opacity: _lerp(0.85 + 0.15 * value.p0, 0.85, q),
    );
  }

  @override
  void settleDuringDrag() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 用户正在拖动预览：动画不接管，由手指继续驱动（标题入场也让位）。
      widget.onTrackSwapped?.call(true);
      if (_coverController.isAnimating) {
        _coverController.stop(canceled: true);
      }
    });
  }

  @override
  void settleCommit() {
    _outgoingCoverOnTop = false;
    // 预览期间源侧新身份已经渲染（再下一首 / 再上一首）。对账后若实际源侧
    // 就是同一身份，直接从预览透明度接管，不再重放 180ms 淡入；身份不一致
    // 或不可预测（随机轮末等）时保留原有淡入兜底。
    final previewNeighbor = _session.previewSourceNeighbor;
    final actualSource = _session.direction == 1
        ? _playback?.snapshot.next
        : _playback?.snapshot.previous;
    final bool continuous =
        previewNeighbor != null &&
        actualSource != null &&
        previewNeighbor.id == actualSource.id;
    final double start = continuous
        ? _sourceFadeStartFor(
            _sourceNewNeighborOpacityAt(_coverController.value.clamp(0.0, 1.0)),
          )
        : 0.0;
    _sourceNeighborFade.value = start;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTrackSwapped?.call(false);
      // 过渡已在提交时走完：画面即最终态，直接落位；若还在换场中段
      // （快速对账），保持它继续（center 已是 displayTrack，位置连续）。
      if (!_coverSwapMidFlight) _coverController.value = 1.0;
      if (start < 1) _sourceNeighborFade.forward(from: start);
    });
  }

  @override
  void crossfadeCorrection() {
    _outgoingCoverOnTop = false;
    _reconcileCorrection.value = 0;
    _sourceNeighborFade.value = 0;
    _reconcileCorrection.forward();
    _sourceNeighborFade.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTrackSwapped?.call(false);
      if (!_coverSwapMidFlight) _coverController.value = 1.0;
    });
  }

  @override
  void adoptSteadySlots() {
    // 身份淡换进行中不叠加接管（下一次稳态帧自然对齐）。
    if (_slotIdentityFade.isAnimating) return;
    final playback = _playback;
    if (playback != null) _syncSlotIdentityTracking(playback.snapshot);
  }

  @override
  void hardReset({Track? adoptTrack}) {
    disarmTimeout();
    _coverController.stop(canceled: true);
    _coverController.value = 1.0;
    _sourceNeighborFade.value = 1.0;
    _reconcileCorrection.value = 1.0;
    _slotIdentityFade.value = 1.0;
    _artworkRefreshFade.value = 1.0;
    _pressController.stop();
    _pressController.value = 0;
    _pressedSlot = null;
    _outgoingCoverOnTop = false;
    _previewTrendAnchor = 0;
    _handoff = null;
    _handoffTails.clear();
    _centerArtworkRefreshing = false;
    _outgoingCenterArtworkUrl = null;
    _leftSlotOutgoing = null;
    _rightSlotOutgoing = null;
    _resetDragTracking();
    // 隐藏态切歌：父级还没按新曲目重建，中心身份直接接管传入曲目。
    final track = adoptTrack ?? widget.displayTrack;
    _centerTrackId = trackKeyOf(track);
    _centerArtworkUrl = _realCoverUrlOf(track);
    final playback = _playback;
    if (playback != null) _syncPlayState(playback);
  }

  @override
  void requestSkip(int direction) {
    final playback = _playback;
    if (playback == null) return;
    if (direction < 0) {
      playback.skipToPrevious();
    } else {
      playback.skipToNext();
    }
  }

  @override
  void notifySwapped(bool duringDrag) {
    widget.onTrackSwapped?.call(duringDrag);
  }

  @override
  void armTimeout(Duration duration) {
    disarmTimeout();
    _pendingTimer = Timer(duration, () {
      if (!mounted) return;
      _session.timeoutFired();
    });
  }

  @override
  void disarmTimeout() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
  }

  /// 按压反馈开始（原始指针事件驱动：TapGestureRecognizer 的 onTapDown 与
  /// 横滑识别器竞争时要等 100ms 判定或抬手才触发，给不了「按下即反馈」）。
  void _handleCoverPressStart(_DeckSlot slot) {
    _pressedSlot = slot;
    _pressController.animateTo(1);
  }

  /// 按压反馈结束（抬手/取消/横滑接管）：回弹到 0。
  void _handleCoverPressEnd() {
    if (_pressedSlot == null) return;
    _pressController.animateTo(0);
  }

  /// 按压回弹结束：清掉按压槽位（缩放已回 1，无需重建）。
  void _handlePressStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    _pressedSlot = null;
  }

  /// 某槽位的按压缩放；未按压的槽位恒 1.0。
  double _pressScaleFor(_DeckSlot slot) => slot == _pressedSlot
      ? 1 - (1 - _pressScale) * _pressController.value
      : 1.0;

  /// 播放快照通知：合并同一批通知到微任务统一对账。
  ///
  /// - 不在通知回调里直接改 UI：通知可能来自构建/布局期间，微任务一定在
  ///   下一帧构建前运行（不会在 build/布局期间改状态），且同一批（同一次
  ///   抖动）多条通知只处理一次；
  /// - 切歌检测与空闲缓存（左槽身份 / 下一首 / 方向提示）都归
  ///   [CoverSwapSession.observe]：会话是唯一写入者，这里只补渲染侧的空闲
  ///   视觉（中心换图 / 槽位身份淡换）；
  /// - current 为 null（停止/清空）不改变动画身份（deck 仍展示上一首），
  ///   之后同一首恢复也不会重播；只有 id 真正变化才开启新会话。
  void _handlePlaybackChanged() {
    if (_trackSyncScheduled) return;
    _trackSyncScheduled = true;
    scheduleMicrotask(() {
      _trackSyncScheduled = false;
      if (!mounted) return;
      final playback = _playback;
      if (playback == null) return;
      _syncPlayState(playback);
      final bool trackChanged = _session.observe(
        snapshot: playback.snapshot,
        displayTrack: widget.displayTrack,
      );
      // 切歌（身份/动画/对账）由会话接管；同 id 的重复通知才刷新空闲视觉。
      if (!trackChanged) _refreshIdleVisuals(playback);
    });
  }

  void _onMorphChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 飞行中的侧邻位 reveal 变化：只更新本地镜像（Stack 子树逐帧重建）。
  void _onPageDeckRevealChanged() {
    if (!mounted) return;
    final double value = widget.morph?.pageDeckReveal.value ?? 1;
    if (_pageDeckReveal.value != value) _pageDeckReveal.value = value;
  }

  /// current 未变时的空闲刷新：中心换图 + 左右槽位身份淡换。
  ///
  /// 在通知微任务里（下一帧构建前）判定并启动淡化：淡化起点必须先把控制器
  /// 归零，否则会先闪一帧新身份/新图再回跳。会话激活期间（拖动/提交/过渡/
  /// 校正）槽位身份由会话窗口负责，这里只接管中心换图。
  void _refreshIdleVisuals(PlaybackProvider playback) {
    final snapshot = playback.snapshot;
    final current = snapshot.current;
    final currentId = trackKeyOf(current);
    // 中心封面同 id、URL 变化（音源补图）：250ms 交叉淡化换图，不播切歌动画。
    // current 已变（切歌/清空）时由切歌与校正路径接管，不做换图淡化。
    if (currentId != null &&
        currentId == _session.animatedTrackId &&
        currentId == _centerTrackId) {
      final url = _realCoverUrlOf(current);
      if (url != _centerArtworkUrl) {
        if (!_session.visible || _artworkRefreshFade.isAnimating) {
          // 不可见（或淡化中再次更新）：直接接管新 URL，不启动/重启动画。
          _centerArtworkUrl = url;
        } else {
          setState(() {
            _outgoingCenterArtworkUrl = _centerArtworkUrl;
            _centerArtworkRefreshing = true;
            _centerArtworkUrl = url;
            _artworkRefreshFade.value = 0;
          });
          _artworkRefreshFade.forward();
        }
      }
    }
    _refreshIdleSlots(snapshot);
  }

  /// 空闲期槽位身份变化（加歌/删歌/开关随机导致上一首/下一首换人）：
  /// 以约 180ms 原位交叉淡化表达；身份变为空则淡出为空。
  ///
  /// 门控：只在会话 idle 且过渡动画已停下时接管——拖动/提交/校正期间槽位
  /// 身份由会话窗口负责，不得叠加。左槽身份取自会话（[CoverSwapSession.
  /// previous]），与渲染同源。
  void _refreshIdleSlots(PlaybackSnapshot snapshot) {
    if (_session.phase != CoverSwapPhase.idle || _coverController.isAnimating) {
      return;
    }
    final left = _session.previous;
    final right = snapshot.next;
    final bool leftChanged = _leftSlotShown?.id != left?.id;
    final bool rightChanged = _rightSlotShown?.id != right?.id;
    if (!leftChanged && !rightChanged) return;
    if (!_session.visible) {
      // 不可见：身份直接对齐，不播淡化（避免回到播放页时补播）。
      setState(() {
        if (leftChanged) {
          _leftSlotShown = left;
          _leftSlotOutgoing = null;
        }
        if (rightChanged) {
          _rightSlotShown = right;
          _rightSlotOutgoing = null;
        }
      });
      return;
    }
    if (_slotIdentityFade.isAnimating) {
      // 淡化中身份再次变化：直接接管新身份（以当前透明度渲染），不重启动画
      // （重启动画会让已淡出的卡透明度回跳）。该侧若还没在淡出（另一侧先
      // 变化），补一个淡出起点：从当前透明度起步，避免直接硬切身份。
      setState(() {
        if (leftChanged) {
          _leftSlotOutgoing ??= _leftSlotShown;
          _leftSlotShown = left;
        }
        if (rightChanged) {
          _rightSlotOutgoing ??= _rightSlotShown;
          _rightSlotShown = right;
        }
      });
      return;
    }
    setState(() {
      if (leftChanged) {
        _leftSlotOutgoing = _leftSlotShown;
        _leftSlotShown = left;
      }
      if (rightChanged) {
        _rightSlotOutgoing = _rightSlotShown;
        _rightSlotShown = right;
      }
      _slotIdentityFade.value = 0;
    });
    _slotIdentityFade.forward();
  }

  /// 会话结束/稳态帧：把槽位身份跟踪对齐到快照（并清掉淡出中的旧身份）。
  ///
  /// 会话窗口（切歌/对账）已经把槽位身份演到位，直接接管不补淡换；空闲期
  /// 后续的变化才会以 [CoverSwapSession] 之外的淡换表达。
  void _syncSlotIdentityTracking(PlaybackSnapshot snapshot) {
    _leftSlotShown = _session.previous;
    _rightSlotShown = snapshot.next;
    _leftSlotOutgoing = null;
    _rightSlotOutgoing = null;
  }

  /// 中心封面同 id、封面 URL 变化（音源补图）：以约 250ms 交叉淡化换图。
  ///
  /// 只在同一曲目 id 内换 URL 时触发；id 变化（切歌/对账落位）由切歌与校正
  /// 路径负责，这里只接管新身份、不播换图淡化。淡化起点必须在新 URL 渲染
  /// 之前把控制器归零，否则会先闪一帧新图再回跳旧图，因此放在这里而不是 build。
  void _syncCenterArtwork(Track? track) {
    final id = trackKeyOf(track);
    final url = _realCoverUrlOf(track);
    if (id != _centerTrackId) {
      _centerTrackId = id;
      _centerArtworkUrl = url;
      _centerArtworkRefreshing = false;
      _outgoingCenterArtworkUrl = null;
      if (_artworkRefreshFade.value != 1.0) _artworkRefreshFade.value = 1.0;
      return;
    }
    if (url == _centerArtworkUrl) return;
    if (_artworkRefreshFade.isAnimating || !_session.visible) {
      // 不可见（或淡化中再次更新）：直接接管新 URL，不启动/重启动画。
      _centerArtworkUrl = url;
      return;
    }
    _outgoingCenterArtworkUrl = _centerArtworkUrl;
    _centerArtworkRefreshing = true;
    _centerArtworkUrl = url;
    _artworkRefreshFade.value = 0;
    _artworkRefreshFade.forward();
  }

  /// 换图淡化结束：撤下旧图卡片（稳态只留实际曲目卡）。
  void _handleArtworkRefreshStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!_centerArtworkRefreshing) return;
    setState(() => _centerArtworkRefreshing = false);
  }

  /// 槽位身份交叉淡化结束：撤下淡出中的旧身份卡。
  void _handleSlotIdentityStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_leftSlotOutgoing == null && _rightSlotOutgoing == null) return;
    setState(() {
      _leftSlotOutgoing = null;
      _rightSlotOutgoing = null;
    });
  }

  /// 校正控制器走完：对账校正结束（会话回 idle，槽位身份按新快照稳态接管）。
  void _handleCorrectionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _session.correctionCompleted();
  }

  /// 进度控制器落位：即时切歌结束 / 提交过渡落位后开始校正 / 回弹落位。
  ///
  /// 三种收尾都属于会话时机（见 [CoverSwapSession.progressCompleted]）。
  void _handleCoverStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 落位帧起稳态槽位接管：清掉接管快照，避免下一次会话误用过期起点。
    _handoff = null;
    _handoffTails.clear();
    _session.progressCompleted();
  }

  @override
  void dispose() {
    _playback?.removeListener(_handlePlaybackChanged);
    _removeCoverListener?.call();
    widget.morph?.removeListener(_onMorphChanged);
    widget.morph?.pageDeckReveal.removeListener(_onPageDeckRevealChanged);
    _pageDeckReveal.dispose();
    disarmTimeout();
    _session.dispose();
    _artworkRefreshFade.removeStatusListener(_handleArtworkRefreshStatus);
    _artworkRefreshFade.dispose();
    _slotIdentityFade.removeStatusListener(_handleSlotIdentityStatus);
    _slotIdentityFade.dispose();
    _reconcileCorrection.removeStatusListener(_handleCorrectionStatus);
    _reconcileCorrection.dispose();
    _sourceNeighborFade.dispose();
    _playStateController.dispose();
    _pressController.removeStatusListener(_handlePressStatus);
    _pressController.dispose();
    _coverController.removeStatusListener(_handleCoverStatus);
    _coverController.dispose();
    super.dispose();
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    // 横滑接管：按压反馈让位（拖动跟手本身就是反馈）。
    _handleCoverPressEnd();
    // 过渡动画 / 迷你⇄完整封面飞行 / 顶栏⇄播放页飞行期间不接受新手势
    // （提交等待与校正由会话自己拒绝）：一次拖动只对应一次切歌，避免两段
    // 过渡叠加；飞行期间由副本承接，deck 本身冻结。
    if (_coverSwapMidFlight ||
        widget.coverFlightActive ||
        (widget.morph?.pageHeaderHidden ?? false)) {
      return;
    }
    if (!_session.dragStart()) return;
    _dragStartX = details.globalPosition.dx;
    _dragStartY = details.globalPosition.dy;
    _dragDx = 0;
    _isHorizontalDragConfirmed = false;
    // 新手势的层级从「目标在上」起步；第一次有效位移会按趋势重新判定。
    _outgoingCoverOnTop = false;
    _previewTrendAnchor = _coverController.value;
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_session.dragActive || _dragStartX == null || _dragStartY == null) {
      return;
    }

    final dx = details.globalPosition.dx - _dragStartX!;
    final dy = details.globalPosition.dy - _dragStartY!;

    if (!_isHorizontalDragConfirmed) {
      if (dy.abs() > dx.abs() * 1.5) {
        // 纵向意图更明确：放弃本次横向拖动（展开/收起交给外层手势）。
        _session.dragCancel();
        _resetDragTracking();
        return;
      } else if (dx.abs() > 10.0) {
        _isHorizontalDragConfirmed = true;
      }
    }

    if (!_isHorizontalDragConfirmed) return;
    _dragDx = dx;
    // 进度即画面进度：拖动跟手与弹簧吸附同源，松手从同一进度续播不跳。
    final double visual = (dx.abs() / _coverSwapRange).clamp(0.0, 1.0);
    _session.dragUpdate(delta: dx, progress: visual);
  }

  /// 是否处于「换场中段」。
  ///
  /// 弹簧在容差内会一直报 `isAnimating`（进度 ≈1 的不可见拖尾），不能直接
  /// 当「过渡进行中」判定——否则新手势/新切歌会在尾部窗口被饿死，看起来
  /// 像动画没播。真正中段才「续走不重放」。
  bool get _coverSwapMidFlight =>
      _coverController.isAnimating && _coverController.value < 0.99;

  /// 拖动行程：约 0.6 个封面宽度走完整段过渡（也是速度→进度的换算基准）。
  double get _coverSwapRange => max(48.0, widget.artDimension * 0.6);

  /// 松手：达标且存在预览目标则提交切歌；未达标/边界回弹。
  void _handleHorizontalDragEnd(DragEndDetails details) {
    // 本次手势已被忽略（提交等待期间的拖动）。
    if (!_session.dragActive) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final dx = _dragDx;
    final confirmed = _isHorizontalDragConfirmed;
    final wasPreviewing = _session.previewActive;
    _session.dragEnd();
    _resetDragTracking();
    if (!confirmed) return;

    final threshold = widget.isLargeScreen ? 400.0 : 800.0;
    final triggerDistance = widget.isLargeScreen ? 40.0 : 80.0;
    final bool shouldCommit =
        velocity.abs() > threshold || dx.abs() > triggerDistance;

    // 只有进入过预览（存在可切换的目标）才允许提交；边界拖动直接回弹。
    if (!wasPreviewing) return;

    // 手势速度换算到进度域（画面进度 = |dx| / range），松手从同一进度续播。
    final double progressVelocity = -velocity / _coverSwapRange;
    if (shouldCommit) {
      _session.commit(progressVelocity: progressVelocity);
    } else {
      _session.releasePreview(progressVelocity: progressVelocity);
    }
  }

  void _handleHorizontalDragCancel() {
    _session.dragCancel();
    _resetDragTracking();
  }

  /// 复位 deck 侧的手势跟踪（会话的拖动状态由会话自己收尾）。
  void _resetDragTracking() {
    _dragStartX = null;
    _dragStartY = null;
    _dragDx = 0;
    _isHorizontalDragConfirmed = false;
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    // 切歌检测与空闲缓存刷新都在播放快照监听里（微任务）完成：build 期间
    // 零写入，这里只渲染当前会话/稳态画面。
    return _buildArtworkStack(context, playback);
  }

  /// 三封面堆叠：左=上一首、中=当前、右=下一首（左右压住露出边缘）。
  ///
  /// 切歌动画与「拖动跟手」共用同一条进度（[`_coverController`]）：横向拖动
  /// 时中心位由预览目标封面顶上、按滑动距离过渡；松手后从同一进度续播或回弹。
  /// 无上一首/下一首时对应槽位为空（不闪、不空跳）。
  ///
  /// 横向手势宿主固定在 [AnimatedBuilder] 外层：拖动期间中心卡会因
  /// `interactive` 换型重建，手势挂在卡上会被 dispose（表现为滑到一半冻住、
  /// 松手无反应）。宿主 element 稳定，控制器逐帧重建只影响子树。
  Widget _buildArtworkStack(
    BuildContext context,
    PlaybackProvider playbackProvider,
  ) {
    final String? currentImageUrl = _realCoverUrlOf(widget.displayTrack);
    return Listener(
      // DragGestureRecognizer 对「已接受」手势的 PointerCancel 也走 onEnd
      // （不是 onCancel），而 Listener 先于识别器收到取消事件：这里直接
      // 按取消处理并复位，随后识别器的 onEnd 因 dragActive=false 被忽略，
      // 避免系统打断被当成松手提交切歌。
      onPointerCancel: (_) => _handleHorizontalDragCancel(),
      child: GestureDetector(
        key: PlayerCoverDeck.swipeHostKey,
        behavior: HitTestBehavior.opaque,
        // 从手指真实按下位置起算位移：默认的 start 会吃掉 touch slop，
        // 拖动距离与阈值判断都会缩小（110px 的滑动会被量成 80px）。
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: _handleHorizontalDragStart,
        onHorizontalDragUpdate: _handleHorizontalDragUpdate,
        onHorizontalDragEnd: _handleHorizontalDragEnd,
        onHorizontalDragCancel: _handleHorizontalDragCancel,
        child: Center(
          child: SizedBox(
            key: PlayerCoverDeck.stackKey,
            width: widget.stackDimension,
            height: widget.stackHeight,
            child: AnimatedBuilder(
              animation: _coverStackAnimation,
              builder: (context, _) {
                // 拖动预览与切歌动画共用渲染：拖动时进度由手指驱动。
                // settling 在检测帧（动画尚未在 post-frame 启动）也按过渡渲染：
                // 滑出卡必须从会话建立的第一帧起就参与（否则会先画落位态再
                // 回跳，且空闲缓存可能误清会话身份）。
                // correcting（对账校正）只走中心交叉淡化：左右槽按新快照
                // 稳态渲染，不叠加切歌窗口。
                final session = _session;
                final correcting = session.phase == CoverSwapPhase.correcting;
                // 预览视觉（拖动跟手 / 提交等待 / 回退中）都由会话目标驱动：
                // 回退中若换回当前曲目，目标槽位会在回弹半途闪成当前封面。
                final showingPreview = session.showingPreviewTarget;
                final animating =
                    !correcting &&
                    (showingPreview ||
                        _coverController.isAnimating ||
                        session.phase == CoverSwapPhase.settling);
                // p 是弹簧进度：位移/旋转/缩放直接用 p（spatial 弹簧保留过冲）；
                // 透明度窗口从 p 派生且截断 0..1（M3E 规范：effects 不过冲）。
                final double p = _coverController.value;
                final double t = p;
                final double pClamped = p.clamp(0.0, 1.0);
                final dir = session.direction;
                final double sideSize = widget.artDimension * 0.78;
                final double offset = widget.artDimension * 0.30;
                const double sideRotation = 0.05;
                // 侧邻位展开进度：进入飞行最后 45% 从中心展开 / 离开反向收回；
                // 减弱动效直接落位。中心卡不参与这个 transform（锚点必须是
                // 稳态矩形）。
                final double reveal = reduceMotionOf(context)
                    ? 1.0
                    : _pageDeckReveal.value.clamp(0.0, 1.0);
                // 飞行期间整层手势与侧槽点击关闭（副本才是唯一交互/视觉来源）。
                final bool deckFrozen = widget.morph?.pageHeaderHidden ?? false;
                final _CoverHandoff? handoff = _handoff;
                final bool handoffActive =
                    handoff != null &&
                    session.phase == CoverSwapPhase.settling &&
                    trackKeyOf(session.from) == trackKeyOf(handoff.centerTrack);
                final children = <Widget>[];

                // 接管后更早的滑出卡：从捕获位置继续向左离场并快速淡出，
                // 不参与新会话的邻位窗口（否则会与 oldNeighbor 同身份叠影）。
                for (final tail in _handoffTails) {
                  final _HandoffVisual visual = tail.visualAt(
                    p,
                    sideOffset: offset,
                    fadeSpan: _takeoverTailFadeSpan,
                  );
                  if (visual.opacity <= 0.005) continue;
                  children.add(
                    _mainCoverLayer(
                      context,
                      tail.track,
                      playbackProvider,
                      artDimension: widget.artDimension,
                      // 尾卡列表只在接管时变动：按身份 + 捕获进度给稳定
                      // key，避免新增尾卡时旧 element 被换曲重建（图片闪）。
                      layerKey: ValueKey(
                        'coverHandoffTail:${tail.track.id.uri}:${tail.p0}',
                      ),
                      x: visual.x,
                      rotation: visual.rotation,
                      scale: visual.scale,
                      opacity: visual.opacity,
                      interactive: false,
                    ),
                  );
                }

                // 回拖/回弹时当前封面压在中心目标之上；正向拖动/落位时
                // 目标在上（与稳态一致）。
                final bool outgoingOnTop =
                    showingPreview && _outgoingCoverOnTop;
                Widget? outgoingLayer;
                // 目标槽位旧身份：窗口 p∈[0, 0.4] 内 0.85→0 原位淡出（无位移），
                // 与源槽位新身份的淡入窗口（p∈[0.6, 1]）错开——同一槽位不出现
                // 两张半透明封面叠加的「叠影」。接管会话中这个旧身份正是被
                // 替换下来的上一段滑出卡，由 tail 层接管，不能重复渲染。
                if (animating &&
                    session.oldNeighbor != null &&
                    !handoffActive) {
                  children.add(
                    _sideCoverLayer(
                      context,
                      session.oldNeighbor,
                      sideSize: sideSize,
                      x: -offset * dir,
                      rotation: -sideRotation * dir,
                      opacity: _oldNeighborOpacityAt(pClamped),
                      reveal: reveal,
                      cardKey: PlayerCoverDeck.sideCoverCardKey(
                        left: dir > 0,
                        id: session.oldNeighbor!.id,
                      ),
                    ),
                  );
                }

                if (animating) {
                  // 源槽位新身份：窗口 p∈[0.6, 1] 内 0→0.85 原位淡入（无位移）。
                  // 拖动预览时目标尚未成为快照 current，源侧身份取会话提前
                  // 解析的「再下一首 / 再上一首」，让三槽窗口随拖动连续滑动；
                  // 即时切歌时快照已经翻页，取新 current 的邻位即可。
                  final Track? sourceTrack = showingPreview
                      ? session.previewSourceNeighbor
                      : (dir == 1
                          ? playbackProvider.snapshot.next
                          : session.previous);
                  // 预览中目标封面仍在场，作为源侧缺图占位最连续；即时切歌
                  // 时当前封面就是新曲目。
                  final String? sourcePlaceholderUrl = showingPreview
                      ? (_realCoverUrlOf(session.to) ?? currentImageUrl)
                      : currentImageUrl;
                  children.add(
                    _sideCoverLayer(
                      context,
                      sourceTrack,
                      sideSize: sideSize,
                      x: offset * dir,
                      rotation: sideRotation * dir,
                      opacity: _sourceNewNeighborOpacityAt(pClamped),
                      reveal: reveal,
                      cardKey: sourceTrack == null
                          ? null
                          : PlayerCoverDeck.sideCoverCardKey(
                              left: dir < 0,
                              id: sourceTrack.id,
                            ),
                      placeholderUrl: sourcePlaceholderUrl,
                    ),
                  );
                  // 滑出的旧当前 → 目标槽位：全程插值（终点与稳态槽位卡
                  // 完全重合：位置/旋转/缩放/透明度一致，动画结束无 pop）。
                  // 连切接管时以捕获的中心卡视觉为起点、按剩余行程
                  // `q = (p - p0) / (1 - p0)` 插值（见 _handoffOutgoingVisual）；
                  // 否则沿用本轮全局进度公式。
                  // 入栈时机由 outgoingOnTop 决定（见中心卡渲染）。
                  if (session.from != null) {
                    final _HandoffVisual outgoing = handoffActive
                        ? _handoffOutgoingVisual(p, handoff: handoff)!
                        : _HandoffVisual(
                            x: -offset * dir * t,
                            rotation: -sideRotation * dir * t,
                            scale: 1.0 - 0.22 * t,
                            opacity: 1.0 - 0.15 * pClamped,
                          );
                    outgoingLayer = _mainCoverLayer(
                      context,
                      session.from,
                      playbackProvider,
                      artDimension: widget.artDimension,
                      slotKey: PlayerCoverDeck.outgoingCoverCardKey,
                      layerKey: _outgoingLayerKey,
                      x: outgoing.x,
                      rotation: outgoing.rotation,
                      scale: outgoing.scale,
                      opacity: outgoing.opacity,
                      interactive: false,
                    );
                  }
                } else {
                  // 稳态邻位：可点击切歌（左=上一首，右=下一首）。
                  // - 拖动对账落位后的源侧新身份以纯透明度淡入（无位移/缩放/旋转）；
                  // - 空闲期身份变化（加歌/删歌/开关随机/next 变空）以约
                  //   180ms 原位交叉淡化表达（旧身份淡出、新身份淡入）。
                  // 两个淡化控制器稳态都停在 1，倍率不产生任何影响。
                  final double sourceFade = Curves.easeOut.transform(
                    _sourceNeighborFade.value.clamp(0.0, 1.0),
                  );
                  final double identityFade = Curves.easeOut.transform(
                    _slotIdentityFade.value.clamp(0.0, 1.0),
                  );
                  // 邻位占位只在槽位身份过渡期间借用当前封面：冷启动首帧
                  // 左右图还没解码完时若也用当前封面，会短暂出现「三张
                  // 同一封面」的错位闪动；稳态交给各自的中性占位。
                  final bool sideTransitioning =
                      _slotIdentityFade.isAnimating ||
                          _sourceNeighborFade.isAnimating;
                  final String? sidePlaceholderUrl =
                      sideTransitioning ? currentImageUrl : null;
                  children.addAll(
                    _idleSideLayers(
                      context,
                      left: true,
                      shown: session.previous,
                      outgoing: _leftSlotOutgoing,
                      sideSize: sideSize,
                      x: -offset,
                      rotation: -sideRotation,
                      sourceFade: dir == -1 ? sourceFade : 1.0,
                      identityFade: identityFade,
                      reveal: reveal,
                      placeholderUrl: sidePlaceholderUrl,
                      // 左槽点击 = 上一首：只要展示了身份（快照 previous 或
                      // 队列前一位，与后端 skipToPrevious 的回退、拖动预览
                      // 同源）就可点；左槽为空时不渲染卡片，自然不可点。
                      // 飞行期间禁用点击（副本/锚点交接期间不接受切歌）。
                      onTap: !deckFrozen && playbackProvider.hasTrack
                          ? playbackProvider.skipToPrevious
                          : null,
                    ),
                  );
                  children.addAll(
                    _idleSideLayers(
                      context,
                      left: false,
                      shown: playbackProvider.snapshot.next,
                      outgoing: _rightSlotOutgoing,
                      sideSize: sideSize,
                      x: offset,
                      rotation: sideRotation,
                      sourceFade: dir == 1 ? sourceFade : 1.0,
                      identityFade: identityFade,
                      reveal: reveal,
                      placeholderUrl: sidePlaceholderUrl,
                      onTap: !deckFrozen && playbackProvider.hasTrack
                          ? playbackProvider.skipToNext
                          : null,
                    ),
                  );
                }

                // 中心位：拖动/提交/回退时由预览目标封面顶上（真正的切歌在松手后
                // 才发生）；动画/稳态下就是当前曲目。顶栏⇄播放页飞行时只隐藏
                // 这一张。预览目标在拖动开始时固定，不重读快照（否则提交后
                // 快照先推新邻位，中心封面会闪成再下一首）。
                //
                // 透明度随进度 0.85→1.0 连续插值：p=0 时与稳态的源槽位卡
                // 完全一致（0.85），消除「动画首帧硬跳 1.0」的起手闪跳；
                // p=1 时与稳态中心封面一致（1.0）。
                if (correcting) {
                  // 对账校正：旧预览卡（原位）淡出、实际曲目卡淡入，全程
                  // 无位移/缩放——到位曲目与预览目标不同时只换图不搬位。
                  final double correctionFade = Curves.easeOut.transform(
                    _reconcileCorrection.value.clamp(0.0, 1.0),
                  );
                  if (session.to != null) {
                    children.add(
                      _mainCoverLayer(
                        context,
                        session.to,
                        playbackProvider,
                        artDimension: widget.artDimension,
                        slotKey: PlayerCoverDeck.outgoingCoverCardKey,
                        layerKey: _outgoingLayerKey,
                        x: 0,
                        rotation: 0,
                        scale: 1.0,
                        opacity: 1.0 - correctionFade,
                        interactive: false,
                        hidden: _pageCoverHidden,
                      ),
                    );
                  }
                  children.addAll(
                    _steadyCenterLayers(
                      context,
                      playbackProvider,
                      opacity: correctionFade,
                    ),
                  );
                } else if (animating) {
                  final Track? centerTrack = showingPreview
                      ? (session.to ?? widget.displayTrack)
                      : widget.displayTrack;
                  if (!outgoingOnTop && outgoingLayer != null) {
                    children.add(outgoingLayer);
                  }
                  children.add(
                    _mainCoverLayer(
                      context,
                      centerTrack,
                      playbackProvider,
                      artDimension: widget.artDimension,
                      slotKey: PlayerCoverDeck.centerCoverCardKey,
                      layerKey: _centerLayerKey,
                      trackKey: centerTrack == null
                          ? null
                          : PlayerCoverDeck.centerCoverTrackKey(centerTrack.id),
                      x: dir * offset * (1 - t),
                      rotation: sideRotation * dir * (1 - t),
                      scale: 0.78 + 0.22 * t,
                      opacity: 0.85 + 0.15 * pClamped,
                      interactive: !showingPreview,
                      coverKey: widget.morph?.pageCoverKey,
                      hidden: _pageCoverHidden,
                      // 中心卡不借上一首封面当占位：目标图未预热时用曲目自己的
                      // 默认封面 / 中性回退，避免旧封面从下面透出。
                    ),
                  );
                  if (outgoingOnTop && outgoingLayer != null) {
                    children.add(outgoingLayer);
                  }
                } else {
                  // 稳态中心：同 id、URL 更新（音源补图）时以约 250ms 交叉
                  // 淡化换图（旧图淡出、新图淡入），不播切歌动画。
                  children.addAll(
                    _steadyCenterLayers(
                      context,
                      playbackProvider,
                      opacity: 1.0,
                    ),
                  );
                }

                return Stack(clipBehavior: Clip.none, children: children);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 目标槽位旧身份透明度：窗口 p∈[0, 0.4] 内 0.85→0（窗口内 easeOut），
  /// 之后保持 0。窗口化交叉让旧身份先退场、新身份后进场。
  double _oldNeighborOpacityAt(double p) {
    final double window = (p / _oldNeighborFadeEnd).clamp(0.0, 1.0);
    return _neighborOpacity * (1 - Curves.easeOut.transform(window));
  }

  /// 源槽位新身份透明度：窗口 p∈[0.6, 1] 内 0→0.85（窗口内 easeInOut）。
  double _sourceNewNeighborOpacityAt(double p) {
    final double window =
        ((p - _newNeighborFadeStart) / (1 - _newNeighborFadeStart)).clamp(
          0.0,
          1.0,
        );
    return _neighborOpacity * Curves.easeInOut.transform(window);
  }

  /// 把预览阶段的源侧透明度换算成 [_sourceNeighborFade] 的起点。
  ///
  /// 稳态淡入渲染的是 `_neighborOpacity × easeOut(fade)`；预览窗口用的是
  /// easeInOut。求 easeOut 的反函数，保证对账切换的那一帧透明度不跳。
  double _sourceFadeStartFor(double previewOpacity) {
    final double target = (previewOpacity / _neighborOpacity).clamp(0.0, 1.0);
    if (target <= 0) return 0;
    if (target >= 1) return 1;
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 12; i++) {
      final mid = (low + high) / 2;
      if (Curves.easeOut.transform(mid) < target) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return (low + high) / 2;
  }

  /// 稳态邻位槽位的渲染层：身份交叉淡化期间同槽位并存旧（淡出）与新
  /// （淡入）两张卡，全程稳态几何（无位移/缩放/旋转）；身份变空则只渲染
  /// 淡出中的旧卡（淡出为空）。[sourceFade] 是对账落位后的源侧纯淡入倍率。
  List<Widget> _idleSideLayers(
    BuildContext context, {
    required bool left,
    required Track? shown,
    required Track? outgoing,
    required double sideSize,
    required double x,
    required double rotation,
    required double sourceFade,
    required double identityFade,
    required double reveal,
    required String? placeholderUrl,
    required VoidCallback? onTap,
  }) {
    final double base = _neighborOpacity * sourceFade;
    final layers = <Widget>[];
    if (outgoing != null) {
      layers.add(
        _sideCoverLayer(
          context,
          outgoing,
          sideSize: sideSize,
          x: x,
          rotation: rotation,
          opacity: base * (1 - identityFade),
          reveal: reveal,
          cardKey: PlayerCoverDeck.sideCoverCardKey(
            left: left,
            id: outgoing.id,
          ),
          placeholderUrl: placeholderUrl,
        ),
      );
    }
    if (shown != null) {
      layers.add(
        _sideCoverLayer(
          context,
          shown,
          sideSize: sideSize,
          x: x,
          rotation: rotation,
          opacity: base * identityFade,
          reveal: reveal,
          cardKey: PlayerCoverDeck.sideCoverCardKey(left: left, id: shown.id),
          placeholderUrl: placeholderUrl,
          onTap: onTap,
          pressSlot: left ? _DeckSlot.left : _DeckSlot.right,
        ),
      );
    }
    return layers;
  }

  /// 稳态中心封面层：实际曲目卡（交互 + 共享飞行锚点），同 id 换图淡化
  /// 期间追加旧 URL 卡（原位淡出、不可交互）。
  List<Widget> _steadyCenterLayers(
    BuildContext context,
    PlaybackProvider playbackProvider, {
    required double opacity,
  }) {
    final double artworkFade = Curves.easeOut.transform(
      _artworkRefreshFade.value.clamp(0.0, 1.0),
    );
    final layers = <Widget>[];
    if (_centerArtworkRefreshing && artworkFade < 1) {
      layers.add(
        _mainCoverLayer(
          context,
          widget.displayTrack,
          playbackProvider,
          artDimension: widget.artDimension,
          slotKey: PlayerCoverDeck.outgoingArtworkCardKey,
          layerKey: _outgoingArtworkLayerKey,
          x: 0,
          rotation: 0,
          scale: 1.0,
          opacity: opacity * (1 - artworkFade),
          interactive: false,
          hidden: _pageCoverHidden,
          // 空串表达「明确无封面」（音源补图前的起点）：传 null 会被当作
          // 「未提供覆盖」而回退到曲目当前（新）URL，旧图卡就变成新图了。
          artworkUrlOverride: _outgoingCenterArtworkUrl ?? '',
          fallback: buildFallbackArtwork(context),
        ),
      );
    }
    layers.add(
      _mainCoverLayer(
        context,
        widget.displayTrack,
        playbackProvider,
        artDimension: widget.artDimension,
        slotKey: PlayerCoverDeck.centerCoverCardKey,
        layerKey: _centerLayerKey,
        trackKey: widget.displayTrack == null
            ? null
            : PlayerCoverDeck.centerCoverTrackKey(widget.displayTrack!.id),
        x: 0,
        rotation: 0,
        scale: 1.0,
        opacity: opacity * artworkFade,
        interactive: true,
        coverKey: widget.morph?.pageCoverKey,
        hidden: _pageCoverHidden,
      ),
    );
    return layers;
  }

  /// 邻位封面（压在当前封面之下；[onTap] 非空时可点击切歌）。
  ///
  /// 稳态几何固定（位置/旋转/尺寸），透明度由调用方按窗口/淡入计算。
  /// [reveal] 是进入/离开播放页时侧槽从中心展开/收回的进度：0 = 收回中心
  /// （不渲染，省掉缩放为 0 的图片层），1 = 稳态侧槽（直接返回原 child，
  /// 不叠加 transform）。中心卡不在这里，所以 reveal 不会改变封面锚点。
  /// 不参与 hit test 时（[onTap] 为空）忽略指针。[cardKey] 是身份语义 key
  /// （空闲淡换时同一槽位并存新旧两张卡，测试按身份定位）。
  /// 卡本体的渲染归 [CoverCard]（可点邻位的手势 child 即它）。
  Widget _sideCoverLayer(
    BuildContext context,
    Track? track, {
    required double sideSize,
    required double x,
    required double rotation,
    required double opacity,
    required double reveal,
    Key? cardKey,
    String? placeholderUrl,
    VoidCallback? onTap,
    _DeckSlot? pressSlot,
  }) {
    if (track == null) return const SizedBox.shrink();
    final double progress = reveal.clamp(0.0, 1.0);
    if (progress <= 0) return const SizedBox.shrink();
    final bool settled = progress >= 1.0;
    final double eased = settled
        ? 1.0
        : Curves.easeOutCubic.transform(progress);
    Widget card = _buildCoverCard(
      context,
      track,
      sideSize,
      key: cardKey,
      placeholderUrl: placeholderUrl,
    );
    if (onTap != null) {
      final slot = pressSlot!;
      card = Transform.scale(
        scale: _pressScaleFor(slot),
        child: Listener(
          // 按压反馈走原始指针事件：onTapDown 与横滑识别器竞争时要等
          // 100ms 判定或抬手才触发，给不了「按下即反馈」。
          onPointerDown: (_) => _handleCoverPressStart(slot),
          onPointerUp: (_) => _handleCoverPressEnd(),
          onPointerCancel: (_) => _handleCoverPressEnd(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticsService.lightImpact();
              onTap();
            },
            child: card,
          ),
        ),
      );
    }
    final Widget body = Opacity(
      opacity: settled ? opacity : opacity * eased,
      child: IgnorePointer(ignoring: onTap == null, child: card),
    );
    return Positioned.fill(
      child: Center(
        child: Transform.translate(
          offset: Offset(settled ? x : x * eased, 0),
          child: Transform.rotate(
            angle: settled ? rotation : rotation * eased,
            child: settled ? body : Transform.scale(scale: eased, child: body),
          ),
        ),
      ),
    );
  }

  /// 当前/滑出封面（可交互时保留滑动手势与点击播放/暂停）。
  ///
  /// [artworkUrlOverride] 用于换图淡化的旧 URL 卡：曲目身份相同、只换图片
  /// 地址（[fallback] 与稳态中心卡一致，避免缺图时占位不一致）。
  /// [trackKey] 是中心封面的身份语义 key（校正后展示的是哪一首）。
  Widget _mainCoverLayer(
    BuildContext context,
    Track? track,
    PlaybackProvider playbackProvider, {
    required double artDimension,
    required double x,
    required double rotation,
    required double scale,
    required double opacity,
    required bool interactive,
    Key? slotKey,
    Key? trackKey,
    Key? layerKey,
    Key? coverKey,
    bool hidden = false,
    String? artworkUrlOverride,
    Widget? fallback,
  }) {
    Widget card = interactive
        ? _buildConfigurableMainContent(
            context,
            track,
            playbackProvider,
            artDimension: artDimension,
            coverKey: coverKey,
          )
        : _buildCoverCard(
            context,
            track,
            artDimension,
            artworkUrlOverride: artworkUrlOverride,
            fallback: fallback,
          );
    if (slotKey != null) {
      card = KeyedSubtree(key: slotKey, child: card);
    }
    if (trackKey != null) {
      card = KeyedSubtree(key: trackKey, child: card);
    }
    return Positioned.fill(
      key: layerKey,
      child: Center(
        child: Transform.translate(
          offset: Offset(x, 0),
          child: Transform.rotate(
            angle: rotation,
            child: Transform.scale(
              scale: scale,
              // 隐藏（飞行中）直接乘进同一条透明度：零时长、同层合成，
              // 不嵌套第二层 Opacity（锚点仍在同一布局盒内）。
              child: Opacity(opacity: hidden ? 0 : opacity, child: card),
            ),
          ),
        ),
      ),
    );
  }

  /// 封面卡（三封面/飞行副本共用 [CoverCard]）：外观（r18 + 1px 描边 +
  /// 柔和阴影、裁剪 17）由 [CoverAppearance.page] 统一给出，与飞行副本同源。
  ///
  /// 统一走无缩放缓存键（与顶栏/迷你条/预加载一致），邻位封面升到中间
  /// 只是 transform 插值，不会因缓存键不同重新解码、闪占位图。
  /// [artworkUrlOverride] 供换图淡化渲染旧 URL（曲目身份不变、只换图片地址）。
  Widget _buildCoverCard(
    BuildContext context,
    Track? track,
    double size, {
    Key? key,
    Widget? fallback,
    String? placeholderUrl,
    String? artworkUrlOverride,
  }) {
    final url = artworkUrlOverride ?? _realCoverUrlOf(track);
    return CoverCard(
      key: key,
      size: size,
      appearance: CoverAppearance.page,
      content: (context, clip, iconSize) {
        final coverEdge = playbackCoverDecodeEdge(context);
        final placeholder = placeholderUrl != null && placeholderUrl != url
            ? AppNetworkImage(
                url: placeholderUrl,
                fit: BoxFit.cover,
                fallbackIconSize: iconSize,
                memCacheWidth: coverEdge,
              )
            : fallback;
        return AppNetworkImage(
          url: url,
          fallbackUrl: _coverResolver.defaultCoverUrl,
          fit: BoxFit.cover,
          // 与顶栏↔播放页飞行共享同一外观源（图标态落点必须与真身同尺寸）。
          fallbackIconSize: iconSize,
          memCacheWidth: coverEdge,
          placeholder: placeholder,
          // 缺图槽位也走同一回退（默认封面 → Molia 标志），不展示
          // 「最近播放」封面冒充当前曲目。
          errorWidget:
              fallback ?? buildFallbackArtwork(context, iconSize: iconSize),
        );
      },
    );
  }

  Widget _buildConfigurableMainContent(
    BuildContext context,
    Track? track,
    PlaybackProvider playback, {
    required double artDimension,
    Key? coverKey,
  }) {
    return AnimatedBuilder(
      // 播放态缩放 × 按压反馈（两者相乘合成，互不覆盖）：播放态只用极轻微
      // 的缩放，暂停时封面保持清晰（变暗 20% 会让封面看起来像被禁用）。
      animation: _centerScaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale:
              _playStateScaleAnimation.value * _pressScaleFor(_DeckSlot.center),
          child: child,
        );
      },
      child: Listener(
        // 按压反馈走原始指针事件（见 [_handleCoverPressStart] 注释）。
        onPointerDown: (_) => _handleCoverPressStart(_DeckSlot.center),
        onPointerUp: (_) => _handleCoverPressEnd(),
        onPointerCancel: (_) => _handleCoverPressEnd(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 点击封面 = 播放/暂停；横向拖动由封面区手势宿主统一承接
          // （见 [_buildArtworkStack]：手势不能在拖动期间换型重建）。
          onTap: () {
            HapticsService.lightImpact();
            playback.togglePlayPause();
          },
          child: RepaintBoundary(
            child: KeyedSubtree(
              key: coverKey,
              child: KeyedSubtree(
                key: widget.fullCoverKey,
                // 隐藏透明度由外层中心层按 `hidden` 乘进同一条 Opacity：
                // 飞行副本精确承接起手/落点，真身必须在飞行第一帧就隐去、
                // 落位帧瞬时亮出（这里不再嵌套第二层透明度）。
                child: _buildCoverCard(
                  context,
                  track,
                  artDimension,
                  fallback: buildFallbackArtwork(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面堆叠的槽位标识（按压反馈按槽位定位）。
enum _DeckSlot { left, center, right }

/// 线性插值（避免为一个几何 helper 引入 dart:ui 的 lerpDouble）。
double _lerp(double a, double b, double t) => a + (b - a) * t;

/// 接管会话捕获的起点：上一段中心卡在 p0 的侧槽入场公式值。
///
/// [centerTrack] 是上一段的进场卡（也就是新会话的滑出卡）；[p0] 是新会话
/// 接管时的全局进度，滑出卡用 `(p - p0) / (1 - p0)` 走完剩余行程。
class _CoverHandoff {
  const _CoverHandoff({
    required this.p0,
    required this.direction,
    required this.centerTrack,
  });

  final double p0;
  final int direction;
  final Track centerTrack;
}

/// 一帧可复用的封面视觉状态（接管插值的输入/输出）。
class _HandoffVisual {
  const _HandoffVisual({
    required this.x,
    required this.rotation,
    required this.scale,
    required this.opacity,
  });

  final double x;
  final double rotation;
  final double scale;
  final double opacity;
}

/// 接管后被替换下来的更早滑出卡：从捕获视觉继续向左离场并短淡出。
class _CoverHandoffTail {
  const _CoverHandoffTail({
    required this.track,
    required this.p0,
    required this.direction,
    required this.x,
    required this.scale,
    required this.rotation,
    required this.opacity,
  });

  final Track track;
  final double p0;
  final int direction;
  final double x;
  final double scale;
  final double rotation;
  final double opacity;

  /// 当前全局进度 [progress] 下的视觉：前 [fadeSpan] 段剩余行程内淡出，
  /// 同时继续向远离中心的方向滑出（不回到新会话的侧槽窗口）。
  _HandoffVisual visualAt(
    double progress, {
    required double sideOffset,
    required double fadeSpan,
  }) {
    final double q = ((progress - p0) / (1 - p0)).clamp(0.0, 1.0);
    final double slide = Curves.easeOut.transform(q);
    final double fade = Curves.easeOut.transform(
      (q / fadeSpan).clamp(0.0, 1.0),
    );
    return _HandoffVisual(
      x: _lerp(x, -sideOffset * direction * 1.15, slide),
      rotation: _lerp(rotation, -0.05 * direction * 1.15, slide),
      scale: _lerp(scale, 0.70, slide),
      opacity: opacity * (1 - fade),
    );
  }
}
