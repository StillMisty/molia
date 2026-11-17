/// 歌词页的轻量控件：加载 / 空态、扩展行（翻译 / 罗马音）与快捷操作项。
///
/// 这些组件只负责渲染与手势回调；跟随时机在 `lyrics_view_session.dart`，
/// 滚动几何在 `lyrics_scroll.dart`，页面组合在 `lyrics_view.dart`。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/motion_policy.dart';
import 'lyrics_models.dart';

/// 取词中的占位：小进度环 + 文案。
class LyricsLoadingState extends StatelessWidget {
  const LyricsLoadingState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: M3EProgressIndicator.circular(size: 24, strokeWidth: 2.5),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态（取词失败 / 没找到词）：俏皮话提示，动作由 FAB menu 承担。
class LyricsEmptyState extends StatelessWidget {
  const LyricsEmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 翻译 / 罗马音块（挂在主行文本下方，逐行渲染）。
///
/// 通过 [AnimatedSwitcher] + `SizeTransition` 做「淡出 + 收起」：歌词页
/// 开关切换（翻译 / 罗马音开或关）时扩展行从主行下方展开 / 收起，
/// 而不是硬切、也不是留下占位。
///
/// [animate] 只为当前行打开：其余行零时长直接切换，避免开关一次让
/// 几十行 SizeTransition 同时跑（列表越大越明显）。
class LyricsExtendedLines extends StatelessWidget {
  const LyricsExtendedLines({
    super.key,
    required this.showTranslation,
    required this.translation,
    required this.showRoma,
    required this.roma,
    required this.style,
    required this.animate,
  });

  final bool showTranslation;
  final String translation;
  final bool showRoma;
  final String roma;
  final TextStyle style;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final bool visible = showTranslation || showRoma;
    return AnimatedSwitcher(
      duration: animate
          ? effectDurationOf(context, M3EMotion.short4)
          : Duration.zero,
      switchInCurve: M3EMotion.emphasizedDecelerate,
      switchOutCurve: M3EMotion.emphasizedAccelerate,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topLeft,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topLeft,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: !visible
          ? const SizedBox.shrink(key: ValueKey<String>('lyricsExtendedNone'))
          : Column(
              key: const ValueKey<String>('lyricsExtendedLines'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showTranslation) ...[
                  const SizedBox(height: 2),
                  Text(translation, textAlign: TextAlign.left, style: style),
                ],
                if (showRoma) ...[
                  const SizedBox(height: 2),
                  Text(roma, textAlign: TextAlign.left, style: style),
                ],
              ],
            ),
    );
  }
}

/// FAB menu 项（歌词域操作）：换源 / 复制歌词 / 歌词海报 / 显示设置
/// 四项固定顺序；手动滚动暂停跟随时末尾追加「居中当前行」。
///
/// 文案统一取「动作 + 对象」的短名（3–6 字）：胶囊宽度随文案生长 + 右缘对齐，
/// 长短悬殊时一眼就能看出参差，所以海报入口用「歌词海报」而不是整句说明。
///
/// `M3EFabMenu` 要求 2–6 项：固定四项已满足下限，条件项只追加不替换，
/// 菜单的前四项在任何状态下都不变。
List<M3EFabMenuItem> buildLyricsQuickActionItems({
  required AppLocalizations l10n,
  required bool hasLyrics,
  required bool synced,
  required bool following,
  required bool copyMode,
  required VoidCallback onSwapSource,
  required VoidCallback onToggleCopyMode,
  required VoidCallback onPoster,
  required VoidCallback onDisplaySettings,
  required VoidCallback onCenterCurrentLine,
}) {
  return [
    for (final action in lyricsQuickActionOrder(
      hasLyrics: hasLyrics,
      synced: synced,
      autoScroll: following,
    ))
      _quickActionItem(
        action,
        l10n: l10n,
        copyMode: copyMode,
        onSwapSource: onSwapSource,
        onToggleCopyMode: onToggleCopyMode,
        onPoster: onPoster,
        onDisplaySettings: onDisplaySettings,
        onCenterCurrentLine: onCenterCurrentLine,
      ),
  ];
}

M3EFabMenuItem _quickActionItem(
  LyricsQuickAction action, {
  required AppLocalizations l10n,
  required bool copyMode,
  required VoidCallback onSwapSource,
  required VoidCallback onToggleCopyMode,
  required VoidCallback onPoster,
  required VoidCallback onDisplaySettings,
  required VoidCallback onCenterCurrentLine,
}) {
  switch (action) {
    case LyricsQuickAction.swapSource:
      // 换源：歌词页的快捷入口（信息页歌词来源行是数据面入口）。
      return M3EFabMenuItem(
        icon: const Icon(Icons.swap_horiz_rounded),
        label: l10n.lyricsSwapAction,
        onPressed: onSwapSource,
      );
    case LyricsQuickAction.copyLyrics:
      return M3EFabMenuItem(
        icon: Icon(
          copyMode ? Icons.playlist_play_rounded : Icons.edit_note_rounded,
        ),
        label: copyMode ? l10n.lyricsCopyModeExit : l10n.lyricsCopyModeAction,
        onPressed: onToggleCopyMode,
      );
    case LyricsQuickAction.poster:
      return M3EFabMenuItem(
        icon: const Icon(Icons.checklist_rounded),
        label: l10n.lyricsPosterAction,
        onPressed: onPoster,
      );
    case LyricsQuickAction.displaySettings:
      return M3EFabMenuItem(
        icon: const Icon(Icons.tune_rounded),
        label: l10n.lyricsDisplaySettingsAction,
        onPressed: onDisplaySettings,
      );
    case LyricsQuickAction.centerCurrentLine:
      return M3EFabMenuItem(
        icon: const Icon(Icons.vertical_align_center_rounded),
        label: l10n.centerCurrentLine,
        onPressed: onCenterCurrentLine,
      );
  }
}
