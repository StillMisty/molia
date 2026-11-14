/// 详情页共享封面头与「播放全部」分裂按钮。
///
/// 专辑 / 歌手 / 发现详情三页的 96dp 封面头结构相同，差异只有裁切形状、
/// 回退图标与查看器元数据；「播放全部」尾部菜单也只有「加入列表」可选。
/// 收在一处是为了让「有封面才可点 / 按 96dp 解码 / 查看器标题与保存基名」
/// 这份策略只有一份实现：各页自己写时，漏掉 `memCacheWidth` 或改错保存
/// 文件名只会出现在某一个入口，很难在视觉上发现。
/// 查看原图始终展示原图。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../services/haptics.dart';
import '../app_network_image.dart';
import '../cover_hero.dart';
import '../cover_tap_target.dart';
import '../cover_viewer.dart';
import 'detail_page_chrome.dart';

/// 头部封面裁切：方形（16 圆角缩略图）或圆形（歌手头像）。
enum DetailCoverShape { square, circle }

const double _coverSize = 96;
const double _squareRadius = 16;

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 详情页封面头：96dp 封面 + 标题 / 副标题 / 可选简介与行动。
///
/// [coverUrl] 为空时只显示 [fallbackIcon] 占位，不挂可点层；有封面时才用
/// [coverKey] 标记 [CoverTapTarget]，保持「无封面不可点查看器」的既有行为。
/// 查看器标题与语义标签统一取 l10n 的「封面」，调用方只提供副标题与保存基名。
class DetailCoverHeader extends StatelessWidget {
  const DetailCoverHeader({
    super.key,
    required this.coverUrl,
    required this.shape,
    required this.fallbackIcon,
    required this.coverKey,
    required this.title,
    required this.subtitle,
    this.description,
    this.action,
    this.viewerSubtitle,
    this.viewerFileNameBase,
    this.heroTag,
  });

  /// 已解析的封面地址；null / 空串走占位。
  final String? coverUrl;

  final DetailCoverShape shape;

  /// 无封面 / 加载失败时的占位图标（专辑 / 歌手 / 歌单各有一个）。
  final IconData fallbackIcon;

  /// 可点层的 key（三个入口的测试与自动化都按它定位）。
  final Key coverKey;

  final String title;

  /// 一行身份说明（歌手 · 年份 · 曲目数等，由调用方拼接）。
  final String subtitle;

  final String? description;

  /// 头部主行动（通常是 [DetailPlayAllSplitButton]）。
  final Widget? action;

  /// 查看器副标题；缺省与 [title] 相同（发现详情页的名称即页标题）。
  final String? viewerSubtitle;

  /// 查看器「保存原图」的文件名基名；缺省与 [viewerSubtitle] 相同。
  final String? viewerFileNameBase;

  /// 非空时封面参与路由共享元素（来源卡片用同一个 tag）。
  ///
  /// 专辑 / 歌手入口不传。
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final coverUrl = this.coverUrl;
    final hasCover = coverUrl != null && coverUrl.isNotEmpty;

    Widget artwork = DetailCoverArtwork(
      coverUrl: coverUrl,
      shape: shape,
      fallbackIcon: fallbackIcon,
      heroTag: heroTag,
    );

    if (hasCover) {
      final viewerSubtitle = this.viewerSubtitle ?? title;
      final fileNameBase = viewerFileNameBase ?? viewerSubtitle;
      artwork = CoverTapTarget(
        // key 只挂在可点层上：无封面时页面里不应出现这个入口。
        key: coverKey,
        size: _coverSize,
        // 交互层与裁切同形：圆形头像的触控高亮才不会被方形圆角切掉。
        borderRadius: shape == DetailCoverShape.circle
            ? BorderRadius.circular(_coverSize / 2)
            : BorderRadius.circular(_squareRadius),
        semanticLabel: l10n.openCoverFor(title),
        onPressed: () {
          HapticsService.lightImpact();
          unawaited(
            showCoverViewer(
              context,
              coverUrl: coverUrl,
              title: l10n.coverLabel,
              subtitle: viewerSubtitle,
              fileNameBase: fileNameBase,
            ),
          );
        },
        child: artwork,
      );
    }

    return DetailPageHeroHeader(
      artwork: artwork,
      title: title,
      subtitle: subtitle,
      description: description,
      action: action,
    );
  }
}

/// 详情页封面视觉：96dp 方 / 圆 + 占位 + 可选共享元素。
///
/// 详情页加载骨架与加载完成后的头部共用同一份尺寸 / 占位 / 解码口径；
/// 各写一份时 Hero 落位会看到圆角或占位图标跳变。
class DetailCoverArtwork extends StatelessWidget {
  const DetailCoverArtwork({
    super.key,
    required this.coverUrl,
    required this.shape,
    required this.fallbackIcon,
    this.heroTag,
  });

  final String? coverUrl;
  final DetailCoverShape shape;

  /// 无封面 / 加载失败时的占位图标。
  final IconData fallbackIcon;

  /// 非空时把封面包进路由共享元素（tag 由入口按内容 id 生成）。
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverUrl = this.coverUrl;
    final hasCover = coverUrl != null && coverUrl.isNotEmpty;
    final placeholder = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        fallbackIcon,
        size: 40,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    Widget artwork = SizedBox.square(
      dimension: _coverSize,
      child: hasCover
          ? AppNetworkImage(
              url: coverUrl,
              fit: BoxFit.cover,
              // 头部只有 96dp：按容器解码，避免把整张原图留在内存里。
              memCacheWidth:
                  (_coverSize * MediaQuery.devicePixelRatioOf(context)).round(),
              placeholder: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              errorWidget: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  fallbackIcon,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : placeholder,
    );
    artwork = switch (shape) {
      DetailCoverShape.square => ClipRRect(
        borderRadius: BorderRadius.circular(_squareRadius),
        child: artwork,
      ),
      DetailCoverShape.circle => ClipOval(child: artwork),
    };

    final heroTag = this.heroTag;
    if (heroTag == null) return artwork;
    return CoverHero(tag: heroTag, child: artwork);
  }
}

enum _PlayAllAction { shuffle, addToLibrary }

/// 详情页「播放全部」分裂按钮：主操作播放 / 尾部菜单随机播放、可选加入列表。
///
/// [onAddToLibrary] 为 null 时不渲染菜单项（发现详情的导入入口在 AppBar，
/// 头部不重复放）；菜单顺序固定为随机播放在前，避免三页各自排菜单。
class DetailPlayAllSplitButton extends StatelessWidget {
  const DetailPlayAllSplitButton({
    super.key,
    required this.onPlay,
    required this.onShuffle,
    this.onAddToLibrary,
  });

  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  /// 尾部菜单「加入列表」；null 时隐藏该项。
  final VoidCallback? onAddToLibrary;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final onAddToLibrary = this.onAddToLibrary;
    return M3ESplitButton<_PlayAllAction>(
      label: l10n.playAll,
      leadingIcon: Icons.play_arrow_rounded,
      style: M3EButtonStyle.filled,
      onPressed: onPlay,
      items: [
        M3ESplitButtonItem<_PlayAllAction>(
          value: _PlayAllAction.shuffle,
          child: Text(l10n.playAllShuffled),
        ),
        if (onAddToLibrary != null)
          M3ESplitButtonItem<_PlayAllAction>(
            value: _PlayAllAction.addToLibrary,
            child: Text(l10n.addToPlaylist),
          ),
      ],
      onSelected: (action) {
        switch (action) {
          case _PlayAllAction.shuffle:
            onShuffle();
          case _PlayAllAction.addToLibrary:
            onAddToLibrary?.call();
        }
      },
    );
  }
}
