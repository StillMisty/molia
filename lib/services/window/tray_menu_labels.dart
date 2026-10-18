/// 桌面外壳菜单文案：托盘菜单项与 Windows 任务栏缩略图按钮共用
/// （组合根按当前界面语言解析后注入，语言切换时重新注入）。
///
/// 为什么不让托盘 / 任务栏服务直接持有 `AppLocalizations`：服务层保留「文案从
/// 哪来」的决定权在组合根，与播放控制项 / 收藏项的状态文案（播放⇄暂停、
/// 收藏⇄取消收藏）由服务按值切换保持同构。
class TrayMenuLabels {
  const TrayMenuLabels({
    required this.showWindow,
    required this.play,
    required this.pause,
    required this.previous,
    required this.next,
    required this.addFavorite,
    required this.removeFavorite,
    required this.quit,
  });

  final String showWindow;
  final String play;
  final String pause;
  final String previous;
  final String next;
  final String addFavorite;
  final String removeFavorite;
  final String quit;
}
