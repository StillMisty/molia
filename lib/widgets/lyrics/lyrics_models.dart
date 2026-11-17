/// 歌词页内部模型：快捷动作与行角色（纯 Dart，可单测）。
library;

/// 歌词页 FAB 的固定动作序列（顺序即展示顺序）。
///
/// 前四项恒定：换源 / 复制歌词 / 歌词海报 / 显示设置。用户手动滚动后
/// 「居中当前行」只能追加在末尾——固定项不因歌词有无、是否本地曲目而增删，
/// 菜单位置才不会随状态跳来跳去。
enum LyricsQuickAction {
  swapSource,
  copyLyrics,
  poster,
  displaySettings,
  centerCurrentLine,
}

/// 按状态计算 FAB 动作：前四项恒定，「居中当前行」只作为第五项追加。
List<LyricsQuickAction> lyricsQuickActionOrder({
  required bool hasLyrics,
  required bool synced,
  required bool autoScroll,
}) {
  return [
    LyricsQuickAction.swapSource,
    LyricsQuickAction.copyLyrics,
    LyricsQuickAction.poster,
    LyricsQuickAction.displaySettings,
    if (hasLyrics && synced && !autoScroll) LyricsQuickAction.centerCurrentLine,
  ];
}

/// 歌词行在页面上的视觉角色（正文 / 已唱 / 当前 / 未唱）。
///
/// 颜色与不透明度都从这里派生：未同步歌词没有「当前」语义，统一按正文显示。
enum LyricsLineRole { unsynced, past, current, upcoming }

/// 按同步状态与行位置判定视觉角色。
LyricsLineRole lyricsLineRole({
  required bool synced,
  required bool isPast,
  required bool isCurrent,
}) {
  if (!synced) return LyricsLineRole.unsynced;
  if (isPast) return LyricsLineRole.past;
  if (isCurrent) return LyricsLineRole.current;
  return LyricsLineRole.upcoming;
}

/// 行内容不透明度：当前行与未同步歌词保持全亮，其余降低一档。
double lyricsLineOpacity(LyricsLineRole role) => switch (role) {
  LyricsLineRole.current || LyricsLineRole.unsynced => 1.0,
  LyricsLineRole.past || LyricsLineRole.upcoming => 0.8,
};

/// 歌词主字号：宽版式与窄版式两档。
double lyricsLineFontSize({required bool wideLayout}) =>
    wideLayout ? 24.0 : 22.0;
