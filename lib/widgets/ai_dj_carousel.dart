/// 发现页「今日推荐」区：搜索框下方的推荐流。
///
/// - 展示 [AiDjProvider.recommendations]（持久化的今日推荐列表）：封面卡 +
///   歌名/歌手（用 carousel 原生槽位，保证每张卡都常显，不再把文字塞进
///   图片层被槽位裁掉）；
/// - 浏览：桌面端开 freeScroll 且允许鼠标拖动（跟手拖拽、松手吸附最近的
///   卡）；横向滚动视图只吃 dx，纵向滚轮的 dy 到不了它手里，所以在外层
///   自接指针信号、攒够一格翻一张。触屏维持 carousel 默认的一步一张，
///   避免与发现页的竖向滚动手势互抢；
/// - 点卡即从该首起播、AI 接管队列（`playRecommendation`），并把该卡滚到
///   焦点位：拖动/滚轮之后焦点未必在点中的卡上，滚过去信息区才落到这首；
/// - 卡片流下方是推荐理由信息区：只显示焦点卡（carousel 最大槽位）的理由，
///   歌名 / 歌手由卡片承担、不在信息区重复；理由为空或焦点越界（「换一批」卡、
///   换批后的过期索引）时整区不渲染——留一个空块比不显示更突兀；
/// - 尾部「换一批」卡只留刷新图标、不写字（读屏靠语义标签），整卡仍是
///   可点按钮（推歌中只换"下一批来源"，不打断播放）；
/// - 未配置/未启用 → 整块（卡片流 + 信息区）不渲染（不额外做引导）；搜索
///   激活时由宿主页不挂载本组件（让位给结果区），本组件不感知搜索态；
/// - 列表为空 → 显式「生成推荐」引导卡；生成中 → 骨架；失败 → 重试卡；
/// - 过期不做提示（「上次更新」只在卡片区副标题展示）。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../pages/ai_dj_page.dart';
import '../providers/ai_dj_provider.dart';
import '../services/ai/ai_generation_executor.dart';
import '../utils/responsive.dart';
import 'ai_dj_shared.dart';
import 'ai_dj_waiting.dart';
import 'app_network_image.dart';

class AiDjCarousel extends StatefulWidget {
  const AiDjCarousel({super.key});

  @override
  State<AiDjCarousel> createState() => _AiDjCarouselState();
}

class _AiDjCarouselState extends State<AiDjCarousel> {
  /// 骨架卡/占位卡宽度（真实卡片宽度由 M3ECarousel 布局决定）。
  static const double _placeholderWidth = 132;

  /// carousel 高度：封面 + 槽位文字（文字由 carousel 叠在封面上）。
  static const double _carouselHeight = 198;

  /// 桌面滚轮翻卡的累计位移阈值（逻辑像素）：一格滚轮就能翻一张，
  /// 再小则会被一次惯性滚动连翻好几张。
  static const double _wheelStepThreshold = 40;

  /// 卡片流控制器：滚轮翻卡、点卡对位都要用它，不能交给 carousel 内部持有。
  final M3ECarouselController _controller = M3ECarouselController();

  /// 焦点（最大槽位）卡索引：下方信息区跟着它显示推荐理由。
  int _focalIndex = 0;

  /// 滚轮累计位移（没到阈值前先攒着）。
  double _wheelDelta = 0;

  /// 翻卡动画进行中：期间的滚轮事件丢弃，避免一次滚动连着翻好几张。
  bool _wheelAnimating = false;

  /// 上一步没走动的方向（+1 / −1，0 = 没有）与当时的滚动位置。
  ///
  /// 贴着末尾时一步的位移可能超出当前可滚范围（M3E 内容总长随滑动增长），
  /// 动画被边界拉回、焦点原地不动：这个方向不再截流，交给发现页整体滚动。
  /// 位置一变（拖动 / 换卡）判断即作废，所以只记位置不记「已到尽头」。
  int _wheelStalledDirection = 0;
  double _wheelStalledPixels = 0;

  /// 上一帧是否渲染了卡片流：卡片流从引导卡/骨架/重试卡切回来时 carousel
  /// 是新建的（滚动位置回到首卡），焦点索引要跟着复位。
  bool _carouselVisible = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AiDjProvider?>();
    if (provider == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        // 默认关闭：未启用时发现页完全不出现 AI 相关内容（不额外做引导）。
        if (!provider.enabled) {
          _carouselVisible = false;
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context)!;
        final list = provider.recommendations;
        final hasCards = list != null && list.items.isNotEmpty;
        if (hasCards && !_carouselVisible) {
          // carousel 重建即滚动位置归零；焦点索引不复位会让信息区显示上一轮
          // 的理由（卡片流本身却停在首卡）。
          _focalIndex = 0;
          _wheelDelta = 0;
        }
        _carouselVisible = hasCards;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.aiDjTodayTitle,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        ValueListenableBuilder<AiGenerationState>(
                          valueListenable: provider.generationState,
                          builder: (context, _, __) => Text(
                            _subtitleText(l10n, provider),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  M3EButton.text(
                    key: const Key('aiDjManageButton'),
                    onPressed: () => _openPage(context),
                    child: Text(l10n.aiDjViewAll),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 细进度条只订阅生成状态：进度分片不再重建卡片流。
            ValueListenableBuilder<AiGenerationState>(
              valueListenable: provider.generationState,
              builder: (context, generation, _) {
                final progress = generation.progress;
                if (progress == null || !hasCards) {
                  return const SizedBox.shrink();
                }
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: AiDjThinProgress(value: progress.fraction),
                    ),
                    const SizedBox(height: 6),
                  ],
                );
              },
            ),
            _body(context, l10n, provider),
            if (hasCards) _reasonPanel(context, list),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  String _subtitleText(AppLocalizations l10n, AiDjProvider provider) {
    final list = provider.recommendations;
    final progress = provider.progress;
    if (progress != null) {
      return [
        aiDjPhaseText(l10n, progress),
        if (provider.status == AiDjStatus.playing) l10n.aiDjStatusPlaying,
      ].join(' · ');
    }
    final parts = <String>[
      if (provider.status == AiDjStatus.playing) l10n.aiDjStatusPlaying,
      if (list != null)
        l10n.aiDjLastUpdated(aiDjUpdatedText(l10n, list.generatedAt)),
    ];
    if (parts.isEmpty) return l10n.aiDjDiscoverSubtitle;
    return parts.join(' · ');
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    AiDjProvider provider,
  ) {
    final list = provider.recommendations;
    if (list == null || list.items.isEmpty) {
      if (provider.progress != null) return _skeleton(context);
      final error = provider.lastError;
      if (error != null) {
        return _guideCard(
          context,
          key: const Key('aiDjBatchErrorCard'),
          icon: Icons.error_outline_rounded,
          title: l10n.aiDjBatchFailed,
          subtitle: aiDjFailureText(l10n, error),
          trailingIcon: Icons.refresh_rounded,
          onTap: () => unawaited(provider.refreshRecommendations()),
        );
      }
      // 空列表：显式生成（不自动消耗 token）。
      return _guideCard(
        context,
        key: const Key('aiDjGenerateCard'),
        icon: Icons.auto_awesome_rounded,
        title: l10n.aiDjEmptyList,
        subtitle: l10n.aiDjEmptyListHint,
        onTap: () => unawaited(provider.refreshRecommendations()),
      );
    }
    return _carousel(context, l10n, provider, list);
  }

  Widget _guideCard(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    IconData trailingIcon = Icons.chevron_right_rounded,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: M3ECard(
        key: key,
        variant: M3ECardVariant.filled,
        color: scheme.surfaceContainerHigh,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        onPressed: onTap,
        child: Row(
          children: [
            Icon(icon, size: 22, color: scheme.tertiary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            Icon(trailingIcon, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _skeleton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget box() => Container(
          width: _placeholderWidth,
          height: _placeholderWidth,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
        );
    return SizedBox(
      height: _placeholderWidth,
      child: AiDjPulse(
        child: ListView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            box(),
            const SizedBox(width: 10),
            box(),
            const SizedBox(width: 10),
            box(),
            const SizedBox(width: 10),
            box(),
          ],
        ),
      ),
    );
  }

  Widget _carousel(
    BuildContext context,
    AppLocalizations l10n,
    AiDjProvider provider,
    AiDjBatch batch,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final desktop = isDesktopPlatform();
    final carousel = M3ECarousel(
      key: const Key('aiDjCarousel'),
      controller: _controller,
      type: M3ECarouselType.contained,
      height: _carouselHeight,
      // 桌面跟手拖动、松手吸附到最近的卡；触摸端保持「一步一张」，
      // 免得和发现页的竖向滚动手势互抢。
      freeScroll: desktop,
      onChange: (details) {
        if (!mounted || details.focalIndex == _focalIndex) return;
        setState(() => _focalIndex = details.focalIndex);
      },
      children: [
        for (var i = 0; i < batch.items.length; i++)
          M3ECarouselItem(
            // 封面 + 原生 title/subtitle 槽位：文字由 carousel 按当前槽位
            // 渲染，任何宽度下都保留歌名与歌手。
            image: AppNetworkImage(
              url: batch.items[i].track.artwork?.uri.toString(),
              fit: BoxFit.cover,
              fallbackColor: scheme.surfaceContainerHighest,
              fallbackIconSize: 32,
            ),
            title: Text(
              batch.items[i].track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.titleSmall,
            ),
            subtitle: _artistOf(batch.items[i]).isEmpty
                ? null
                : Text(
                    _artistOf(batch.items[i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodySmall,
                  ),
            // 关闭按槽位隐藏标题：歌名与歌手每张卡都要在。
            applyDynamicTextContentTransform: false,
            showScrim: const M3ECarouselScrim.gradient(),
            semanticLabel: _semanticLabel(batch.items[i]),
            onTap: () {
              unawaited(provider.playRecommendation(i));
              // 点中的卡滚到焦点位：拖动/滚轮之后焦点未必在它身上，
              // 信息区也就跟着焦点落到这首上。
              unawaited(_controller.animateToItem(i));
            },
          ),
        M3ECarouselItem(
          image: Container(
            color: scheme.surfaceContainerHigh,
            child: Center(
              child: Icon(
                Icons.refresh_rounded,
                size: 34,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          // 只留图标：卡片上不再写「换一批」，读屏名靠语义标签。
          semanticLabel: l10n.aiDjRefreshBatch,
          onTap: () => unawaited(provider.refreshRecommendations()),
        ),
      ],
    );
    if (!desktop) return carousel;
    return ScrollConfiguration(
      // 鼠标拖动默认被 ScrollBehavior 挡掉（dragDevices 不含鼠标）：
      // 这里只为桌面放开，跟手拖动才走 freeScroll 的吸附物理。
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          ...ScrollConfiguration.of(context).dragDevices,
          PointerDeviceKind.mouse,
        },
      ),
      // 横向滚动视图只吃 `dx`，普通滚轮的 `dy` 到不了它手里：在外面自己接
      // 指针信号，把 dy 攒够一格再翻一张。
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: carousel,
      ),
    );
  }

  /// 推荐理由信息区：显示焦点卡（carousel 最大槽位）的推荐理由。
  ///
  /// 歌名 / 歌手不再在这里重复一遍——卡片流上的槽位文字就是这首的标识，信息区
  /// 只留 AI 的理由。焦点不在推荐卡上（「换一批」卡，或换批后越界的过期索引）
  /// 或该卡没有理由时整区不渲染——留一个空块比不显示更突兀。
  Widget _reasonPanel(BuildContext context, AiDjBatch batch) {
    if (_focalIndex < 0 || _focalIndex >= batch.items.length) {
      return const SizedBox.shrink();
    }
    final item = batch.items[_focalIndex];
    final reason = item.source.reason.trim();
    if (reason.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const Key('aiDjReasonPanel'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 16,
              color: scheme.tertiary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 桌面滚轮翻卡：把 dy 攒够一格就翻一张，翻完清零。
  ///
  /// 两个不消费信号的分支——动画进行中、该方向没卡可翻——把这次滚动留给
  /// 外层页面：卡片流在发现页里本来就是竖向滚动的一部分。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final double dy = event.scrollDelta.dy;
    if (dy == 0) return;

    if (_wheelAnimating) {
      _wheelDelta = 0;
      _claimSignal(event);
      return;
    }

    _wheelDelta += dy;
    if (_wheelDelta.abs() < _wheelStepThreshold) {
      // 还没攒够一格：也先占住信号，否则同一次滚动会顺手把外层页面带走。
      _claimSignal(event);
      return;
    }
    final int direction = _wheelDelta > 0 ? 1 : -1;
    if (!_canStep(direction) || _stalled(direction)) {
      _wheelDelta = 0;
      return;
    }
    _wheelDelta = 0;
    _claimSignal(event);
    unawaited(_stepByWheel(direction));
  }

  /// 抢下这次指针信号：同一次滚轮不要再被外层竖向滚动视图消费。
  void _claimSignal(PointerSignalEvent event) {
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
  }

  /// 该方向是否还有可滚的余地。
  bool _canStep(int direction) {
    if (!_controller.hasClients) return false;
    final position = _controller.position;
    if (!position.hasContentDimensions) return false;
    return direction > 0
        ? position.pixels < position.maxScrollExtent - 0.5
        : position.pixels > position.minScrollExtent + 0.5;
  }

  /// 这个方向上一次翻卡是不是停在原地（没走动的判断见字段注释）。
  bool _stalled(int direction) {
    if (_wheelStalledDirection != direction || !_controller.hasClients) {
      return false;
    }
    return (_controller.position.pixels - _wheelStalledPixels).abs() < 1;
  }

  /// 滚轮翻一张：以当前焦点卡为基准。
  ///
  /// 不用 `M3ECarouselController.next()`：它的步进游标在自由拖动之后会和
  /// 实际位置脱节，反而往回翻；`animateToItem` 自己夹取上下界，到尽头是空操作。
  Future<void> _stepByWheel(int direction) async {
    _wheelAnimating = true;
    final double before =
        _controller.hasClients ? _controller.position.pixels : 0;
    try {
      await _controller.animateToItem(_focalIndex + direction);
    } finally {
      _wheelAnimating = false;
    }
    if (!_controller.hasClients) return;
    final bool moved = (_controller.position.pixels - before).abs() >= 1;
    _wheelStalledDirection = moved ? 0 : direction;
    _wheelStalledPixels = before;
  }

  static String _artistOf(ResolvedRecommendation item) =>
      item.track.artistLabel;

  String _semanticLabel(ResolvedRecommendation item) {
    final artist = _artistOf(item);
    return artist.isEmpty ? item.track.title : '${item.track.title} - $artist';
  }

  void _openPage(BuildContext context) {
    ResponsiveNavigation.showAdaptiveModalPage(
      context: context,
      // 弹层自带标题栏（含关闭）会和页面自己的标题栏叠成双层 chrome：
      // 关闭走遮罩 / Esc / 下滑 / 系统返回。
      showCloseButton: false,
      child: const AiDjPage(),
    );
  }
}
