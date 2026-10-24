/// AI 推歌页：当前推荐 + 偏好入口 + 历史入口 + 发送透明化 + 反馈 + 配置。
///
/// 定位（对齐「个性推荐」）：**当前推荐是主体**——持久、可浏览、可随时播放；
/// 「推歌（电台）」是列表上的一个动作（播放全部即接管队列并自动续歌）。
/// 自动补歌是静默后台行为，本页不显示它的进度，只在连续失败后显示内部状态。
/// 入口：发现页「今日推荐」区的「查看全部」+ 设置 › 内容 › AI 推歌。
///
/// 版式：M3E 分区式（与收藏 / 队列页同一种形状语言）——分区标题 + 平铺
/// 分段列表直接铺在页面表面，不再「卡片套卡片」。发送原文收进弹窗，
/// 避免长提示词把页面撑成长列表。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../domain/models/failure.dart';
import '../l10n/app_localizations.dart';
import '../pages/ai_dj_history_page.dart';
import '../pages/ai_dj_preferences_page.dart';
import '../providers/ai_dj_provider.dart';
import '../providers/playback_provider.dart';
import '../services/ai/ai_generation_executor.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import '../widgets/ai_dj_prompt_dialog.dart';
import '../widgets/ai_dj_shared.dart';
import '../widgets/ai_dj_track_tile.dart';
import '../widgets/ai_dj_waiting.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/track_row.dart';

class AiDjPage extends StatefulWidget {
  const AiDjPage({super.key});

  @override
  State<AiDjPage> createState() => _AiDjPageState();
}

class _AiDjPageState extends State<AiDjPage> {
  /// 分区间距（分区标题之间）。
  static const double _sectionGap = 24;

  late final AiDjProvider _provider;
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final FocusNode _baseUrlFocus = FocusNode();

  /// 配置表单展开态：未配置时默认展开。
  bool _editingConfig = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _provider = context.read<AiDjProvider>();
    final config = _provider.config;
    if (config == null) {
      // 首次配置：默认预填第一个内置预设（DeepSeek），只需粘 API Key。
      final preset = LlmProviderPreset.builtIn.first;
      _baseUrlController.text = preset.baseUrl;
      _modelController.text = preset.model;
    } else {
      _loadConfigIntoControllers(config);
    }
    _editingConfig = !_provider.hasConfig;
    // 启用状态下确保有列表可浏览（列表缺失才生成，不跨天自动换批）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_provider.ensureRecommendations());
    });
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _baseUrlFocus.dispose();
    super.dispose();
  }

  void _loadConfigIntoControllers(LlmConfig? config) {
    _baseUrlController.text = config?.baseUrl ?? '';
    _apiKeyController.text = config?.apiKey ?? '';
    _modelController.text = config?.model ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.aiDjTitle),
        automaticallyImplyLeading: true,
        actions: [
          M3EIconButton(
            key: const Key('aiDjHistoryButton'),
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.history_rounded),
            semanticLabel: l10n.aiDjHistoryTitle,
            onPressed: () => _openPage(const AiDjHistoryPage()),
          ),
        ],
      ),
      body: SafeArea(
        child: Consumer<AiDjProvider>(
          builder: (context, provider, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _statusSection(l10n, provider),
              if (provider.enabled) ...[
                _preferencesSection(l10n, provider),
                ..._recommendationsSection(context, l10n, provider),
                ..._feedbackSection(l10n, provider),
                ..._sendingSection(l10n, provider),
              ],
              ..._configSection(l10n, provider),
            ],
          ),
        ),
      ),
    );
  }

  /// 分区标题行：标题 + 可选副标题（上次更新等）+ 可选行尾动作。
  Widget _sectionHeader(String title, {String? caption, Widget? trailing}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Text(title, style: context.typeScale.titleMedium),
        if (caption != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typeScale.labelMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ] else
          const Spacer(),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _statusSection(AppLocalizations l10n, AiDjProvider provider) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusText = switch (provider.status) {
      AiDjStatus.off =>
        provider.enabled ? l10n.aiDjStatusIdle : l10n.aiDjStatusOff,
      AiDjStatus.preparing => l10n.aiDjStatusPreparing,
      AiDjStatus.playing => l10n.aiDjStatusPlaying,
      AiDjStatus.error => l10n.aiDjStatusError,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardListSurface(
          position: M3ECardPosition.single,
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          // 开关行整体不可点：交互只走右侧 Switch，避免误触开启/关闭。
          onPressed: null,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.aiDjToggle, style: context.typeScale.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      l10n.aiDjToggleSubtitle,
                      style: context.typeScale.bodySmall.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: context.typeScale.labelMedium.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              M3ESwitch(
                key: const Key('aiDjModeSwitch'),
                value: provider.enabled,
                onChanged:
                    _busy ? null : (value) => value ? _enable() : _disable(),
              ),
            ],
          ),
        ),
        if (provider.enabled && provider.queuedCount > 0) ...[
          const SizedBox(height: 8),
          Text(
            l10n.aiDjQueued(provider.queuedCount),
            style: context.typeScale.labelSmall.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (provider.lastError != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  aiDjFailureText(l10n, provider.lastError!),
                  style: context.typeScale.bodySmall,
                ),
              ),
              M3EButton.icon(
                style: M3EButtonStyle.text,
                onPressed: provider.isBusy
                    ? null
                    : () => unawaited(provider.refreshRecommendations()),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l10n.aiDjRetry),
              ),
            ],
          ),
        ],
        if (provider.autoFeedError != null && !provider.autoFeedHalted) ...[
          const SizedBox(height: 8),
          Row(
            key: const Key('aiDjAutoFeedError'),
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.aiDjAutoFeedFailed,
                  style: context.typeScale.bodySmall,
                ),
              ),
            ],
          ),
        ],
        if (provider.autoFeedHalted) ...[
          const SizedBox(height: 8),
          Row(
            key: const Key('aiDjAutoFeedHalted'),
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.aiDjAutoFeedHalted(provider.autoFeedFailures),
                  style: context.typeScale.bodySmall,
                ),
              ),
              M3EButton.text(
                key: const Key('aiDjAutoFeedResumeButton'),
                onPressed: provider.resumeAutoFeed,
                child: Text(l10n.aiDjAutoFeedResume),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _preferencesSection(AppLocalizations l10n, AiDjProvider provider) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: CardListSurface(
        key: const Key('aiDjPreferencesRow'),
        position: M3ECardPosition.single,
        onPressed: () => _openPage(const AiDjPreferencesPage()),
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            Icon(Icons.tune_rounded, size: 22, color: scheme.tertiary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.aiDjPreferencesTitle,
                    style: context.typeScale.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    aiDjPreferencesSummary(l10n, provider.preferences),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typeScale.bodySmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  List<Widget> _recommendationsSection(
    BuildContext context,
    AppLocalizations l10n,
    AiDjProvider provider,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final batch = provider.recommendations;
    final items = batch?.items ?? const <ResolvedRecommendation>[];
    final currentUri = context.select<PlaybackProvider, String?>(
      (playback) => playback.snapshot.current?.id.uri,
    );
    final busy = provider.isBusy;
    final radioActive = provider.status == AiDjStatus.playing;

    return [
      const SizedBox(height: _sectionGap),
      _sectionHeader(
        l10n.aiDjTodayTitle,
        caption: batch == null
            ? null
            : l10n.aiDjLastUpdated(aiDjUpdatedText(l10n, batch.generatedAt)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (radioActive)
              M3EIconButton(
                key: const Key('aiDjFeedBatchButton'),
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.queue_music_rounded),
                semanticLabel: l10n.aiDjFeedBatch,
                onPressed: busy ? null : _feedBatch,
              ),
            M3EIconButton(
              key: const Key('aiDjRefreshBatchButton'),
              variant: M3EIconButtonVariant.standard,
              icon: const Icon(Icons.refresh_rounded),
              semanticLabel: l10n.aiDjRefreshBatch,
              onPressed: busy
                  ? null
                  : () => unawaited(provider.refreshRecommendations()),
            ),
          ],
        ),
      ),
      if (items.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            M3EButton.filled(
              key: const Key('aiDjPlayAllButton'),
              onPressed: busy ? null : () => unawaited(provider.startRadio()),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(l10n.aiDjPlayAll),
            ),
            M3EButton.tonal(
              key: const Key('aiDjEnqueueAllButton'),
              onPressed: busy ? null : _enqueueAll,
              icon: const Icon(Icons.playlist_add_rounded),
              label: Text(l10n.aiDjEnqueueAll),
            ),
          ],
        ),
      ],
      const SizedBox(height: 12),
      // 进度分片只重建这张卡，不带走整页列表。
      ValueListenableBuilder<AiGenerationState>(
        valueListenable: provider.generationState,
        builder: (context, generation, _) {
          final progress = generation.progress;
          if (progress == null) return const SizedBox.shrink();
          return _GenerationCard(
            progress: progress,
            onCancel: provider.cancelGeneration,
          );
        },
      ),
      if (provider.progress != null && items.isEmpty) ...[
        const SizedBox(height: 12),
        AiDjPulsingSkeleton(rows: 5),
      ] else if (batch == null || items.isEmpty)
        _emptyRecommendations(l10n, provider)
      else ...[
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: TrackRow.gapOf(context)),
          AiDjTrackTile(
            index: i,
            count: items.length,
            item: items[i],
            isCurrent: items[i].track.id.uri == currentUri,
            busy: busy,
            replacing: provider.isReplacing(items[i].track.id.uri),
            onPlay: () => unawaited(provider.playRecommendation(i)),
            onReplace: () => unawaited(provider.replaceRecommendation(i)),
            onNotInterested: () => unawaited(
              provider.markNotInterested(items[i].track.id.uri),
            ),
            onMoreLikeThis: () => unawaited(
              provider.addSeed(items[i].source.label),
            ),
          ),
        ],
      ],
      if (batch != null && batch.unresolved.isNotEmpty) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.aiDjUnresolved(batch.unresolved.length),
                style: context.typeScale.labelMedium.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            M3EButton.text(
              key: const Key('aiDjRetryUnresolvedButton'),
              onPressed: provider.isBusy ? null : _retryUnresolved,
              child: Text(l10n.aiDjRetryUnresolved),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final item in batch.unresolved.take(10))
          Text(
            '· ${item.label}',
            style: context.typeScale.bodySmall.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    ];
  }

  /// 空列表：显式「生成推荐」（不自动消耗 token）。
  Widget _emptyRecommendations(
    AppLocalizations l10n,
    AiDjProvider provider,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.aiDjEmptyList,
          style: context.typeScale.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.aiDjEmptyListHint,
          style: context.typeScale.bodySmall.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        M3EButton.tonal(
          key: const Key('aiDjGenerateButton'),
          onPressed: provider.isBusy
              ? null
              : () => unawaited(provider.refreshRecommendations()),
          icon: const Icon(Icons.auto_awesome_rounded),
          label: Text(l10n.aiDjGenerate),
        ),
      ],
    );
  }

  List<Widget> _feedbackSection(AppLocalizations l10n, AiDjProvider provider) {
    final notInterested = provider.notInterestedItems;
    final manualLabels = {
      for (final item in notInterested) item.source.label,
    };
    final autoSkipped = [
      for (final label in provider.skippedLabels)
        if (!manualLabels.contains(label)) label,
    ];
    final liked = provider.likedLabels;
    final rememberedSkipped = provider.rememberedSkippedLabels;
    final rememberedLiked = provider.rememberedLikedLabels;
    final seeds = provider.seeds;
    if (notInterested.isEmpty &&
        autoSkipped.isEmpty &&
        liked.isEmpty &&
        rememberedSkipped.isEmpty &&
        rememberedLiked.isEmpty &&
        seeds.isEmpty) {
      return const [];
    }
    return [
      const SizedBox(height: _sectionGap),
      _sectionHeader(
        l10n.aiDjFeedbackTitle,
        trailing: M3EButton.text(
          key: const Key('aiDjClearMemoryButton'),
          onPressed: () => _clearMemory(provider),
          child: Text(l10n.aiDjClearMemory),
        ),
      ),
      if (rememberedSkipped.isNotEmpty || rememberedLiked.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          l10n.aiDjFeedbackMemory,
          style: context.typeScale.labelMedium,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final label in rememberedSkipped.take(10))
              M3EChip(
                type: M3EChipType.assist,
                label: '${l10n.aiDjFeedbackSkipped} · $label',
              ),
            for (final label in rememberedLiked.take(10))
              M3EChip(
                type: M3EChipType.assist,
                label: '${l10n.aiDjFeedbackLiked} · $label',
              ),
          ],
        ),
      ],
      if (autoSkipped.isNotEmpty ||
          liked.isNotEmpty ||
          notInterested.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          l10n.aiDjFeedbackThisRound,
          style: context.typeScale.labelMedium,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in notInterested)
              M3EChip(
                key: Key('aiDjNotInterested_${item.track.id.uri}'),
                type: M3EChipType.input,
                label: '${l10n.aiDjNotInterested} · ${item.source.label}',
                onDeleted: () =>
                    unawaited(provider.undoNotInterested(item.track.id.uri)),
                onPressed: () =>
                    unawaited(provider.undoNotInterested(item.track.id.uri)),
              ),
            for (final label in autoSkipped.take(10))
              M3EChip(
                type: M3EChipType.assist,
                label: '${l10n.aiDjFeedbackSkipped} · $label',
              ),
            for (final label in liked.take(10))
              M3EChip(
                type: M3EChipType.assist,
                label: '${l10n.aiDjFeedbackLiked} · $label',
              ),
          ],
        ),
      ],
      if (seeds.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          l10n.aiDjSeedsTitle,
          style: context.typeScale.labelMedium,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final seed in seeds)
              M3EChip(
                key: Key('aiDjSeed_$seed'),
                type: M3EChipType.input,
                label: l10n.aiDjSeedLabel(seed),
                onDeleted: () => unawaited(provider.removeSeed(seed)),
              ),
          ],
        ),
      ],
    ];
  }

  List<Widget> _sendingSection(AppLocalizations l10n, AiDjProvider provider) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return [
      const SizedBox(height: _sectionGap),
      _sectionHeader(l10n.aiDjTransparencyTitle),
      const SizedBox(height: 8),
      CardListSurface(
        key: const Key('aiDjPromptRow'),
        position: M3ECardPosition.single,
        onPressed: () => unawaited(showAiDjPromptDialog(context, provider)),
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            Icon(Icons.visibility_rounded, size: 22, color: scheme.tertiary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.aiDjViewPrompt,
                    style: context.typeScale.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.aiDjPromptPrivacyHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typeScale.bodySmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    ];
  }

  List<Widget> _configSection(AppLocalizations l10n, AiDjProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: _sectionGap),
      _sectionHeader(
        l10n.aiDjConfigTitle,
        trailing: !_editingConfig && provider.hasConfig
            ? M3EButton.text(
                key: const Key('aiDjManageConfigButton'),
                onPressed: () => setState(() => _editingConfig = true),
                child: Text(l10n.aiDjOpenSettings),
              )
            : null,
      ),
      const SizedBox(height: 8),
      if (_editingConfig) _configForm(l10n) else _configSummary(l10n, provider),
      const SizedBox(height: 12),
      M3EDivider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      const SizedBox(height: 4),
      // 两个配置动作（测试连接 / 清除配置）平级，收进同一组：tonal 统一语气，
      // 按下即分发命令（selectedIndex 恒空、不留选中态）。
      M3EButtonGroup(
        type: M3EButtonGroupType.standard,
        style: M3EButtonStyle.tonal,
        actions: [
          M3EButtonGroupAction(
            icon: const Icon(Icons.wifi_tethering_rounded),
            label: Text(l10n.aiDjTestConnection),
            enabled: !_busy,
          ),
          if (!_editingConfig && provider.hasConfig)
            M3EButtonGroupAction(
              icon: const Icon(Icons.delete_rounded),
              label: Text(l10n.aiDjClearConfig),
              enabled: !_busy,
            ),
        ],
        onSelectedIndexChanged: (index) {
          if (index == 0) {
            _testConnection();
          } else if (index == 1) {
            _clearConfig();
          }
        },
      ),
    ];
  }

  Widget _configForm(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in LlmProviderPreset.builtIn)
              M3EChip(
                label: preset.name,
                type: M3EChipType.filter,
                selected: _baseUrlController.text.trim() == preset.baseUrl,
                onPressed: () => _applyPreset(preset),
              ),
            M3EChip(
              key: const Key('aiDjCustomPresetChip'),
              label: l10n.aiDjPresetCustom,
              type: M3EChipType.filter,
              selected: !_matchesAnyPreset(),
              // 选「自定义」= 继续编辑地址：把焦点送回 URL 输入框。
              onPressed: () => _baseUrlFocus.requestFocus(),
            ),
          ],
        ),
        const SizedBox(height: 12),
        M3ETextField(
          key: const Key('aiDjBaseUrlField'),
          controller: _baseUrlController,
          focusNode: _baseUrlFocus,
          label: l10n.aiDjBaseUrl,
          placeholder: 'https://api.deepseek.com',
          leading: const Icon(Icons.link_rounded),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        M3ETextField(
          key: const Key('aiDjApiKeyField'),
          controller: _apiKeyController,
          label: l10n.aiDjApiKey,
          obscureText: true,
          showPasswordToggle: true,
          leading: const Icon(Icons.key_rounded),
        ),
        const SizedBox(height: 12),
        M3ETextField(
          key: const Key('aiDjModelField'),
          controller: _modelController,
          label: l10n.aiDjModel,
          placeholder: 'deepseek-chat',
          leading: const Icon(Icons.smart_toy_rounded),
        ),
        const SizedBox(height: 12),
        M3EButton.filled(
          key: const Key('aiDjSaveConfigButton'),
          onPressed: _busy ? null : _saveConfig,
          icon: const Icon(Icons.check_rounded),
          label: Text(l10n.aiDjSaveConfig),
        ),
      ],
    );
  }

  Widget _configSummary(AppLocalizations l10n, AiDjProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    final config = provider.config;
    if (config == null) {
      return Text(
        l10n.aiDjNotConfigured,
        style: context.typeScale.bodySmall.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(config.baseUrl, style: context.typeScale.bodyMedium),
        const SizedBox(height: 4),
        Text(
          '${config.model} · ${config.maskedApiKey}',
          style: context.typeScale.bodySmall.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  bool _matchesAnyPreset() => LlmProviderPreset.builtIn
      .any((preset) => preset.baseUrl == _baseUrlController.text.trim());

  void _applyPreset(LlmProviderPreset preset) {
    setState(() {
      _baseUrlController.text = preset.baseUrl;
      _modelController.text = preset.model;
    });
  }

  void _openPage(Widget page) {
    ResponsiveNavigation.showPageModal(
      context: context,
      // 页面自带 Scaffold / AppBar，弹层只提供卡片容器：关闭走遮罩 /
      // Esc / 下滑 / 系统返回。
      child: page,
    );
  }

  /// 开启功能（不接管播放；列表缺失时生成一批）。
  Future<void> _enable() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = _provider;
    if (!provider.hasConfig) {
      setState(() => _editingConfig = true);
      _notify(l10n.aiDjNotConfigured, error: true);
      return;
    }
    if (!await ensureAiDjConsent(context, provider)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await provider.setEnabled(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 关闭功能：停止续推，弹确认决定是否清空当前队列。
  Future<void> _disable() async {
    final l10n = AppLocalizations.of(context)!;
    // 弹层 dialog 挂 root navigator（M3EDialog.show 语义）；本页可能位于设置
    // 弹层的嵌套 Navigator 内，页面 context 上的 pop 会误退本页，关闭要显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
    final keepQueue = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.aiDjStopDialogTitle,
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancel),
          ),
          M3EButton.text(
            key: const Key('aiDjStopKeepQueueButton'),
            onPressed: () => navigator.pop(true),
            child: Text(l10n.aiDjStopKeepQueue),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.aiDjStopClearQueue),
          ),
        ],
      ),
    );
    if (keepQueue == null || !mounted) return;
    await _provider.stop(keepQueue: keepQueue);
    await _provider.setEnabled(false);
  }

  Future<void> _enqueueAll() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = _provider;
    final before = provider.queuedCount;
    await provider.enqueueRecommendations();
    if (!mounted) return;
    if (provider.queuedCount == before) {
      _notify(l10n.aiDjEnqueueEmpty);
    }
  }

  Future<void> _feedBatch() async {
    final provider = _provider;
    final before = provider.historyCount;
    await provider.feedMore();
    if (!mounted) return;
    if (provider.historyCount > before) {
      _notify(AppLocalizations.of(context)!.aiDjFeedDone);
    }
  }

  Future<void> _retryUnresolved() async {
    final provider = _provider;
    final before = provider.recommendations?.unresolved.length ?? 0;
    await provider.retryUnresolved();
    if (!mounted) return;
    final after = provider.recommendations?.unresolved.length ?? 0;
    if (after < before) {
      _notify(AppLocalizations.of(context)!.aiDjUnresolvedRetried);
    }
  }

  Future<void> _clearMemory(AiDjProvider provider) async {
    final l10n = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.aiDjClearMemoryTitle,
        content: Text(l10n.aiDjClearMemoryBody),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            key: const Key('aiDjClearMemoryConfirm'),
            onPressed: () => navigator.pop(true),
            child: Text(l10n.aiDjClearMemory),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await provider.clearFeedbackMemory();
    if (!mounted) return;
    _notify(l10n.aiDjMemoryCleared);
  }

  Future<void> _saveConfig() async {
    final l10n = AppLocalizations.of(context)!;
    final config = LlmConfig(
      baseUrl: _baseUrlController.text,
      apiKey: _apiKeyController.text,
      model: _modelController.text,
    );
    if (!config.isComplete) {
      _notify(l10n.aiDjNotConfigured, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _provider.saveConfig(config);
      if (!mounted) return;
      setState(() => _editingConfig = false);
      _notify(l10n.aiDjConfigSaved);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = _provider;
    final editing = _editingConfig;
    final config = editing
        ? LlmConfig(
            baseUrl: _baseUrlController.text,
            apiKey: _apiKeyController.text,
            model: _modelController.text,
          )
        : provider.config;
    if (config == null || !config.isComplete) {
      _notify(l10n.aiDjNotConfigured, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await provider.testConnection(config);
      if (!mounted) return;
      // 表单值测通即存：消除「测过了但忘记保存」的坑，配置以刚验证的那份为准。
      if (editing) {
        await provider.saveConfig(config);
        if (!mounted) return;
        setState(() => _editingConfig = false);
        _notify(l10n.aiDjTestSaved);
      } else {
        _notify(l10n.aiDjTestSucceeded);
      }
    } on SourceFailure catch (failure) {
      if (!mounted) return;
      _notify(aiDjFailureText(l10n, failure), error: true);
    } catch (_) {
      if (!mounted) return;
      _notify(l10n.aiDjRequestFailed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearConfig() async {
    await _provider.clearConfig();
    if (!mounted) return;
    _loadConfigIntoControllers(null);
    setState(() => _editingConfig = true);
  }

  void _notify(String message, {bool error = false}) {
    final notifications = context.read<NotificationService?>();
    if (notifications == null) {
      M3ESnackbar.show(context, message: message);
      return;
    }
    if (error) {
      notifications.showErrorSnackBar(message);
    } else {
      notifications.showSuccessSnackBar(message);
    }
  }
}

/// 显式生成状态卡：阶段 + 等待秒数 + 解析进度 + 停止。
///
/// 静默自动补歌永远不实例化本组件（provider 不设置 progress）。
class _GenerationCard extends StatefulWidget {
  const _GenerationCard({
    required this.progress,
    required this.onCancel,
  });

  final AiDjProgress progress;
  final VoidCallback onCancel;

  @override
  State<_GenerationCard> createState() => _GenerationCardState();
}

class _GenerationCardState extends State<_GenerationCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final seconds =
        DateTime.now().difference(widget.progress.startedAt).inSeconds;
    final progress = widget.progress;
    return M3ECard(
      key: const Key('aiDjGenerationCard'),
      variant: M3ECardVariant.filled,
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AiDjPulse(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: M3ELoadingIndicator(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.aiDjGenerationStatus,
                      style: context.typeScale.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        aiDjPhaseText(l10n, progress),
                        l10n.aiDjWaitingSeconds(seconds),
                      ].join(' · '),
                      style: context.typeScale.bodySmall.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              M3EIconButton(
                key: const Key('aiDjCancelGenerationButton'),
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.stop_rounded),
                semanticLabel: l10n.aiDjCancelGeneration,
                onPressed: widget.onCancel,
              ),
            ],
          ),
          const SizedBox(height: 10),
          AiDjThinProgress(value: progress.fraction),
        ],
      ),
    );
  }
}
