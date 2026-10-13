/// AI 推歌页：今日推荐列表 + 电台状态 + 反馈 + 配置。
///
/// 定位（对齐「个性推荐」）：**列表是主体**——持久、可浏览、可随时播放；
/// 「推歌（电台）」是列表上的一个动作（播放全部即接管队列并自动续推）。
/// 入口：发现页「今日推荐」区的「查看全部」+ 设置 › 内容 › AI 推歌。
/// 模式状态机与播放协调在 [AiDjProvider]；本页只做展示与交互。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../domain/models/failure.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../providers/playback_provider.dart';
import '../services/notification_service.dart';
import '../widgets/ai_dj_shared.dart';
import '../widgets/ai_dj_track_tile.dart';
import '../widgets/icon_swap.dart';
import '../widgets/track_row.dart';

class AiDjPage extends StatefulWidget {
  const AiDjPage({super.key});

  @override
  State<AiDjPage> createState() => _AiDjPageState();
}

class _AiDjPageState extends State<AiDjPage> {
  late final AiDjProvider _provider;
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();

  /// 配置表单展开态：未配置时默认展开。
  bool _editingConfig = false;
  bool _busy = false;

  /// 「本次发送的数据」摘要：展开时懒加载。
  bool _showUpstream = false;
  bool _upstreamLoading = false;
  AiUpstreamSummary? _upstream;

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
      ),
      body: SafeArea(
        child: Consumer<AiDjProvider>(
          builder: (context, provider, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _statusCard(l10n, provider),
              if (provider.enabled) ...[
                const SizedBox(height: 16),
                _recommendationsCard(context, l10n, provider),
                const SizedBox(height: 16),
                _feedbackCard(l10n, provider),
                const SizedBox(height: 16),
                _upstreamCard(l10n),
              ],
              const SizedBox(height: 16),
              _configCard(l10n, provider),
            ],
          ),
        ),
      ),
    );
  }

  // ── 状态卡：功能开关 + 电台状态 + 会话统计 ──────────────────────────────

  Widget _statusCard(AppLocalizations l10n, AiDjProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    final statusText = switch (provider.status) {
      AiDjStatus.off =>
        provider.enabled ? l10n.aiDjStatusIdle : l10n.aiDjStatusOff,
      AiDjStatus.preparing => l10n.aiDjStatusPreparing,
      AiDjStatus.playing => l10n.aiDjStatusPlaying,
      AiDjStatus.error => l10n.aiDjStatusError,
    };
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.aiDjToggle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                statusText,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(width: 8),
              M3ESwitch(
                key: const Key('aiDjModeSwitch'),
                value: provider.enabled,
                onChanged:
                    _busy ? null : (value) => value ? _enable() : _disable(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.aiDjToggleSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          if (provider.enabled && provider.queuedCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              l10n.aiDjQueued(provider.queuedCount),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
          if (provider.lastError != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    aiDjFailureText(l10n, provider.lastError!),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: provider.isBusy
                      ? null
                      : () => unawaited(provider.refreshRecommendations()),
                  child: Text(l10n.aiDjRetry),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── 今日推荐：主操作 + 推荐卡列表 + 未解析折叠 ─────────────────────────

  Widget _recommendationsCard(
    BuildContext context,
    AppLocalizations l10n,
    AiDjProvider provider,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final list = provider.recommendations;
    final items = list?.items ?? const <ResolvedRecommendation>[];
    final currentUri = context.select<PlaybackProvider, String?>(
      (playback) => playback.snapshot.current?.id.uri,
    );
    final busy = provider.isBusy;

    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.aiDjTodayTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (list != null)
                Text(
                  l10n.aiDjLastUpdated(aiDjUpdatedText(l10n, list.generatedAt)),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              M3EButton.filled(
                key: const Key('aiDjPlayAllButton'),
                onPressed: busy || items.isEmpty
                    ? null
                    : () => unawaited(provider.startRadio()),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.aiDjPlayAll),
              ),
              M3EButton.tonal(
                key: const Key('aiDjEnqueueAllButton'),
                onPressed: busy || items.isEmpty ? null : _enqueueAll,
                icon: const Icon(Icons.playlist_add_rounded),
                label: Text(l10n.aiDjEnqueueAll),
              ),
              M3EButton.text(
                key: const Key('aiDjRefreshBatchButton'),
                onPressed: busy ? null : () => unawaited(provider.refreshRecommendations()),
                child: Text(l10n.aiDjRefreshBatch),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (provider.isBusy && list == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: M3ELoadingIndicator()),
            )
          else if (list == null || items.isEmpty)
            _emptyRecommendations(l10n, provider)
          else
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) SizedBox(height: TrackRow.gapOf(context)),
              AiDjTrackTile(
                index: i,
                count: items.length,
                item: items[i],
                isCurrent: items[i].track.id.uri == currentUri,
                inQueue: provider.isQueued(items[i].track.id.uri),
                busy: provider.isBusy,
                onPlay: () => unawaited(provider.playRecommendation(i)),
                onReplace: () => unawaited(provider.replaceRecommendation(i)),
                onNotInterested: () => unawaited(
                  provider.markNotInterested(items[i].track.id.uri),
                ),
              ),
            ],
          if (list != null && list.unresolved.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              l10n.aiDjUnresolved(list.unresolved.length),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 4),
            for (final item in list.unresolved.take(10))
              Text(
                '· ${item.label}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 空列表：显式「生成推荐」（不自动消耗 token）。
  Widget _emptyRecommendations(
    AppLocalizations l10n,
    AiDjProvider provider,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.aiDjEmptyList,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.aiDjEmptyListHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        M3EButton.tonal(
          key: const Key('aiDjGenerateButton'),
          onPressed:
              provider.isBusy ? null : () => unawaited(provider.refreshRecommendations()),
          icon: const Icon(Icons.auto_awesome_rounded),
          label: Text(l10n.aiDjGenerate),
        ),
      ],
    );
  }

  // ── 反馈面板：跳过 / 不感兴趣（可撤销） / 喜欢 ─────────────────────────

  Widget _feedbackCard(AppLocalizations l10n, AiDjProvider provider) {
    final notInterested = provider.notInterestedItems;
    final manualLabels = {
      for (final item in notInterested) item.source.label,
    };
    final autoSkipped = [
      for (final label in provider.skippedLabels)
        if (!manualLabels.contains(label)) label,
    ];
    final liked = provider.likedLabels;
    if (notInterested.isEmpty && autoSkipped.isEmpty && liked.isEmpty) {
      return const SizedBox.shrink();
    }
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.aiDjFeedbackTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
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
      ),
    );
  }

  // ── 本次发送的数据（隐私透明） ─────────────────────────────────────────

  Widget _upstreamCard(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final summary = _upstream;
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.aiDjUpstreamTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: IconSwap<bool>(
                  value: _showUpstream,
                  builder: (context, showUpstream) => Icon(
                    showUpstream
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                ),
                tooltip: l10n.aiDjUpstreamTitle,
                onPressed: _toggleUpstream,
              ),
            ],
          ),
          if (_showUpstream) ...[
            const SizedBox(height: 4),
            if (_upstreamLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: M3ELoadingIndicator(),
              )
            else if (summary != null) ...[
              Text(
                l10n.aiDjUpstreamBody(
                  summary.recentEvents,
                  summary.topArtists,
                  summary.exclusions,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                l10n.aiDjUpstreamHint,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  void _toggleUpstream() {
    setState(() {
      _showUpstream = !_showUpstream;
    });
    if (_showUpstream && _upstream == null) {
      unawaited(_loadUpstream());
    }
  }

  Future<void> _loadUpstream() async {
    setState(() => _upstreamLoading = true);
    final summary = await _provider.summarizeUpstream();
    if (!mounted) return;
    setState(() {
      _upstream = summary;
      _upstreamLoading = false;
    });
  }

  // ── 配置卡：折叠摘要 + 展开表单 + 缓存有效期 ───────────────────────────

  Widget _configCard(AppLocalizations l10n, AiDjProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.aiDjConfigTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (!_editingConfig && provider.hasConfig)
                TextButton(
                  key: const Key('aiDjManageConfigButton'),
                  onPressed: () => setState(() => _editingConfig = true),
                  child: Text(l10n.aiDjOpenSettings),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_editingConfig) _configForm(l10n) else _configSummary(l10n, provider),
          const SizedBox(height: 4),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          _cacheTtlRow(l10n, provider),
          const SizedBox(height: 4),
          Row(
            children: [
              M3EButton.tonal(
                key: const Key('aiDjTestConnectionButton'),
                onPressed: _busy ? null : _testConnection,
                icon: const Icon(Icons.wifi_tethering_rounded),
                label: Text(l10n.aiDjTestConnection),
              ),
              if (!_editingConfig && provider.hasConfig) ...[
                const SizedBox(width: 8),
                M3EButton.text(
                  onPressed: _busy ? null : _clearConfig,
                  child: Text(l10n.aiDjClearConfig),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 推荐缓存有效期：只影响续推是否消费旧列表，不做过期提示。
  Widget _cacheTtlRow(AppLocalizations l10n, AiDjProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.aiDjCacheTtlTitle),
                const SizedBox(height: 2),
                Text(
                  l10n.aiDjCacheTtlHint,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 132,
            child: M3EDropdownMenu<int>(
              items: [
                for (final days in kAiCacheTtlDayOptions)
                  M3EDropdownItem<int>(
                    label: days <= 0
                        ? l10n.aiDjCacheTtlForever
                        : l10n.aiDjCacheTtlDays(days),
                    value: days,
                    selected: provider.cacheTtlDays == days,
                  ),
              ],
              singleSelect: true,
              showChipAnimation: false,
              onSelectionChanged: (items) {
                if (items.isEmpty) return;
                unawaited(provider.setCacheTtlDays(items.first.value));
              },
            ),
          ),
        ],
      ),
    );
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
                onPressed: () => _applyPreset(l10n, preset),
              ),
            M3EChip(
              label: l10n.aiDjPresetCustom,
              type: M3EChipType.filter,
              selected: !_matchesAnyPreset(),
              onPressed: () => setState(() {}),
            ),
          ],
        ),
        const SizedBox(height: 12),
        M3ETextField(
          key: const Key('aiDjBaseUrlField'),
          controller: _baseUrlController,
          label: l10n.aiDjBaseUrl,
          placeholder: 'https://api.deepseek.com',
          leading: const Icon(Icons.link_rounded),
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(config.baseUrl, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text(
          '${config.model} · ${config.maskedApiKey}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  bool _matchesAnyPreset() => LlmProviderPreset.builtIn
      .any((preset) => preset.baseUrl == _baseUrlController.text.trim());

  void _applyPreset(AppLocalizations l10n, LlmProviderPreset preset) {
    setState(() {
      _baseUrlController.text = preset.baseUrl;
      _modelController.text = preset.model;
    });
  }

  // ── 动作 ──────────────────────────────────────────────────────────────

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
    final config = _editingConfig
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
      _notify(l10n.aiDjTestSucceeded);
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

/// Web 平台隐藏（CORS 与密钥安全）；其余平台可用。
bool get aiDjSupportedPlatform => !kIsWeb;
