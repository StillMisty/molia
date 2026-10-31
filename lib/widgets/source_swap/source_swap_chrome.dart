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
    this.channels = const [],
  });

  final Track seed;

  /// 当前渠道描述符：脚本源显示名从这里查，查不到回退源 key。
  final List<SourceDescriptor> channels;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final sourceLabel = lyricsProviderLabel(l10n, channels, seed.id.sourceKey);
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

/// 换源页统一搜索栏（AppSearchBar 包装 + 固定测试 key）。
///
/// `Key` 放在 AppSearchBar 上：两个 tab 同时存活时 finder 会命中两个，
/// 页面测试再按 tab 视图做 descendant 限定。
class SourceSwapSearchField extends StatelessWidget {
  const SourceSwapSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.trailing = const <Widget>[],
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return AppSearchBar(
      key: const Key('sourceSwapSearchField'),
      controller: controller,
      focusNode: focusNode,
      hintText: _l10n(context).sourceSwapSearchHint,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      trailing: trailing,
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
/// 用 [Wrap] 而不是横向滚动：来源可能排到第 7 个（5 个内置平台 + B 站 +
/// 脚本源），横向滚动时窄屏默认看不到最后一个，用户很难发现还能滑出来。
class SourceSwapSourceChips extends StatelessWidget {
  const SourceSwapSourceChips({
    super.key,
    required this.sources,
    required this.selectedKey,
    required this.onSelected,
  });

  final List<SourceSwapSourceOption> sources;

  /// 空串 = 全部。
  final String selectedKey;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return M3EChipGroup(
      groupLabel: l10n.sourceSwapSources,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          M3EChip(
            key: const ValueKey<String>('sourceSwapSourceChip-all'),
            label: l10n.sourceSwapAllSources,
            type: M3EChipType.filter,
            selected: selectedKey.isEmpty,
            onPressed: () => onSelected(''),
          ),
          for (final source in sources)
            M3EChip(
              key: ValueKey<String>('sourceSwapSourceChip-${source.key}'),
              label: source.label,
              type: M3EChipType.filter,
              selected: selectedKey == source.key,
              onPressed: () => onSelected(source.key),
            ),
        ],
      ),
    );
  }
}

/// 状态条：失败源（error 图标 + 文案 + 重试）或不可用来源（info 图标 + 提示）。
///
/// 失败重试按 tab 传不同 [retryKey]：两个 tab 同时存活时同名 Key 会让
/// 页面测试的 finder 撞车，也方便读屏定位到具体哪一侧的重试。
class SourceSwapNotice extends StatelessWidget {
  const SourceSwapNotice.failed({
    super.key,
    required this.message,
    this.onRetry,
    this.retryKey,
  }) : _isError = true;

  const SourceSwapNotice.info({super.key, required this.message})
    : _isError = false,
      onRetry = null,
      retryKey = null;

  final String message;
  final bool _isError;
  final VoidCallback? onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = _l10n(context);
    final color = _isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            _isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 18,
            color: color,
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
          if (_isError)
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

/// 空态：图标 + 标题 + 可选下一步提示 + 可选动作。
class SourceSwapEmptyState extends StatelessWidget {
  const SourceSwapEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final Widget? action;

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
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// 「全部」模式下按来源分组的小节标题。
class SourceSwapSectionHeader extends StatelessWidget {
  const SourceSwapSectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Semantics(
        header: true,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.typeScale.titleSmall.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
