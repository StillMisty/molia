/// 换源页两个 tab 共用的 chrome：曲目条、搜索栏、来源 chips、状态条、
/// 分组标题与底部确认条。
///
/// 不读 providers：歌词侧与音频侧的会话状态分别留在各自 provider，本文件
/// 只接收已经算好的展示数据；基础件只复用 AppSearchBar / TrackArtwork。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/source.dart';
import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/m3e_context.dart';
import '../../utils/lyrics_provider_label.dart';
import '../app_search_bar.dart';
import '../track_artwork.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载组件而不注册 delegate，
/// 此时回退到简体中文（与换源视图同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 换源页顶部的曲目条：封面 + 歌名 + 「歌手 · 当前来源」。
///
/// 两个 tab 共用同一首种子曲目，把它放在页面级而不是各 tab 里，切 tab 时
/// 不重复占位；来源名兼容内置渠道 / 脚本渠道 / LRCLIB。
class SourceSwapTrackHeader extends StatelessWidget {
  const SourceSwapTrackHeader({
    super.key,
    required this.seed,
    this.sourceDescriptors = const [],
  });

  final Track seed;

  /// 可搜索渠道描述符：脚本源显示名从这里查。
  ///
  /// 非搜索 / 已停用的脚本不在其中，`lyricsProviderLabel` 会回退源 key，
  /// 这是标签解析的已知下限（不为此再维护一份全渠道列表）。
  final List<SourceDescriptor> sourceDescriptors;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final sourceLabel = lyricsProviderLabel(
      l10n,
      sourceDescriptors,
      seed.id.sourceKey,
    );
    final artist = seed.artistLabel;
    final subtitle = artist.isEmpty ? sourceLabel : '$artist · $sourceLabel';
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        children: [
          TrackArtwork(
            track: seed,
            size: 40,
            borderRadius: BorderRadius.circular(10),
            memCacheWidth: (40 * MediaQuery.of(context).devicePixelRatio)
                .round(),
            fallbackColor: theme.colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  seed.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typeScale.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typeScale.bodySmall.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 换源页统一搜索栏（AppSearchBar 包装）。
///
/// Key 由调用方给（音频 / 歌词各一个）：两个 tab 同时存活时固定 Key 会让
/// finder 命中两个；[enabled] 在确认 / 取词期间锁住输入。
class SourceSwapSearchField extends StatelessWidget {
  const SourceSwapSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AppSearchBar(
      controller: controller,
      focusNode: focusNode,
      hintText: _l10n(context).sourceSwapSearchHint,
      autofocus: autofocus,
      enabled: enabled,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}

/// 一个来源筛选选项；[key] 为空串 = 「全部」。
class SourceSwapSourceOption {
  const SourceSwapSourceOption({required this.key, required this.label});

  final String key;
  final String label;
}

/// 「全部 + 所有可搜索来源」筛选 chips。
///
/// 固定单行横向滚动：所有来源保持一行，窄屏可以左右滑动查看后面的渠道，
/// 不再换行挤压列表高度。
class SourceSwapSourceChips extends StatelessWidget {
  const SourceSwapSourceChips({
    super.key,
    required this.sources,
    required this.selectedKey,
    required this.onSelected,
    this.enabled = true,
  });

  final List<SourceSwapSourceOption> sources;

  /// 空串 = 全部。
  final String selectedKey;
  final ValueChanged<String> onSelected;

  /// 异步写入 / 取词期间禁用切换；选中态仍按 [selectedKey] 显示。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        key: const Key('sourceSwapSourceChipsScroll'),
        scrollDirection: Axis.horizontal,
        child: M3EChipGroup(
          groupLabel: l10n.sourceSwapSources,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: M3EChip(
                  key: const ValueKey<String>('sourceSwapSourceChip-all'),
                  label: l10n.sourceSwapAllSources,
                  type: M3EChipType.filter,
                  selected: selectedKey.isEmpty,
                  onPressed: enabled ? () => onSelected('') : null,
                ),
              ),
              for (final source in sources)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: M3EChip(
                    key: ValueKey<String>('sourceSwapSourceChip-${source.key}'),
                    label: source.label,
                    type: M3EChipType.filter,
                    selected: selectedKey == source.key,
                    onPressed: enabled ? () => onSelected(source.key) : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 失败源状态条：error 图标 + 文案 + 重试。
///
/// 失败重试按 tab 传不同 [retryKey]：两个 tab 同时存活时同名 Key 会让
/// 页面测试的 finder 撞车，也方便读屏定位到具体哪一侧的重试。
class SourceSwapNotice extends StatelessWidget {
  const SourceSwapNotice.failed({
    super.key,
    required this.message,
    this.onRetry,
    this.retryKey,
  });

  final String message;
  final VoidCallback? onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = _l10n(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: context.typeScale.bodySmall.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          M3EIconButton(
            key: retryKey,
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.refresh_rounded),
            semanticLabel: l10n.retry,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

/// 搜索中且还没有任何结果的居中加载态。
class SourceSwapLoadingState extends StatelessWidget {
  const SourceSwapLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const M3EProgressIndicator.circular(),
            const SizedBox(height: 12),
            Text(
              _l10n(context).sourceSwapSearching,
              textAlign: TextAlign.center,
              style: context.typeScale.bodyMedium.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态：图标 + 标题 + 可选下一步提示。
class SourceSwapEmptyState extends StatelessWidget {
  const SourceSwapEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
  });

  final IconData icon;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: context.typeScale.bodyMedium.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: context.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 「全部」模式下按来源分组的小节标题。
///
/// [hint] 给不可用来源（如未登录 B 站）挂在标题右侧：提示与来源同屏，
/// 不占用全局状态条；窄屏时标题与提示各自省略，不撑破一行。
class SourceSwapSectionHeader extends StatelessWidget {
  const SourceSwapSectionHeader({super.key, required this.label, this.hint});

  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = this.hint;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typeScale.titleSmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(width: 8),
              Flexible(
                // B 站提示比标题长：给提示 2/3 宽度，标题仍能完整显示
                // 「哔哩哔哩」；窄屏只省略提示尾部，不挤掉来源名。
                flex: 2,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: context.typeScale.bodySmall.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 底部操作条：未选提示 / 已选摘要 + 全宽确认按钮。
///
/// 底部补 [MediaQuery.padding] 的安全区；忙碌时按钮内显示小 spinner 并禁用，
/// 防止重复点击（换源 / 取词都是一次性副作用）。
class SourceSwapActionBar extends StatelessWidget {
  const SourceSwapActionBar({
    super.key,
    required this.confirmLabel,
    required this.onConfirm,
    this.selectedTitle,
    this.selectedSource,
    this.busy = false,
  });

  final String confirmLabel;
  final VoidCallback? onConfirm;

  /// null = 尚未选择，显示「点选一项后确认」。
  final String? selectedTitle;
  final String? selectedSource;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final hasSelection = selectedTitle != null;
    final summary = hasSelection
        ? l10n.sourceSwapSelected(selectedTitle!, selectedSource ?? '')
        : l10n.sourceSwapPickOne;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const M3EDivider(),
        Padding(
          padding: EdgeInsets.fromLTRB(0, 8, 0, 16 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: M3EButton.filled(
                  onPressed: hasSelection && !busy ? onConfirm : null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (busy) ...[
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: M3EProgressIndicator.circular(
                            size: 16,
                            strokeWidth: 2,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(confirmLabel),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
