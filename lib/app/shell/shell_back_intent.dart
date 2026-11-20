part of 'app_shell.dart';

/// 壳层级返回（Android back / 桌面 Esc）的单一实现。
///
/// 单独成 part：这套判定同时服务两组入口（系统返回与可配置 Esc 命令），
/// 放进 `app_shell.dart` 会把壳层文件推过 800 行棘轮；part 共享 library
/// 私有状态，行为与主文件内联完全一致。

extension _ShellBackIntent on _MyAppState {
  /// 壳层的层级返回（Android back / 桌面 Esc 共用一份判定）。
  ///
  /// 顺序：展开的播放器 → 收起；非家目的地 → 回上一目的地；其余允许
  /// 系统 pop（由 PopScope.canPop 决定，这里返回 false 表示「不再拦」）。
  bool _handleShellBack() {
    if (_nowPlaying.expanded.value) {
      _nowPlaying.collapse();
      return true;
    }
    final nav = context.read<NavProvider>();
    final current = _effectiveDestination;
    if (current == nav.effectiveHomeDestination) return false;
    var target = _previousDestination;
    if (target == current || !nav.isVisible(target)) {
      target = nav.effectiveHomeDestination;
    }
    if (target == current) return false;
    _selectDestination(target);
    return true;
  }

  /// Esc 落到「关闭队列」命令时的入口：先走层级返回，队列命令仍保持优先。
  ///
  /// 在播放页且右栏停在队列时，Esc 依然是「收队列」（既有肌肉记忆）；队列
  /// 已收起或不在播放页时才回上一目的地。Esc 的占用登记（[EscapeClaims]）
  /// 与可配置键位由 `desktop_shortcuts.dart` 在本回调之前处理。
  void _handleShellBackCommand() {
    if (_effectiveDestination == ShellDestination.nowPlaying &&
        _nowPlaying.activeTab.value == nowPlayingQueueTabIndex) {
      _closeQueuePanel();
      return;
    }
    if (_handleShellBack()) return;
    // 没有层级可退（家页面且已收起）：保持原命令落点（非播放页 no-op）。
    _closeQueuePanel();
  }

  /// 壳层级返回拦截：只有「展开的播放器」或「非家目的地」才拦，
  /// 其余交还给系统 pop（家页面收起态按正常退出）。
  ///
  /// 两层 PopScope 会同时收到回调（页面级多选 / 搜索、壳层级返回）：
  /// canPop 为 true（壳层不拦）时壳层只做 no-op，页面级拦截仍由页面自己
  /// 消费，不会把选择态一起导航走。
  Widget _withBackScope(Widget child) {
    final nav = context.read<NavProvider>();
    final canLeave =
        _effectiveDestination == nav.effectiveHomeDestination &&
        !_nowPlaying.expanded.value;
    return PopScope(
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
