/// 首次引导：四屏、全程可跳过，渲染在壳层之前（不是路由、不是导航目的地）。
///
/// 只写现有 provider / 设置：渠道开关走 [SourcesProvider]，默认音质与省流走
/// [SourcesProvider] / [DataSaverService]；流程自身只持有当前步骤，不镜像任何
/// 设置值。不联网、不登录。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/source.dart';
import '../l10n/app_localizations.dart';
import '../providers/sources_provider.dart';
import '../services/data_saver_service.dart';
import '../theme/m3e_context.dart';
import '../theme/motion_policy.dart';

class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key, required this.onFinished});

  /// 完成 / 跳过都走同一个回调：壳层负责写设备本地标记并切回正常骨架。
  final Future<void> Function() onFinished;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  static const int _stepCount = 4;

  int _step = 0;
  bool _finishing = false;

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await widget.onFinished();
  }

  void _next() {
    if (_step >= _stepCount - 1) {
      unawaited(_finish());
      return;
    }
    setState(() => _step++);
  }

  void _back() {
    if (_step == 0) return;
    setState(() => _step--);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      label: l10n.onboardingStep(_step + 1, _stepCount),
                      child: M3EProgressIndicator.linear(
                        value: (_step + 1) / _stepCount,
                        linearSize: M3EProgressIndicatorSize.s,
                        strokeWidth: 4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.onboardingStep(_step + 1, _stepCount),
                    style: context.typeScale.labelMedium.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  M3EButton.text(
                    key: const Key('onboardingSkip'),
                    onPressed: _finishing ? null : _finish,
                    child: Text(l10n.onboardingSkip),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                // 每一步用同一根淡入（key 变化即重跑）；减弱动效时零时长硬切。
                // 不用 AnimatedSwitcher：它是图标切换的专用件（架构约定）。
                child: TweenAnimationBuilder<double>(
                  key: ValueKey<int>(_step),
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: effectDurationOf(context, M3EMotion.short3),
                  curve: M3EMotion.emphasizedDecelerate,
                  builder: (context, opacity, child) =>
                      Opacity(opacity: opacity, child: child),
                  child: SingleChildScrollView(
                    child: _buildStep(context, l10n, _step),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_step > 0)
                    M3EButton.text(
                      key: const Key('onboardingBack'),
                      onPressed: _finishing ? null : _back,
                      child: Text(l10n.onboardingBack),
                    ),
                  const Spacer(),
                  M3EButton.filled(
                    key: const Key('onboardingNext'),
                    onPressed: _finishing ? null : _next,
                    child: Text(
                      _step == _stepCount - 1
                          ? l10n.onboardingStart
                          : l10n.onboardingNext,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context, AppLocalizations l10n, int step) =>
      switch (step) {
        0 => _textStep(
          context,
          icon: Icons.shield_rounded,
          title: l10n.onboardingPrivacyTitle,
          body: l10n.onboardingPrivacyBody,
          noteTitle: l10n.onboardingPrivacyScriptsTitle,
          noteBody: l10n.onboardingPrivacyScriptsBody,
        ),
        1 => _channelsStep(context, l10n),
        2 => _qualityStep(context, l10n),
        _ => _optionalStep(context, l10n),
      };

  Widget _textStep(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
    String? noteTitle,
    String? noteBody,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Icon(icon, size: 44, color: scheme.primary),
        const SizedBox(height: 16),
        Text(title, style: context.emphasizedTypeScale.headlineSmall),
        const SizedBox(height: 12),
        Text(body, style: context.typeScale.bodyLarge),
        if (noteTitle != null && noteBody != null) ...[
          const SizedBox(height: 24),
          Text(noteTitle, style: context.typeScale.titleMedium),
          const SizedBox(height: 6),
          Text(
            noteBody,
            style: context.typeScale.bodyMedium.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _channelsStep(BuildContext context, AppLocalizations l10n) {
    final sources = context.watch<SourcesProvider?>();
    final ready = sources?.initialized ?? false;
    final channels = sources?.channels ?? const <SourceDescriptor>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          l10n.onboardingChannelsTitle,
          style: context.emphasizedTypeScale.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(l10n.onboardingChannelsBody, style: context.typeScale.bodyLarge),
        const SizedBox(height: 16),
        if (!ready)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Row(
              children: [
                const M3ELoadingIndicator(),
                const SizedBox(width: 12),
                Text(
                  l10n.onboardingChannelsPreparing,
                  style: context.typeScale.bodyMedium,
                ),
              ],
            ),
          )
        else
          for (final channel in channels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      channel.displayName,
                      style: context.typeScale.bodyLarge,
                    ),
                  ),
                  M3ESwitch(
                    key: ValueKey<String>('onboardingChannel-${channel.key}'),
                    value: channel.enabled,
                    onChanged: (value) => unawaited(
                      sources!.setChannelEnabled(channel.key, value),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _qualityStep(BuildContext context, AppLocalizations l10n) {
    final sources = context.watch<SourcesProvider?>();
    final dataSaver = context.watch<DataSaverService?>();
    final scheme = Theme.of(context).colorScheme;
    final quality = sources?.preferredQuality ?? '320k';
    const options = ['320k', '192k', '128k'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          l10n.onboardingQualityTitle,
          style: context.emphasizedTypeScale.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(l10n.onboardingQualityBody, style: context.typeScale.bodyLarge),
        const SizedBox(height: 20),
        Text(l10n.onboardingQualityLabel, style: context.typeScale.titleSmall),
        const SizedBox(height: 8),
        M3ESegmentedButton<String>(
          key: const Key('onboardingQuality'),
          segments: [
            for (final option in options)
              M3ESegment(value: option, label: option.toUpperCase()),
          ],
          selected: {quality},
          enabled: sources != null,
          onSelectionChanged: (selection) {
            if (selection.isEmpty) return;
            unawaited(sources!.setPreferredQuality(selection.first));
          },
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.onboardingDataSaver,
                    style: context.typeScale.bodyLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.onboardingDataSaverHint,
                    style: context.typeScale.bodySmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            M3ESwitch(
              key: const Key('onboardingDataSaver'),
              value: dataSaver?.enabled ?? false,
              onChanged: dataSaver == null
                  ? null
                  : (value) => unawaited(dataSaver.setEnabled(value)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _optionalStep(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    Widget row(String title, String body) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.typeScale.titleMedium),
          const SizedBox(height: 4),
          Text(
            body,
            style: context.typeScale.bodyMedium.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          l10n.onboardingOptionalTitle,
          style: context.emphasizedTypeScale.headlineSmall,
        ),
        row(l10n.onboardingOptionalSync, l10n.onboardingOptionalSyncBody),
        row(l10n.onboardingOptionalAi, l10n.onboardingOptionalAiBody),
        const SizedBox(height: 20),
        Text(
          l10n.onboardingOptionalNoAccount,
          style: context.typeScale.bodyMedium.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
