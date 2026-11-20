/// 播放页封面的读屏语义：中心封面是播放 / 暂停，邻位封面是上一首 / 下一首。
///
/// 单独一层的原因：点封面的动作与封面所在版式无关（迷你条封面 = 打开播放页，
/// 播放页中心封面 = 播放 / 暂停），标签必须与实际点击结果一致；播放态又在
/// `Player` 的 build 订阅之外（只订阅当前曲目），只能由本组件自己订阅。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';

/// AppLocalizations 查找：与播放器其它行组件同一约定，未注册 delegate 时
/// 回退简体中文。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 播放页中心封面：语义是「播放 / 暂停 + 曲名」的按钮。
///
/// 这里刻意不标 `image`：读屏用户听到的是可执行动作，而不是一张图。
class PageCoverSemantics extends StatelessWidget {
  const PageCoverSemantics({
    super.key,
    required this.track,
    required this.child,
  });

  /// 当前展示曲目（封面缺省时只读出「封面」）。
  final Track? track;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isPlaying = context.select<PlaybackProvider, bool>(
      (provider) => provider.isPlaying,
    );
    final l10n = _l10n(context);
    final track = this.track;
    final String label = track == null
        ? l10n.coverLabel
        : '${isPlaying ? l10n.pause : l10n.play} · ${track.title}';
    return Semantics(button: true, label: label, child: child);
  }
}

/// 迷你条封面：语义仍是「打开播放页 + 曲名」（点击整条即展开）。
class MiniCoverSemantics extends StatelessWidget {
  const MiniCoverSemantics({
    super.key,
    required this.track,
    required this.child,
  });

  final Track? track;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final track = this.track;
    return Semantics(
      image: true,
      label: track == null ? l10n.coverLabel : l10n.openPlayerFor(track.title),
      child: child,
    );
  }
}
