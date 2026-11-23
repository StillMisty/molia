import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../domain/models/diagnostics.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/diagnostics_provider.dart';
import '../../services/diagnostics/resolve_metrics.dart';
import '../settings/settings_tiles.dart';
import 'diagnostics_labels.dart';

/// 本次运行：运行时长、上次退出与取链统计（只读、紧凑）。
class DiagnosticsSessionSection extends StatefulWidget {
  const DiagnosticsSessionSection({super.key, required this.provider});

  final DiagnosticsProvider provider;

  @override
  State<DiagnosticsSessionSection> createState() =>
      _DiagnosticsSessionSectionState();
}

class _DiagnosticsSessionSectionState extends State<DiagnosticsSessionSection> {
  Timer? _durationTimer;

  @override
  void initState() {
    super.initState();
    // 只重算展示用的时长，不触发任何检查 / 扫盘。
    _durationTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<DiagnosticSessionInfo?>(
      valueListenable: widget.provider.session,
      builder: (context, session, _) {
        return ValueListenableBuilder<ResolveMetricsSnapshot>(
          valueListenable: widget.provider.metrics,
          builder: (context, metrics, _) {
            final duration = session == null
                ? null
                : DateTime.now().difference(session.startedAt);
            return SettingsSectionCard(
              title: l10n.diagnosticsSessionSection,
              footer: SettingsSectionHint(text: l10n.diagnosticsResolveHint),
              children: [
                if (duration != null)
                  SettingsInfoTile(
                    icon: Icons.timelapse_rounded,
                    title: l10n.diagnosticsSessionDuration,
                    subtitle: diagnosticDurationText(l10n, duration),
                  )
                else
                  SettingsInfoTile(
                    icon: Icons.timelapse_rounded,
                    title: l10n.diagnosticsSessionDuration,
                    subtitle: l10n.diagnosticsLoading,
                  ),
                SettingsInfoTile(
                  icon: Icons.logout_rounded,
                  title: l10n.diagnosticsPreviousExit,
                  subtitle: _previousExitText(l10n, session),
                ),
                SettingsInfoTile(
                  icon: Icons.bolt_rounded,
                  title: l10n.diagnosticsResolveSection,
                  subtitle: _resolveText(l10n, metrics),
                ),
                if (metrics.failureKinds.isNotEmpty)
                  SettingsInfoTile(
                    icon: Icons.report_rounded,
                    title: l10n.diagnosticsResolveFailureKinds,
                    subtitle: [
                      for (final entry in metrics.failureKinds)
                        '${diagnosticFailureReason(l10n, entry.key)} '
                            '${entry.value}',
                    ].join(' · '),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  String _previousExitText(
    AppLocalizations l10n,
    DiagnosticSessionInfo? session,
  ) {
    final at = session?.previousExitAt;
    if (at == null) return l10n.diagnosticsPreviousExitUnknown;
    final time = diagnosticShortTime(at);
    return session!.previousAbnormalExit
        ? l10n.diagnosticsPreviousExitAbnormal(time)
        : l10n.diagnosticsPreviousExitClean(time);
  }

  String _resolveText(AppLocalizations l10n, ResolveMetricsSnapshot metrics) {
    if (metrics.calls == 0) return l10n.diagnosticsResolveNoData;
    final rate = (metrics.cacheHits * 100 / metrics.calls).round();
    return [
      '${l10n.diagnosticsResolveCalls} ${l10n.diagnosticsResolveCount(metrics.calls)}',
      l10n.diagnosticsResolveCacheHitRate(rate),
      '${l10n.diagnosticsResolveFailures} '
          '${l10n.diagnosticsResolveCount(metrics.failures)}',
      '${l10n.diagnosticsResolveTimeouts} '
          '${l10n.diagnosticsResolveCount(metrics.timeouts)}',
    ].join(' · ');
  }
}
