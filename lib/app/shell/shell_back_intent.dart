part of 'app_shell.dart';

/// 壳层级返回（Android back）与桌面 Esc 命令的单一实现。
///
/// 单独成 part：两条入口共用「播放器展开就先收起」的层级口径，但 Esc 还要
/// 先处理「关闭队列」命令；放进 `app_shell.dart` 会把壳层文件推过 800 行
/// 棘轮。part 共享 library 私有状态，行为与主文件内联完全一致。

extension _ShellBackIntent on _MyAppState {
  /// 壳层的层级返回（Android back / 桌面 Esc 共用一份判定）。
  ///
  /// 一级页（资料 / 发现、播放、收藏）按返回即退出应用，只有展开的播放器
  /// 需要壳层先收起；返回 false 表示「不再拦」，交给系统 pop。
  bool _handleShellBack() {
    if (_nowPlaying.expanded.value) {
      _requestPlayerExpansion(false);
      return true;
    }
    return false;
  }

  /// Esc 落到「关闭队列」命令时的入口：队列命令优先，其次收起播放器。
  ///
  /// 在播放页且右栏停在队列时，Esc 依然是「收队列」（既有肌肉记忆）；队列
  /// 已收起时，展开态再收起成 0 高度。其它一级页不再「回上一目的地」——一级页
  /// 返回就是退出，Esc 保持原命令落点（非播放页 no-op）。Esc 的占用登记
  /// （[EscapeClaims]）与可配置键位由 `desktop_shortcuts.dart` 在本回调之前
  /// 处理。
  void _handleShellBackCommand() {
    if (_effectiveDestination == ShellDestination.nowPlaying &&
        _nowPlaying.activeTab.value == nowPlayingQueueTabIndex) {
      _closeQueuePanel();
      return;
    }
    if (_nowPlaying.expanded.value) {
      _requestPlayerExpansion(false);
      return;
    }
    // 没有层级可退：保持原命令落点（播放页回默认歌词页；其它页 no-op）。
    _closeQueuePanel();
  }

  /// 壳层级返回拦截：只有「播放页展开」才拦，其余交还给系统 pop。
  ///
  /// 两层 PopScope 会同时收到回调（页面级多选 / 搜索、壳层级返回）：
  /// canPop 为 true（壳层不拦）时壳层只做 no-op，页面级拦截仍由页面自己
  /// 消费，不会把选择态一起导航走。
  Widget _withBackScope(Widget child) {
    final canLeave =
        !(_effectiveDestination == ShellDestination.nowPlaying &&
            _nowPlaying.expanded.value);
    return PopScope(
      // 测试据此读取 canPop，断言「一级页允许系统退出」。
      key: const Key('shellBackScope'),
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 页面级 PopScope（多选 / 搜索 / 排序）也收到同一次回调，且返回
        // 值无法裁决：有登记方时壳层让位，由页面消费这次返回。
        if (BackClaims.any) return;
        _handleShellBack();
      },
      child: child,
    );
  }
}
