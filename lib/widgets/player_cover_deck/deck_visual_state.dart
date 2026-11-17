/// 空闲视觉状态：中心同 id 换图与槽位身份交叉淡化。
///
/// 由 [DeckController] 组合持有；入口组件只在离散变化时 setState。所有时长
/// 与门控和原实现一致，这里只负责「什么时候开始淡化、淡出起点是谁」。
library;

import 'package:material_ui/material_ui.dart';

import '../../domain/models/playback.dart';
import '../../domain/models/track.dart';
import '../cover_appearance.dart' show trackKeyOf;

/// 中心换图 / 槽位身份淡化的控制器与身份跟踪。
class DeckVisualState {
  DeckVisualState({
    required this.slotIdentityFade,
    required this.artworkRefreshFade,
    required this.realCoverUrlOf,
    required this.onVisualsChanged,
    required Track? initialDisplayTrack,
  }) {
    // 中心换图的淡出起点必须是「挂载时正在展示的 URL」：首个快照若只补了
    // 封面 URL（同 id），syncCenterArtwork 才能识别为换图而不是首帧接管。
    _centerTrackId = trackKeyOf(initialDisplayTrack);
    _centerArtworkUrl = realCoverUrlOf(initialDisplayTrack);
    _animation = Listenable.merge([slotIdentityFade, artworkRefreshFade]);
    slotIdentityFade.addStatusListener(_handleSlotIdentityStatus);
    artworkRefreshFade.addStatusListener(_handleArtworkRefreshStatus);
  }

  final String? Function(Track?) realCoverUrlOf;
  final VoidCallback onVisualsChanged;

  final AnimationController slotIdentityFade;
  final AnimationController artworkRefreshFade;
  late final Listenable _animation;

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

  Listenable get animation => _animation;
  bool get slotIdentityAnimating => slotIdentityFade.isAnimating;
  double get slotIdentityValue => slotIdentityFade.value;
  double get artworkRefreshValue => artworkRefreshFade.value;
  bool get centerArtworkRefreshing => _centerArtworkRefreshing;
  String? get outgoingCenterArtworkUrl => _outgoingCenterArtworkUrl;
  Track? get leftSlotOutgoing => _leftSlotOutgoing;
  Track? get rightSlotOutgoing => _rightSlotOutgoing;

  /// 中心封面同 id、封面 URL 变化（音源补图）：以约 250ms 交叉淡化换图。
  ///
  /// 只在同一曲目 id 内换 URL 时触发；id 变化（切歌/对账落位）由切歌与校正
  /// 路径负责，这里只接管新身份、不播换图淡化。淡化起点必须在新 URL 渲染
  /// 之前把控制器归零，否则会先闪一帧新图再回跳旧图，因此放在这里而不是
  /// build。
  void syncCenterArtwork(Track? track, {required bool visible}) {
    final id = trackKeyOf(track);
    final url = realCoverUrlOf(track);
    if (id != _centerTrackId) {
      _centerTrackId = id;
      _centerArtworkUrl = url;
      _centerArtworkRefreshing = false;
      _outgoingCenterArtworkUrl = null;
      if (artworkRefreshFade.value != 1.0) artworkRefreshFade.value = 1.0;
      return;
    }
    if (url == _centerArtworkUrl) return;
    if (artworkRefreshFade.isAnimating || !visible) {
      // 不可见（或淡化中再次更新）：直接接管新 URL，不启动/重启动画。
      _centerArtworkUrl = url;
      return;
    }
    _outgoingCenterArtworkUrl = _centerArtworkUrl;
    _centerArtworkRefreshing = true;
    _centerArtworkUrl = url;
    artworkRefreshFade.value = 0;
    artworkRefreshFade.forward();
  }

  /// 空闲刷新：中心换图 + 左右槽位身份淡换。
  ///
  /// 门控由会话 / 进度控制器提供；中心换图与槽位淡换的起点都必须在渲染新
  /// 身份之前归零，否则会先闪一帧新内容再回跳。
  void refreshIdleVisuals(
    PlaybackSnapshot snapshot, {
    required Track? previous,
    required String? animatedTrackId,
    required bool sessionVisible,
    required bool sessionIdle,
    required bool progressAnimating,
  }) {
    final current = snapshot.current;
    final currentId = trackKeyOf(current);
    // 中心封面同 id、URL 变化（音源补图）：250ms 交叉淡化换图，不播切歌动画。
    // current 已变（切歌/清空）时由切歌与校正路径接管，不做换图淡化。
    if (currentId != null &&
        currentId == animatedTrackId &&
        currentId == _centerTrackId) {
      final url = realCoverUrlOf(current);
      if (url != _centerArtworkUrl) {
        if (!sessionVisible || artworkRefreshFade.isAnimating) {
          // 不可见（或淡化中再次更新）：直接接管新 URL，不启动/重启动画。
          _centerArtworkUrl = url;
        } else {
          _outgoingCenterArtworkUrl = _centerArtworkUrl;
          _centerArtworkRefreshing = true;
          _centerArtworkUrl = url;
          artworkRefreshFade.value = 0;
          onVisualsChanged();
          artworkRefreshFade.forward();
        }
      }
    }
    _refreshIdleSlots(
      snapshot,
      previous: previous,
      sessionVisible: sessionVisible,
      sessionIdle: sessionIdle,
      progressAnimating: progressAnimating,
    );
  }

  /// 空闲期槽位身份变化（加歌/删歌/开关随机导致上一首/下一首换人）：
  /// 以约 180ms 原位交叉淡化表达；身份变为空则淡出为空。
  ///
  /// 门控：只在会话 idle 且过渡动画已停下时接管——拖动/提交/校正期间槽位
  /// 身份由会话窗口负责，不得叠加。左槽身份取自会话（`previous`），与渲染
  /// 同源。
  void _refreshIdleSlots(
    PlaybackSnapshot snapshot, {
    required Track? previous,
    required bool sessionVisible,
    required bool sessionIdle,
    required bool progressAnimating,
  }) {
    if (!sessionIdle || progressAnimating) return;
    final left = previous;
    final right = snapshot.next;
    final bool leftChanged = _leftSlotShown?.id != left?.id;
    final bool rightChanged = _rightSlotShown?.id != right?.id;
    if (!leftChanged && !rightChanged) return;
    if (!sessionVisible) {
      // 不可见：身份直接对齐，不播淡化（避免回到播放页时补播）。
      if (leftChanged) {
        _leftSlotShown = left;
        _leftSlotOutgoing = null;
      }
      if (rightChanged) {
        _rightSlotShown = right;
        _rightSlotOutgoing = null;
      }
      onVisualsChanged();
      return;
    }
    if (slotIdentityFade.isAnimating) {
      // 淡化中身份再次变化：直接接管新身份（以当前透明度渲染），不重启动画
      // （重启动画会让已淡出的卡透明度回跳）。该侧若还没在淡出（另一侧先
      // 变化），补一个淡出起点：从当前透明度起步，避免直接硬切身份。
      if (leftChanged) {
        _leftSlotOutgoing ??= _leftSlotShown;
        _leftSlotShown = left;
      }
      if (rightChanged) {
        _rightSlotOutgoing ??= _rightSlotShown;
        _rightSlotShown = right;
      }
      onVisualsChanged();
      return;
    }
    if (leftChanged) {
      _leftSlotOutgoing = _leftSlotShown;
      _leftSlotShown = left;
    }
    if (rightChanged) {
      _rightSlotOutgoing = _rightSlotShown;
      _rightSlotShown = right;
    }
    slotIdentityFade.value = 0;
    onVisualsChanged();
    slotIdentityFade.forward();
  }

  /// 会话结束/稳态帧：把槽位身份跟踪对齐到快照（并清掉淡出中的旧身份）。
  ///
  /// 会话窗口（切歌/对账）已经把槽位身份演到位，直接接管不补淡换；空闲期
  /// 后续的变化才会以控制器之外的淡换表达。
  void adoptSteadySlots({required Track? previous, required Track? next}) {
    // 身份淡换进行中不叠加接管（下一次稳态帧自然对齐）。
    if (slotIdentityFade.isAnimating) return;
    _leftSlotShown = previous;
    _rightSlotShown = next;
    _leftSlotOutgoing = null;
    _rightSlotOutgoing = null;
  }

  /// 全部动画立即落位到稳态；中心身份接管 [adoptTrack]。
  void hardReset(Track? adoptTrack) {
    slotIdentityFade.value = 1.0;
    artworkRefreshFade.value = 1.0;
    _centerArtworkRefreshing = false;
    _outgoingCenterArtworkUrl = null;
    _leftSlotOutgoing = null;
    _rightSlotOutgoing = null;
    _centerTrackId = trackKeyOf(adoptTrack);
    _centerArtworkUrl = realCoverUrlOf(adoptTrack);
  }

  void _handleArtworkRefreshStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!_centerArtworkRefreshing) return;
    _centerArtworkRefreshing = false;
    onVisualsChanged();
  }

  void _handleSlotIdentityStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_leftSlotOutgoing == null && _rightSlotOutgoing == null) return;
    _leftSlotOutgoing = null;
    _rightSlotOutgoing = null;
    onVisualsChanged();
  }

  /// 只解除监听；控制器本体由 [DeckController] 持有并释放。
  void dispose() {
    slotIdentityFade.removeStatusListener(_handleSlotIdentityStatus);
    artworkRefreshFade.removeStatusListener(_handleArtworkRefreshStatus);
  }
}
