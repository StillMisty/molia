/// 单行歌词：角色颜色 / 当前行强调 / 逐字高亮与扩展行组合。
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/lyric_line.dart';
import '../lyric_karaoke_text.dart';
import '../../services/lyrics_display/lyric_timing_policy.dart';
import 'lyrics_controls.dart';
import 'lyrics_models.dart';

/// 一行歌词（含翻译 / 罗马音扩展行）。
///
/// 行样式必须从环境样式派生：AnimatedDefaultTextStyle 是「替换」而不是合并
/// （内部直接 `DefaultTextStyle(style: …)`，见 SDK implicit_animations.dart），
/// 写字面量会把字体族一并丢成引擎默认字体——设置页选的「应用字体」会在
/// 整段歌词行失效。这里只覆盖字号/字重/颜色/行高，其余继续继承主题。
class LyricsLineTile extends StatelessWidget {
  const LyricsLineTile({
    super.key,
    required this.lineKey,
    required this.textKey,
    required this.line,
    required this.isSynced,
    required this.isPastLine,
    required this.isCurrentLine,
    required this.active,
    required this.copyMode,
    required this.wideLayout,
    required this.showTranslation,
    required this.translation,
    required this.showRoma,
    required this.roma,
    required this.effectDuration,
    required this.position,
    required this.onTap,
  });

  /// 整项 key（点行 seek / 命中判定）。
  final GlobalKey lineKey;

  /// 主行文本块 key（自动滚动锚定）。
  final GlobalKey textKey;

  final LyricLine line;
  final bool isSynced;
  final bool isPastLine;
  final bool isCurrentLine;
  final bool active;
  final bool copyMode;
  final bool wideLayout;
  final bool showTranslation;
  final String translation;
  final bool showRoma;
  final String roma;
  final Duration effectDuration;
  final ValueListenable<Duration> position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final LyricsLineRole lineRole = lyricsLineRole(
      synced: isSynced,
      isPast: isPastLine,
      isCurrent: isCurrentLine,
    );
    // 歌词行角色契约：正文用 onSurface/onSurfaceVariant，仅当前行用 primary
    // 强调（全页唯一强调色）。
    final Color baseTextColor = switch (lineRole) {
      LyricsLineRole.unsynced ||
      LyricsLineRole.upcoming => theme.colorScheme.onSurface,
      LyricsLineRole.past => theme.colorScheme.onSurfaceVariant,
      LyricsLineRole.current => theme.colorScheme.primary,
    };
    final double lyricFontSize = lyricsLineFontSize(wideLayout: wideLayout);
    // 扩展行样式：字号对齐桌面歌词规格（主字号 × 0.8），颜色保持行角色
    // 契约的次要文本，不参与 primary 强调。
    final TextStyle extendedLineStyle = TextStyle(
      fontSize: lyricFontSize * 0.8,
      fontWeight: FontWeight.w500,
      color: theme.colorScheme.onSurfaceVariant,
    );
    // 逐字渲染：仅当前行 + 有词时间轴 + 非复制模式；已唱/未唱用
    // primary/onSurface 双色，行级强调由词高亮表达。
    final List<LyricWord>? lineWords = line.words;
    final bool useKaraoke =
        active &&
        isCurrentLine &&
        !copyMode &&
        lineWords != null &&
        lineWords.isNotEmpty;

    return GestureDetector(
      key: lineKey,
      onTap: onTap,
      child: AnimatedPadding(
        duration: effectDuration,
        curve: M3EMotion.emphasizedDecelerate,
        padding: EdgeInsets.symmetric(
          vertical: isCurrentLine ? 12.0 : 8.0,
          // 宽版式（桌面右栏 / 平板两栏）与队列、详情同一内容边距（16，
          // M3E 口径）；窄版式保持歌词行特有的 40。
          horizontal: wideLayout ? 16.0 : 40.0,
        ),
        child: AnimatedDefaultTextStyle(
          duration: effectDuration,
          curve: M3EMotion.emphasizedDecelerate,
          style: DefaultTextStyle.of(context).style.copyWith(
            fontSize: lyricFontSize,
            // M3E 没有 w600 档：当前行 w700、其余 w500，
            // 保留「高亮行更重」的两级对照（原来 w700/w600）。
            fontWeight: isCurrentLine ? FontWeight.w700 : FontWeight.w500,
            color: baseTextColor,
            height: 1.1,
          ),
          child: AnimatedOpacity(
            duration: effectDuration,
            curve: M3EMotion.emphasizedDecelerate,
            opacity: lyricsLineOpacity(lineRole),
            child: Semantics(
              // 行是阅读单位：逐字高亮只影响绘画，不做逐词语义；
              // 自动滚动不请求焦点，也不把行标成 live region。
              container: true,
              excludeSemantics: true,
              label: line.text,
              selected: isCurrentLine,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (useKaraoke)
                    KaraokeLyricText(
                      key: textKey,
                      words: lineWords,
                      position: position,
                      lead: kLyricDisplayLead,
                      playedColor: theme.colorScheme.primary,
                      unplayedColor: theme.colorScheme.onSurface,
                    )
                  else
                    Text(line.text, key: textKey, textAlign: TextAlign.left),
                  // 翻译 / 罗马音：空文本不占位；顺序与 LyricLineTracker 的
                  // 扩展行拼接一致。逐行渲染，与主行一起滚动；歌词页开关
                  // 切换时展开 / 收起。
                  LyricsExtendedLines(
                    showTranslation: showTranslation,
                    translation: translation,
                    showRoma: showRoma,
                    roma: roma,
                    style: extendedLineStyle,
                    // 只有当前行（且页面活跃）做展开 / 收起：否则切换翻译
                    // 开关时几十行 SizeTransition 同时跑。
                    animate: active && isCurrentLine,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
