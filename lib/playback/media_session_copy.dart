/// 系统媒体会话的本地化文案快照。
///
/// handler 不再读全局 `LanguageService.localeNotifier`：组合根解析当前界面
/// 语言后把 [MediaSessionCopy] 经 `ValueListenable` 注入，语言切换由来源通知
/// handler 重发通知动作文案。测试因此可以注入任意语言的普通值。
library;

import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';

/// 通知 / 锁屏上会出现的全部文案（元数据回退 + 两个自定义动作）。
class MediaSessionCopy {
  const MediaSessionCopy({
    required this.unknownArtist,
    required this.favoriteAdd,
    required this.favoriteRemove,
    required this.playModeListLoop,
    required this.playModeSequential,
    required this.playModeSingleRepeat,
    required this.playModeShuffle,
  });

  /// 从生成的 l10n 取词：唯一来源是 `AppLocalizations`（不新增键）。
  factory MediaSessionCopy.of(AppLocalizations l10n) => MediaSessionCopy(
        unknownArtist: l10n.unknownArtist,
        favoriteAdd: l10n.favoriteAdd,
        favoriteRemove: l10n.favoriteRemove,
        playModeListLoop: l10n.playModeListLoop,
        playModeSequential: l10n.playModeSequential,
        playModeSingleRepeat: l10n.playModeSingleRepeat,
        playModeShuffle: l10n.playModeShuffle,
      );

  /// 歌手为空时的回退文案（替代 handler 里硬编码的「未知歌手」）。
  final String unknownArtist;

  final String favoriteAdd;
  final String favoriteRemove;

  final String playModeListLoop;
  final String playModeSequential;
  final String playModeSingleRepeat;
  final String playModeShuffle;

  /// 收藏动作文案：反映当前收藏态（点按是反向操作）。
  String favoriteLabel({required bool favorite}) =>
      favorite ? favoriteRemove : favoriteAdd;

  /// 播放顺序动作文案：反映当前模式（点按循环到下一个）。
  String playModeLabel(PlayMode mode) => switch (mode) {
        PlayMode.listLoop => playModeListLoop,
        PlayMode.sequential => playModeSequential,
        PlayMode.singleRepeat => playModeSingleRepeat,
        PlayMode.shuffle => playModeShuffle,
      };
}
