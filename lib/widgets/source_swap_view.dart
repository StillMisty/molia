import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../providers/source_swap_provider.dart';
import '../utils/lyrics_provider_label.dart';
import 'source_swap/source_swap_chrome.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文（与收藏页 / 加入列表弹层同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 音频换源视图：可编辑搜索栏 → 来源筛选 chip → 候选列表 → 底部确认。
///
/// 供「换源」页的音频 tab 使用；会话状态在 [SourceSwapProvider]，
/// 本组件只负责呈现与交互。挂载即发起会话、卸载即清空会话。
/// 页面用 PageView 承载 tab：不 keep-alive 时切到歌词会把本视图 dispose，
/// 音频会话随即被 clear，切回来得从头搜。
@visibleForTesting
class SourceSwapView extends StatefulWidget {
  const SourceSwapView({super.key, required this.request});

  final SourceSwapRequest request;

  @override
  State<SourceSwapView> createState() => _SourceSwapViewState();
}

class _SourceSwapViewState extends State<SourceSwapView>
    with AutomaticKeepAliveClientMixin {
  late final SourceSwapProvider _provider;
  late final TextEditingController _searchController;
  final FocusNode _searchFocusNode = FocusNode();

  /// 会话已发起（首帧微任务里 begin；发起前显示加载态，避免读到旧会话）。
  bool _started = false;

  /// 确认流程（含去重追问）进行中：按钮内 spinner，防重复点击。
  bool _isApplying = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _provider = context.read<SourceSwapProvider>();
    _searchController = TextEditingController();
    // begin 会同步通知监听者；放到微任务里，避开本组件的首次 build。
    scheduleMicrotask(() {
      if (!mounted) return;
      _provider.begin(widget.request);
      if (!mounted) return;
      setState(() {
        _started = true;
        _searchController.text = _provider.keyword;
        _searchController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _searchController.text.length,
        );
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    // 关闭即结束会话：dispose 期间 widget 树处于锁定态，通知会触发
    // markNeedsBuild 断言；推迟到微任务清空，过期在途结果由会话 id 守卫丢弃。
    scheduleMicrotask(_provider.clear);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = _l10n(context);
    final provider = context.watch<SourceSwapProvider>();
    final sources = provider.searchableSources;
    final failedNames = provider.failedSourceNames;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SourceSwapSearchField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onChanged: (value) {
              // 清空（清除键或手动删空）立即回到初始提示并保留焦点。
              if (_started && value.isEmpty) {
                unawaited(provider.search(''));
              }
            },
            onSubmitted: (value) {
              if (!_started) return;
              _searchFocusNode.unfocus();
              unawaited(provider.search(value));
            },
          ),
        ),
        if (sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: SourceSwapSourceChips(
              sources: [
                for (final source in sources)
                  SourceSwapSourceOption(
                    key: source.key,
                    label: lyricsProviderLabel(
                      l10n,
                      provider.channels,
                      source.key,
                    ),
                  ),
              ],
              selectedKey: provider.activeSourceKey,
              onSelected: provider.selectSource,
            ),
          ),
        if (provider.isSearching && provider.groups.isNotEmpty)
          const M3EProgressIndicator.linear(),
        if (failedNames.isNotEmpty && !provider.isSearching)
          SourceSwapNotice.failed(
            message: l10n.sourceSwapFailedSources(failedNames.join(', ')),
            retryKey: const Key('sourceSwapRetryFailedAudio'),
            onRetry: provider.retryFailed,
          ),
        Expanded(child: _buildBody(context, l10n, provider)),
        SourceSwapActionBar(
          selectedTitle: provider.selected?.title,
          selectedSource: provider.selected == null
              ? null
              : provider.selectedSourceName,
          confirmLabel: l10n.sourceSwapConfirm,
          busy: _isApplying,
          onConfirm: _confirm,
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    SourceSwapProvider provider,
  ) {
    if (!_started || (provider.isSearching && provider.groups.isEmpty)) {
      return const SourceSwapLoadingState();
    }
    if (provider.noSources) {
      return SourceSwapEmptyState(
        icon: Icons.source_rounded,
        title: l10n.sourceSwapNoSources,
        hint: l10n.sourceSwapNoSourcesHint,
      );
    }
    if (provider.keyword.isEmpty) {
      return SourceSwapEmptyState(
        icon: Icons.search_rounded,
        title: l10n.sourceSwapSearchEmpty,
      );
    }

    final entries = _listEntries(provider);
    if (entries.isEmpty) {
      if (provider.activeSourceKey.isEmpty) {
        return SourceSwapEmptyState(
          icon: Icons.search_off_rounded,
          title: l10n.sourceSwapEmpty,
          hint: l10n.sourceSwapEmptyHint,
        );
      }
      return SourceSwapEmptyState(
        icon: Icons.search_off_rounded,
        title: l10n.searchNoResultsInSource(
          lyricsProviderLabel(
            l10n,
            provider.channels,
            provider.activeSourceKey,
          ),
        ),
        hint: l10n.sourceSwapEmptyHint,
      );
    }

    final gap = TrackRow.gapOf(context);
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final group = entry.group;
        if (entry.track == null) {
          return SourceSwapSectionHeader(
            key: ValueKey<String>('sourceSwapSection-${group.sourceKey}'),
            label: lyricsProviderLabel(
              l10n,
              provider.channels,
              group.sourceKey,
            ),
          );
        }
        final track = entry.track!;
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: TrackRow(
            key: ValueKey<String>('sourceSwapAudioRow-${track.id.uri}'),
            model: TrackRowModel(
              title: track.title,
              artist: track.artistLabel,
              coverUrl: track.artwork?.uri.toString(),
              durationMs: track.duration?.inMilliseconds,
              trackId: track.id,
              selected: provider.selected?.id == track.id,
            ),
            surface: const TrackRowSurface(coverSize: 40),
            position: calculateCardPosition(entry.index, entry.count),
            onTap: () => _selectAndPreview(track),
          ),
        );
      },
    );
  }

  /// 全部模式 = 每组 header + 组内行；单源模式 = 只出该组行（无 header）。
  List<_SourceSwapListEntry> _listEntries(SourceSwapProvider provider) {
    final activeKey = provider.activeSourceKey;
    final entries = <_SourceSwapListEntry>[];
    for (final group in provider.groups) {
      if (activeKey.isNotEmpty && group.sourceKey != activeKey) continue;
      if (activeKey.isEmpty) {
        entries.add(_SourceSwapListEntry.header(group));
      }
      for (var index = 0; index < group.items.length; index++) {
        entries.add(
          _SourceSwapListEntry.track(
            group: group,
            track: group.items[index],
            index: index,
            count: group.items.length,
          ),
        );
      }
    }
    return entries;
  }

  /// 选中并立即试听：单曲上下文，试听会打断当前播放。
  void _selectAndPreview(Track track) {
    _provider.select(track);
    unawaited(
      context.read<PlaybackProvider>().playDomainTracks(
        [track],
        0,
        contextName: _l10n(context).sourceSwapPreviewContext,
      ),
    );
  }

  Future<void> _confirm() async {
    if (_isApplying) return;
    setState(() => _isApplying = true);
    final l10n = _l10n(context);
    SourceSwapApplyResult result;
    try {
      result = await _provider.apply();
      if (result.status ==
          SourceSwapApplyStatus.duplicateConfirmationRequired) {
        if (!mounted) return;
        final confirmed = await M3EDialog.show<bool>(
          context,
          dialog: M3EDialog(
            title: l10n.sourceSwapDuplicateTitle,
            content: Text(l10n.sourceSwapDuplicateMessage),
            actions: [
              M3EButton.text(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              M3EButton.filled(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.sourceSwapConfirm),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        result = await _provider.apply(removeDuplicate: true);
      }
    } catch (_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.sourceSwapApplyFailed);
      return;
    } finally {
      if (mounted) setState(() => _isApplying = false);
    }
    if (!mounted) return;
    switch (result.status) {
      case SourceSwapApplyStatus.swapped:
        M3ESnackbar.show(
          context,
          message: result.queueFollowed
              ? l10n.sourceSwapQueueFollowed
              : l10n.sourceSwapDone,
        );
        Navigator.of(context).pop();
      case SourceSwapApplyStatus.targetNotFound:
        M3ESnackbar.show(context, message: l10n.sourceSwapNotFound);
      case SourceSwapApplyStatus.writeFailed:
        // 库内写失败：队列仍指向原曲，留在弹层让用户重试或改选。
        M3ESnackbar.show(context, message: l10n.operationFailed);
      case SourceSwapApplyStatus.duplicateConfirmationRequired:
        break; // 已在上面处理后重试；走到这里说明状态异常，保持弹层。
    }
  }
}

/// 音频候选列表的一行：分组标题或曲目（组内序号用于卡片形状）。
class _SourceSwapListEntry {
  const _SourceSwapListEntry.header(this.group)
    : track = null,
      index = 0,
      count = 0;

  const _SourceSwapListEntry.track({
    required this.group,
    required this.track,
    required this.index,
    required this.count,
  });

  final SourceSwapGroup group;
  final Track? track;
  final int index;
  final int count;
}
