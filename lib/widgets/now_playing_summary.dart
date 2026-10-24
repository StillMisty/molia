/// 当前曲目摘要（封面 / 歌名作者 / 收藏）的共享契约。
///
/// 顶栏、桌面底栏与播放页此前各自手抄同一份摘要：封面外观与有界解码、
/// 播放页激活时的隐藏语义、歌名/作者字阶与无曲目回退、收藏图标与写入路径。
/// 三处靠注释约定「改契约时同步」，任何一处漏改都会让同一曲目在不同宿主
/// 长得不一样。
///
/// 这里把契约收口成四个小模块，宿主只保留版式与交互位置：
/// - [NowPlayingCover]：封面卡 + 共享飞行锚点 + 隐藏不透明度；
/// - [NowPlayingTrackText]：迷你位（顶栏 / 底栏）与播放页两种标题版式；
/// - [NowPlayingFavoriteButton]：图标态即反馈，写路径唯一；
/// - [NowPlayingSummary]：标准「封面 + 12dp + 文本 [+ 尾部槽]」排布。
///
/// 传输控件刻意不在这里合并：三处的按钮数量、档位与布局都不同（顶栏只有
/// 下一首、底栏带进度排、播放页带音量与更大的播放键），强行共用会把版式
/// 差异变成参数。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/app_branding_service.dart';
import '../services/covers/custom_cover_store.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../utils/playback_cover_decode.dart';
import 'app_network_image.dart';
import 'cover_appearance.dart';
import 'favorite_action.dart';
import 'icon_swap.dart';

/// 当前曲目封面地址：真身、飞行副本与预取共用的唯一取值。
///
/// 顶栏/底栏真身与共享飞行副本必须拿同一份 URL（空串视同无封面），否则
/// 飞行期间副本可能换成另一张图。
String? nowPlayingCoverUrl(PlaybackProvider provider) =>
    artworkUrlOf(provider.snapshot.current);

/// 当前曲目的封面卡：顶栏 / 桌面底栏的“迷你封面”唯一实现。
///
/// 隐藏语义与共享飞行绑定：播放页激活或飞行期间封面淡出，但两件事不能
/// 混在一次时长里——飞行落位帧必须与副本移除同帧亮出（亮出 0ms），收起
/// 方向才走 160ms 淡出，否则结束/开始两帧会看到重影或跳变。
class NowPlayingCover extends StatelessWidget {
  /// 跟随当前曲目（顶栏 / 桌面底栏的封面位）。
  const NowPlayingCover.current({
    super.key,
    required this.size,
    this.appearance = CoverAppearance.bar,
    this.flightKey,
    this.hidden = false,
  });

  /// 卡片边长（封面卡恒为方形）。
  final double size;

  /// 卡片外观；顶栏与底栏同用 [CoverAppearance.bar]。
  final CoverAppearance appearance;

  /// 顶栏 ↔ 播放页共享飞行的封面锚点（`PlayerMorphController.barCoverKey`）。
  ///
  /// key 必须落在实际参与布局的卡片上：飞行锚点按它的真实矩形抓取，不能
  /// 由外层包装层代替。
  final Key? flightKey;

  /// 是否处于隐藏态（播放页激活或飞行中）。
  final bool hidden;

  static const Duration _hideDuration = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    final covers =
        context.read<CustomCoverStore?>() ?? CustomCoverStore.instance;
    final track = context.select<PlaybackProvider, Track?>(
      (provider) => provider.snapshot.current,
    );
    return ValueListenableBuilder<int>(
      valueListenable: covers.revision,
      builder: (context, _, __) => AnimatedOpacity(
        // 落位方向必须同步亮出（与飞行副本移除同帧）；收起方向才做淡出。
        duration: hidden ? _hideDuration : Duration.zero,
        opacity: hidden ? 0 : 1,
        child: CoverCard(
          key: flightKey,
          size: size,
          appearance: appearance,
          content: (context, clip, iconSize) => AppNetworkImage(
            url: artworkUrlOf(track),
            borderRadius: clip,
            // 与飞行副本共用同一外观源（图标态飞行起点必须与真身同尺寸）。
            fallbackIconSize: iconSize,
            // 无封面 / 远端失败时先显示设置里的默认封面（Molia 标志兜底）。
            fallbackUrl: covers.defaultCoverUrl,
            // 与播放页 / 迷你条 / 预取共用同一个有界解码键：命中同一张已解码
            // 图，不在 40dp 顶栏里留一张原图。
            memCacheWidth: playbackCoverDecodeEdge(context),
          ),
        ),
      ),
    );
  }
}

/// 自定义应用名（设置页可改，未自定义时为 Molia）。
///
/// 顶栏曲目区的无曲目回退与「播放页激活」后的品牌位共用同一强调字阶，
/// 避免同一位置在两态之间换字号 / 字重。
class NowPlayingAppTitle extends StatelessWidget {
  const NowPlayingAppTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppBrandingService.titleNotifier,
      builder: (context, title, _) => Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.emphasizedTypeScale.titleMedium,
      ),
    );
  }
}

/// 当前曲目的歌名 + 作者文本块。
///
/// 两种版式各自封装一个宿主的完整契约，而不是把字阶 / 单双行拆成参数：
/// - [NowPlayingTrackText.bar]：顶栏与桌面底栏，跟随当前曲目、无曲目回退
///   应用名，歌名 titleMedium / 作者 labelSmall 两行；
/// - [NowPlayingTrackText.page]：播放页标题块，标题 / 作者由宿主给出
///   （播放页可回退最近播放），两行或单行「歌名 · 作者」。
///
/// 两态都只占一行、统一省略号截断：宿主给的是固定高度槽位，换行会把进度
/// 排或歌词区挤出可视区。
class NowPlayingTrackText extends StatelessWidget {
  /// 迷你位（顶栏 / 桌面底栏）。
  const NowPlayingTrackText.bar({super.key})
      : _bar = true,
        title = '',
        artist = '',
        stacked = true;

  /// 播放页标题块。
  const NowPlayingTrackText.page({
    super.key,
    required this.title,
    required this.artist,
    required this.stacked,
  }) : _bar = false;

  final bool _bar;

  /// 播放页版式的歌名（[NowPlayingTrackText.bar] 不使用）。
  final String title;

  /// 播放页版式的作者（[NowPlayingTrackText.bar] 不使用）。
  final String artist;

  /// true = 歌名 / 作者各占一行；false = 单行「歌名 · 作者」。
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    if (!_bar) return _buildPageText(context);

    final info = context.select<PlaybackProvider, (String?, String?)>(
      (provider) {
        final track = provider.snapshot.current;
        return (track?.title, track?.artistLabel);
      },
    );
    final (name, artists) = info;
    if (name == null || name.isEmpty) return const NowPlayingAppTitle();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          style: context.typeScale.titleMedium,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        if (artists != null && artists.isNotEmpty)
          Text(
            artists,
            style: context.typeScale.labelSmall,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
      ],
    );
  }

  /// 播放页标题块：强调字阶只给可交互控件之外的标题，作者走次级色。
  Widget _buildPageText(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = context.emphasizedTypeScale.titleLarge.copyWith(
      color: scheme.onSurface,
    );
    final artistStyle = context.typeScale.bodyMedium.copyWith(
      color: scheme.onSurfaceVariant,
    );

    if (stacked) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
          if (artist.isNotEmpty)
            Text(
              artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: artistStyle,
            ),
        ],
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title, style: titleStyle),
          if (artist.isNotEmpty)
            TextSpan(text: '  ·  $artist', style: artistStyle),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 当前曲目的收藏按钮：播放页 / 桌面底栏 / 播放页迷你条的唯一实现。
///
/// 反馈只靠图标态（已收藏 primary / 未收藏 onSurfaceVariant），不弹提示；
/// 写路径唯一 `LibraryProvider.toggleFavoriteTrack`，宿主不再各自拿仓库。
/// 没有资料库或当前曲目时整块隐藏（与旧实现一致）。
///
/// 尺寸仍由宿主给出：同一契约在底栏是 44 视觉格，播放页迷你条要缩到
/// 36/40，版式差异不属于契约。
///
/// 必须是独立组件而不是宿主内联方法：播放页在 `LayoutBuilder` 里构建进度排，
/// `context.select` 只能发生在组件自身 build 中（State.context 在布局阶段
/// 使用会被 provider 断言拦截）。
class NowPlayingFavoriteButton extends StatelessWidget {
  const NowPlayingFavoriteButton({
    super.key,
    this.size = M3EIconButtonSize.sm,
    this.visualSize,
  });

  final M3EIconButtonSize size;

  /// 视觉格覆盖；null = 交给 M3E 主题的档位默认值。
  final Size? visualSize;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider?>();
    final track = context.select<PlaybackProvider, Track?>(
      (provider) => provider.snapshot.current,
    );
    if (library == null || track == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('zh'));
    final favorite = library.isFavorite(track.id.sourceKey, track.id.id);
    final heart = FavoriteHeart(favorite: favorite);
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      size: size,
      visualSize: visualSize,
      icon: IconSwap<bool>(
        value: heart.favorite,
        // 与收藏页行内心形同一契约（[FavoriteHeart]）。
        builder: (context, favorite) {
          final current = FavoriteHeart(favorite: favorite);
          return Icon(
            current.icon,
            color: current.color(Theme.of(context).colorScheme),
          );
        },
      ),
      semanticLabel: heart.label(l10n),
      onPressed: () {
        HapticsService.lightImpact();
        // 图标态是成功反馈；失败必须明说，否则按钮看起来「点了没反应」。
        unawaited(
          toggleLibraryFavorite(
            context,
            track,
            feedback: FavoriteFeedback.failureOnly,
          ),
        );
      },
    );
  }
}

/// 标准摘要排布：`[封面] 12 [文本] [+ 尾部槽]`，点击封面或文本进播放页。
///
/// 宿主通过槽位保留自己的版式：顶栏在封面槽里叠应用标志（播放页激活时
/// 交叉淡出），桌面底栏在尾部放收藏按钮；间距与点击语义在这里唯一。
///
/// 刻意不用 M3ETappable：它点击时会请求焦点，搜索页输入中点击顶栏会打断
/// 输入；GestureDetector 与播放页封面的手势实现保持一致。
class NowPlayingSummary extends StatelessWidget {
  const NowPlayingSummary({
    super.key,
    required this.cover,
    this.info = const NowPlayingTrackText.bar(),
    this.trailing,
    this.onTap,
  });

  /// 封面槽（通常是 [NowPlayingCover]；顶栏可在外面叠品牌标志）。
  final Widget cover;

  /// 文本槽；缺省是跟随当前曲目的 [NowPlayingTrackText.bar]。
  final Widget info;

  /// 尾部槽（桌面底栏的收藏按钮）；不参与「点击进播放页」的手势。
  final Widget? trailing;

  /// 点击封面/文本进播放页；null = 当前态不可跳转（如播放页已激活）。
  final VoidCallback? onTap;

  /// 封面与文本之间的间距：顶栏 / 底栏同一档。
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Row(
              children: [
                cover,
                const SizedBox(width: _gap),
                Expanded(child: info),
              ],
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}
