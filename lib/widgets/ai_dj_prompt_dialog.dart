/// 发送给 AI 的内容弹窗：本次预览 / 上次发送 / 上次返回。
///
/// 内容放在弹窗里而不是主页面：提示词很长，展开会把 AI 页拉成一条长列表。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../theme/m3e_context.dart';
import 'ai_dj_shared.dart';

/// 打开「发送给 AI 的内容」弹窗。
Future<void> showAiDjPromptDialog(
  BuildContext context,
  AiDjProvider provider,
) {
  return M3EDialog.show<void>(
    context,
    dialog: _AiDjPromptDialog(provider: provider),
  );
}

enum _PromptTab { preview, lastSent, lastRaw }

class _AiDjPromptDialog extends StatefulWidget {
  const _AiDjPromptDialog({required this.provider});

  final AiDjProvider provider;

  @override
  State<_AiDjPromptDialog> createState() => _AiDjPromptDialogState();
}

class _AiDjPromptDialogState extends State<_AiDjPromptDialog> {
  _PromptTab _tab = _PromptTab.preview;
  AiPrompt? _preview;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
  }

  Future<void> _loadPreview() async {
    final prompt = await widget.provider.previewPrompt();
    if (!mounted) return;
    setState(() {
      _preview = prompt;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final preferences = widget.provider.preferences;
    final sections = [
      for (final section in AiUpstreamSection.values)
        if (preferences.sections.contains(section))
          aiDjSectionLabel(l10n, section),
    ].join('、');
    final summary = l10n.aiDjSendSummary(
      sections.isEmpty ? l10n.aiDjSectionsNone : sections,
    );
    final bodyHeight =
        (MediaQuery.sizeOf(context).height * 0.42).clamp(220.0, 420.0);

    return M3EDialog(
      key: const Key('aiDjPromptDialog'),
      title: l10n.aiDjTransparencyTitle,
      subhead: summary,
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            M3ESegmentedButton<_PromptTab>(
              segments: [
                M3ESegment(
                  value: _PromptTab.preview,
                  label: l10n.aiDjPromptTabPreview,
                ),
                M3ESegment(
                  value: _PromptTab.lastSent,
                  label: l10n.aiDjPromptTabLastSent,
                ),
                M3ESegment(
                  value: _PromptTab.lastRaw,
                  label: l10n.aiDjPromptTabLastRaw,
                ),
              ],
              selected: {_tab},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                setState(() => _tab = selection.first);
              },
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: bodyHeight,
              child: SingleChildScrollView(
                child: switch (_tab) {
                  _PromptTab.preview => _buildPreview(l10n),
                  _PromptTab.lastSent => _buildLastSent(l10n),
                  _PromptTab.lastRaw => _buildLastRaw(l10n),
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        M3EButton.text(
          key: const Key('aiDjPromptCloseButton'),
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: Text(l10n.close),
        ),
      ],
    );
  }

  Widget _buildPreview(AppLocalizations l10n) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: M3ELoadingIndicator()),
      );
    }
    final prompt = _preview;
    if (prompt == null) {
      return Text(
        widget.provider.hasConfig
            ? l10n.aiDjPromptUnavailable
            : l10n.aiDjNotConfigured,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _promptBlock(l10n, l10n.aiDjSystemPrompt, prompt.systemPrompt),
        const SizedBox(height: 8),
        _promptBlock(l10n, l10n.aiDjUserPrompt, prompt.userPrompt, copy: true),
      ],
    );
  }

  Widget _buildLastSent(AppLocalizations l10n) {
    final prompt = widget.provider.lastSentPrompt;
    if (prompt == null) return Text(l10n.aiDjNoLastPrompt);
    return _promptBlock(
      l10n,
      l10n.aiDjLastSentPrompt,
      prompt.combined,
      copy: true,
    );
  }

  Widget _buildLastRaw(AppLocalizations l10n) {
    final raw = widget.provider.lastRawResponse;
    if (raw == null || raw.trim().isEmpty) {
      return Text(l10n.aiDjNoLastResponse);
    }
    return _promptBlock(
      l10n,
      l10n.aiDjLastRawResponse,
      raw,
      copy: true,
    );
  }

  Widget _promptBlock(
    AppLocalizations l10n,
    String title,
    String content, {
    bool copy = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: context.typeScale.labelMedium),
              ),
              if (copy)
                M3EButton.text(
                  key: const Key('aiDjCopyPromptButton'),
                  onPressed: () => _copy(l10n, content),
                  child: Text(l10n.aiDjCopyPrompt),
                ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            content,
            style: context.typeScale.bodySmall.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(AppLocalizations l10n, String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    M3ESnackbar.show(context, message: l10n.aiDjPromptCopied);
  }
}
