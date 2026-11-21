part of 'nowplaying.dart';

/// 播放页展开 / 收起与内容手势的处理器。
///
/// 单独成 part：这些方法只负责「把意图交给壳层」和「按壳层请求跑高度动画」，
/// 与页面版式 / tab 构建分开后主文件才守得住 800 行棘轮；part 共享 library
/// 私有状态，行为与内联完全一致。

extension _NowPlayingGestures on _NowPlayingState {
  /// 展开/收起切换：按当前进度过半决定方向。
  ///
  /// 不用落定状态（[_isMini]）判定：弹簧有容差拖尾，「落定回调」晚于视觉
  /// 落定约 0.35s，滚动到一半连点/到顶快速再拉会打进过期目标。
  void _toggleExpand() {
    // 宽版式 / 桌面版式没有收起态：圆点与内容下拉不应发出「点了没反应」
    // 的请求（壳层也会直接忽略）。
    if (!_miniCapable) return;
    HapticsService.lightImpact();
    _requestExpansion(_expandController.value < 0.5);
  }

  /// 页内手势入口的统一出口：把意图交给壳层，由它同时发起顶栏 ⇄ 播放页
  /// 的共享封面飞行。页面不自己起动画，避免飞行与页内运动各跑一套。
  ///
  /// 未挂壳层（单测直接挂页面）时退回本地动画；外部请求走
  /// [_animateExpansion]，不会回调这里，避免循环。
  void _requestExpansion(bool expand) {
    final notify = widget.onRequestExpansion;
    if (notify == null) {
      _animateExpansion(expand);
      return;
    }
    notify(expand);
  }

  /// 执行一次展开 / 收起动画（壳层请求的落点）。
  ///
  /// 展开开始就写 `_isMini = false`：壳层顶栏立刻让位，飞行副本在同一帧
  /// 承接封面；收起则等进度落到端点才算收起（顶栏播放条在飞行落点回来）。
  void _animateExpansion(bool expand) {
    if (expand) {
      _setMini(false);
      // _setMini 在「已经不是收起态」时会提前返回，但展开意图本身仍要立刻
      // 写回壳层：从其它一级页进入时页面原先可能停在展开态，壳层读到的
      // expanded 却是隐藏期间同步下来的 false，晚一帧会让顶栏闪一下播放条。
      _writeExpansion(_miniCapable);
    } else {
      // 无收起态（桌面 / 宽版式）不能把 _isMini 翻成 true：下一次返回会
      // 误以为有可收起高度。
      if (!_miniCapable) {
        _writeExpansion(false);
        return;
      }
    }
    final double target = expand ? 1.0 : 0.0;
    // 拖拽松手的当刻速度可能暂存在这里：壳层回发请求时交给弹簧续跑。
    final double velocity = _pendingExpansionVelocity;
    _pendingExpansionVelocity = 0;
    if (reduceMotionOf(context)) {
      // 减弱动效：展开 / 收起直接换态（弹簧参数本身不变，正常态仍续跑）。
      _expandController.value = target;
      return;
    }
    _expandController.animateTo(target, withVelocity: velocity);
  }

  /// 外部请求（[NowPlayingController]）：展开 / 收起与 tab 共用一个通知通道。
  ///
  /// 请求是动作不是状态：重复请求、请求当前页都照样处理（页面可能刚挂载，
  /// 用户也可能手动切走后再触发一次）。
  void _handleControllerRequest() {
    final controller = widget.controller;
    if (controller == null || !mounted) return;

    // 展开 / 收起意图优先：进入播放页时它常与「切歌词」同一次通知发出，
    // 页面应当先按展开态落位再切 tab。
    final bool? expansion = controller.takeExpansionRequest();
    if (expansion != null) {
      _animateExpansion(expansion);
    }

    // 展开请求与 tab 请求共用一次通知：只有 tab 版本前进才重放 tab，否则
    // 收起播放器会把上一次请求的页再切一遍。
    final bool hasTabRequest =
        controller.tabRequestVersion != _handledTabRequest;
    if (!hasTabRequest) return;
    _handledTabRequest = controller.tabRequestVersion;

    final int? requested = controller.requestedTab;
    if (requested == null) return;
    controller.activeTab.value = requested;

    if (_desktopTabs) {
      _selectDesktopTab(requested);
      return;
    }

    if (!_pageController.hasClients) {
      // 挂载了但还没布局（请求落在 initState 与首帧之间）：初始页已在
      // initState 取过，这里只兜一次帧末补跳。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(requested);
          _handleVisiblePageChanged(requested);
        }
      });
      return;
    }
    if (!_shellVisible) {
      // 隐藏页的 PageView 仍在树上（Offstage），animateToPage 会等 ticker
      // 恢复才走完，看起来像「卡住」；直接跳到目标页，回到前台就是终点。
      _pageController.jumpToPage(requested);
      _handleVisiblePageChanged(requested);
      return;
    }
    if (reduceMotionOf(context)) {
      // 减弱动效：tab 跳转直接换页，不做整段滑动。
      _pageController.jumpToPage(requested);
      _handleVisiblePageChanged(requested);
      return;
    }
    _pageController.animateToPage(
      requested,
      duration: M3EMotion.medium2,
      curve: M3EMotion.emphasizedDecelerate,
    );
  }

  /// 把「当前布局是否有收起态 + 实际是否展开」回写给壳层。
  ///
  /// 构建期只安排帧末写入：壳层展示模块收到回写会 setState，直接在本帧
  /// 通知会触发「构建中 markNeedsBuild」。
  void _syncExpanded() {
    final notify = widget.onExpansionChanged;
    if (notify == null) return;
    final bool expected = _shellVisible && _miniCapable && !_isMini;
    if (_reportedExpansion == expected) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.onExpansionChanged != notify) return;
      notify(expected);
      _reportedExpansion = expected;
    });
  }

  /// 把「当前布局是否有收起态」回写给壳层（构建期只安排帧末写入）。
  ///
  /// 壳层据此决定顶栏是播放条还是品牌位；宽版式 / 桌面版式不写 true，
  /// 否则会暴露一个点了也收不起来的播放条。
  void _syncMiniCapable() {
    final notify = widget.onMiniCapableChanged;
    if (notify == null) return;
    if (_reportedMiniCapable == _miniCapable) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.onMiniCapableChanged != notify) return;
      notify(_miniCapable);
      _reportedMiniCapable = _miniCapable;
    });
  }

  /// 立即回写展开态（动画落定 / 展开请求同步路径）：不走帧末排队。
  void _writeExpansion(bool value) {
    _reportedExpansion = value;
    widget.onExpansionChanged?.call(value);
  }

  /// 展开进度跨过阈值即同步展开态（视觉落定口径，不等弹簧容差拖尾）。
  void _handleExpandProgress() {
    final double progress = _expandController.value;
    if (progress >= 0.99) {
      _setMini(false);
    } else if (progress <= 0.01) {
      _setMini(true);
    }
  }

  void _setMini(bool mini) {
    if (_isMini == mini || !mounted) return;
    _applyMiniState(mini);
    // 动画落定的节点是壳层返回层级最可靠的信号：宽版式无收起态，隐藏页
    // 的展开态也不拦返回，两者都按「未展开」回写。
    //
    // 展开请求来自「即将进入播放页」时页面还没可见，此时不能按可见性把它
    // 压回 false——否则壳层会先显示顶栏播放条、下一帧再收起，闪一帧。
    _writeExpansion(_miniCapable && !mini);
  }

  /// 播放器区域跟手拖拽行程基准：约 0.6 个最大高度走完整段（一次拇指
  /// 上滑即可展开）；也是释放速度 → 进度域的换算基准。
  ///
  /// 收起高度为 0，行程就是完整高度的比例，不再扣页内迷你条。
  double get _expandDragExtent => max(200.0, _playerMaxHeight * 0.6);

  /// 播放器区域跟手拖拽：收起态上拉展开、播放器下拉收起（过半/甩动吸附）。
  void _handlePlayerDragUpdate(DragUpdateDetails details) {
    if (!_miniCapable) return;
    final double extent = _expandDragExtent;
    // 手指向上（dy 负）→ 展开。
    final double delta = -details.delta.dy / extent;
    _expandController.value = (_expandController.value + delta).clamp(0.0, 1.0);
  }

  void _handlePlayerDragEnd(DragEndDetails details) {
    if (!_miniCapable) {
      // 没有收起态时不能把播放器留在半截：任何残留进度直接弹回完整。
      _expandController.value = 1;
      return;
    }
    final double upVelocity = -(details.primaryVelocity ?? 0);
    // 位置 + 速度投影：快速甩动即使行程短也按方向吸附。
    final double projected = _expandController.value + upVelocity / 1800;
    HapticsService.lightImpact();
    final bool expand = projected >= 0.5;
    if (reduceMotionOf(context)) {
      // 减弱动效：松手直接吸附到终态，不跑弹簧。
      _expandController.value = expand ? 1.0 : 0.0;
      return;
    }
    // 松手后的吸附也交给壳层：展开 / 收起两端的封面飞行由壳层统一驱动，
    // 页面只按壳层回发的请求把进度续跑到终点。
    final double extent = _expandDragExtent;
    final double velocity = extent <= 0 ? 0 : upVelocity / extent;
    final notify = widget.onRequestExpansion;
    if (notify == null) {
      _expandController.animateTo(expand ? 1.0 : 0.0, withVelocity: velocity);
      return;
    }
    // 壳层会同步回发 expand / collapse 请求；_animateExpansion 在同一调用栈
    // 里消费这个速度。壳层忽略请求（飞行中 / 无收起态）时这里再清掉，避免
    // 把上一次拖拽的速度带给下一次点按。
    _pendingExpansionVelocity = velocity;
    notify(expand);
    _pendingExpansionVelocity = 0;
  }
}
