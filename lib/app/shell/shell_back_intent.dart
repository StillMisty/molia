part of 'app_shell.dart';

/// 壳层级返回（Android back）与桌面 Esc 命令的单一实现。
///
/// 单独成 part：两条入口共用同一份「页面级占用优先」协议，但层级口径不同
/// ——系统返回在播放页的歌词整页状态先恢复完整播放页；Esc 仍先处理「关闭
/// 队列」命令。放进 `app_shell.dart` 会把壳层文件推过 800 行棘轮。part 共享
/// library 私有状态，行为与主文件内联完全一致。

extension _ShellBackIntent on _MyAppState {
  /// 壳层的层级返回（Android back）：裁决在展示模块，本方法只执行恢复动画。
  ///
  /// 三个底栏目的地（资料 / 发现、播放、收藏）都是平级一级页：正常播放页
  /// 与其它一级页返回即退出应用。唯一页内层级是播放页的歌词整页（播放器
  /// 高度 0），返回先恢复成正常播放页。页面级 `BackClaims` 优先也由模块统一
  /// 判定。返回 false 表示「不再拦」，交给系统 pop。
  bool _handleShellBack() {
    if (_presentation.handleBack(pageClaimsBack: BackClaims.any) !=
        ShellBackIntent.restorePlayer) {
      return false;
    }
    _requestPlayerExpansion(true);
    return true;
  }

  /// Esc 落到「关闭队列」命令时的入口：队列命令优先，其次收起播放器。
  ///
  /// 在播放页且右栏停在队列时，Esc 依然是「收队列」（既有肌肉记忆）；队列
  /// 已收起时，展开态再收起成 0 高度。其它一级页不再「回上一目的地」——一级页
  /// 返回就是退出，Esc 保持原命令落点（非播放页 no-op）。Esc 的占用登记
  /// （[EscapeClaims]）与可配置键位由 `desktop_shortcuts.dart` 在本回调之前
  /// 处理。桌面骨架没有歌词整页状态，本分支只在移动骨架挂载键盘时可达。
  void _handleShellBackCommand() {
    if (_presentation.state.effectiveDestination ==
            ShellDestination.nowPlaying &&
        _nowPlaying.activeTab.value == nowPlayingQueueTabIndex) {
      _closeQueuePanel();
      return;
    }
    if (_presentation.state.expanded) {
      _requestPlayerExpansion(false);
      return;
    }
    // 没有层级可退：保持原命令落点（播放页回默认歌词页；其它页 no-op）。
    _closeQueuePanel();
  }

  /// 壳层级返回拦截：只有「播放页歌词整页」才拦，其余交还给系统 pop。
  ///
  /// 两层 PopScope 会同时收到回调（页面级多选 / 搜索、壳层级返回）：
  /// canPop 为 true（壳层不拦）时壳层只做 no-op，页面级拦截仍由页面自己
  /// 消费，不会把选择态一起导航走。
  Widget _withBackScope(Widget child) {
    return PopScope(
      // 测试据此读取 canPop，断言「一级页允许系统退出」。
      key: const Key('shellBackScope'),
      canPop: !_presentation.state.interceptsBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 页面级 PopScope（多选 / 搜索 / 排序）也收到同一次回调，且返回
        // 值无法裁决：有登记方时壳层让位，由页面消费这次返回（判定收在
        // ShellPresentation.handleBack 里）。
        _handleShellBack();
      },
      child: child,
    );
  }
}
