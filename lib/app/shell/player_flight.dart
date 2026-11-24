part of 'app_shell.dart';

/// 顶栏播放条 / 播放页展开态与共享封面飞行的状态机。
///
/// 单独成 part：这里同时服务「进入 / 离开播放页」和「播放页内部展开 / 收起」
/// 两组入口，但它们必须共用同一套锚点、弹簧与 `PlayerMorphFlight` 副本——
/// 分成两个文件各写一份必然漂移；放在主文件又把壳层推过 800 行棘轮。
/// part 共享 library 私有状态，行为与内联完全一致。

extension _ShellPlayerFlight on _MyAppState {
  /// 顶栏 → 播放页的飞行：起点与终点分两帧抓。
  ///
  /// 起点（顶栏封面）只在点击这一帧存在——顶栏播放条在进入播放页后让位，
  /// 重建后就没了；终点（页内封面）恰恰相反——让位使内容区高 +80，页内封面
  /// 随垂直居中下移，重建前的矩形不是落点。因此本帧抓起点、先把两端封面
  /// 收进飞行态（避免真身与副本同帧重影），帧末（让位后的布局已成立）抓
  /// 终点再起飞：副本飞行终点就是真身的实际落点，交接帧零位移。
  ///
  /// 「已在播放页、从收起态就地展开」同样走这里：目的地检查共用，同一帧内
  /// 又切走时 post-frame 会放弃这次飞行（否则副本会飞向已经不可见的页）。
  void _startMorphToPage() {
    _completeMorph();
    final barCover = _morph.rectOf(_morph.barCoverKey);
    if (barCover == null) {
      // 起点不在场（启动就落在播放页等）：跳过飞行，只对齐两端状态。
      _alignMorphEnds(onPlayerPage: true);
      return;
    }
    _morph.setBarHeaderHidden(true);
    _morph.setPageHeaderHidden(true);
    // 进入首帧页中心就收起（飞行副本承接），侧邻位收回中心等飞行尾段展开。
    _morph.setPageDeckReveal(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_presentation.effectiveDestination != ShellDestination.nowPlaying) {
        // 一帧之内又离开了播放页：这次进入被撤销，两端状态按「不在播放页」
        // 对齐（两端真身都可见、侧槽落位）。
        _alignMorphEnds(onPlayerPage: false);
        return;
      }
      final pageCover = _morph.rectOf(_morph.pageCoverKey);
      if (pageCover == null) {
        // 终点不可用：不飞，页内封面与侧槽直接亮出（顶栏/底栏这一端不在场，
        // 无重影）。
        _alignMorphEnds(onPlayerPage: true);
        return;
      }
      _flyMorph(
        PlayerMorphGeometry(
          barCover: barCover,
          pageCover: pageCover,
          toPage: true,
        ),
      );
    });
  }

  /// 播放页 → 顶栏的飞行：顶栏播放条在展开态整条让位，锚点要等它回到树里
  /// 才有。
  ///
  /// 本帧先让顶栏复位、并把两端封面收进飞行态（顶栏封面出现时就是空位，
  /// 下一帧副本从同一位置起飞，接得上）；帧末（顶栏已完成布局）抓两端锚点、
  /// 再下一帧起飞——代价是飞行比切页晚一帧（16ms），肉眼不可辨。
  ///
  /// [destinationChanged] = false 用于「播放页内部收起」：目的地仍是播放页，
  /// 不能按「又回到播放页」撤销这次飞行。
  void _startMorphBackToBar({bool destinationChanged = true}) {
    _morph.setBarHeaderHidden(true);
    // 离开方向也从第一帧起收起页中心：飞行副本接管整段行程，页面真身
    // 不能先在原地亮着等副本飞过来。
    _morph.setPageHeaderHidden(true);
    // 侧邻位从稳态开始；飞行前 45% 由 tick 时间对称地收回中心。
    _morph.setPageDeckReveal(1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (destinationChanged &&
          _presentation.effectiveDestination == ShellDestination.nowPlaying) {
        // 一帧之内又回到播放页：这次离开被撤销，状态按「在播放页」对齐
        // （顶栏封面仍收起，与启动就落在播放页时同一口径）。
        _alignMorphEnds(onPlayerPage: true);
        return;
      }
      _completeMorph();
      final geometry = _morph.captureGeometry(toPage: false);
      if (geometry == null) {
        // 锚点缺失（收起态/首帧）：跳过飞行，两端真身可见。
        _alignMorphEnds(onPlayerPage: false);
        return;
      }
      _flyMorph(geometry);
    });
  }

  /// 起飞：两端封面的显示状态 + Overlay 副本 + 弹簧。
  ///
  /// 封面 URL 与锚点在同一刻抓取：飞行期间不换图（副本承接的是起飞时那一张）。
  void _flyMorph(PlayerMorphGeometry geometry) {
    _morph.setBarHeaderHidden(true);
    // 两个方向都收起页中心：副本精确承接整段几何，真身不参与飞行（进入时
    // 首帧就不能亮，离开时也不能留到最后才收）。
    _morph.setPageHeaderHidden(true);
    _morphGeometry = geometry;
    _presentation.setFlightInProgress(true);
    final url = nowPlayingCoverUrl(
      context,
      ref.read(playbackControllerProvider),
    );
    final token = ++_morphToken;
    _morphEntry = OverlayEntry(
      builder: (context) => PlayerMorphFlight(
        animation: _morphAnimation,
        geometry: geometry,
        url: url,
        fallback: (context, iconSize) =>
            buildFallbackArtwork(context, iconSize: iconSize),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_morphEntry!);
    // 弹簧从起点跑满全程；落定帧由 [_onMorphTick] 完成交接（whenComplete
    // 只是兜底：中途被新飞行接管会被取消，不触发）。
    _morphAnimation.animateTo(1, from: 0, withVelocity: 0).whenComplete(() {
      if (!mounted || token != _morphToken) return;
      _completeMorph();
    });
  }

  /// 飞行到达（[PlayerMorphFlight.flightPortion]）即在同一帧完成交接：
  /// 先亮出目标端真身、再移除飞行副本，两端封面位置完全一致，无尾段闪烁。
  ///
  /// `snapToEnd` 保证最后一步 value 精确为 1.0，此处即落定帧（零速度）。
  void _onMorphTick() {
    final geometry = _morphGeometry;
    if (geometry == null) return;
    final double progress = _morphAnimation.value.clamp(0.0, 1.0);
    // 侧邻位进入时尾段展开 / 离开时前段收回（不新增 ticker，复用同一条弹簧）。
    _morph.setPageDeckReveal(
      PlayerMorphController.pageDeckRevealAt(progress, toPage: geometry.toPage),
    );
    if (progress >= PlayerMorphFlight.flightPortion) {
      _completeMorph();
    }
  }

  void _removeMorphOverlay() {
    _morphEntry?.remove();
    _morphEntry = null;
  }

  void _completeMorph() {
    _morphToken++;
    final geometry = _morphGeometry;
    _morphGeometry = null;
    _presentation.setFlightInProgress(false);
    // 失败 / 落定都回到稳态展开：落位帧副本移除、真身与侧槽同一帧就位。
    _morph.setPageDeckReveal(1);
    if (geometry == null) {
      _removeMorphOverlay();
      return;
    }
    // 落位：目标端真身瞬时亮出（零时长 Opacity），同一帧移除飞行副本；
    // 播放页激活时顶栏收起（内容由页面承接）。
    _morph.setPageHeaderHidden(false);
    _morph.setBarHeaderHidden(geometry.toPage);
    _removeMorphOverlay();
  }
}
