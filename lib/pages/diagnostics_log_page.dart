import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/diagnostics.dart';
import '../l10n/app_localizations.dart';
import '../providers/diagnostics_provider.dart';
import '../services/notification_service.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/diagnostics/diagnostics_labels.dart';
import '../widgets/empty_state.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// 日志级别筛选。
enum DiagnosticsLogLevelFilter { all, warning, error }

/// 只读日志子页：有界尾部 + 级别 / 关键词筛选 + 复制当前结果。
///
/// 只在打开本页时读一次磁盘；筛选全部在内存结果上执行，不改写文件，也不
/// 提供删除 / 清空（轮转由日志 sink 自动处理）。
class DiagnosticsLogPage extends StatefulWidget {
  const DiagnosticsLogPage({super.key});

  @override
  State<DiagnosticsLogPage> createState() => _DiagnosticsLogPageState();
}

class _DiagnosticsLogPageState extends State<DiagnosticsLogPage> {
  final TextEditingController _search = TextEditingController();
  DiagnosticsLogLevelFilter _level = DiagnosticsLogLevelFilter.all;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<DiagnosticsProvider>().loadLogs());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<DiagnosticsProvider>();
    return ValueListenableBuilder<DiagnosticsLogsState>(
      valueListenable: provider.logsState,
      builder: (context, logs, _) {
        final filtered = _filter(logs.entries);
        return SettingsSubPage.body(
          title: l10n.diagnosticsLogsTitle,
          actions: [
            M3EIconButton(
              key: const Key('diagnosticsLogRefresh'),
              variant: M3EIconButtonVariant.standard,
              icon: const Icon(Icons.refresh_rounded),
              semanticLabel: l10n.diagnosticsLogsRefresh,
              onPressed: () => unawaited(provider.refreshLogs()),
            ),
            M3EIconButton(
              key: const Key('diagnosticsLogCopy'),
              variant: M3EIconButtonVariant.standard,
              icon: const Icon(Icons.content_copy_rounded),
              semanticLabel: l10n.diagnosticsLogsCopy,
              onPressed: filtered.isEmpty
                  ? null
                  : () => unawaited(_copy(context, provider, l10n, filtered)),
            ),
          ],
          body: _body(context, l10n, provider, logs, filtered),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    DiagnosticsProvider provider,
    DiagnosticsLogsState logs,
    List<DiagnosticLogEntry> filtered,
  ) {
    if (logs.status == DiagnosticsLogsStatus.loading ||
        logs.status == DiagnosticsLogsStatus.idle) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (logs.status == DiagnosticsLogsStatus.unavailable ||
        logs.status == DiagnosticsLogsStatus.failed) {
      return SettingsSubPageList(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: EmptyState(
              icon: Icons.receipt_long_rounded,
              message: l10n.diagnosticsLogsUnavailable,
              hint: l10n.diagnosticsLogsUnavailableHint,
            ),
          ),
          _openDirectoryRow(context, provider, l10n),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(kSettingsPadding),
      children: [
        M3ESegmentedButton<DiagnosticsLogLevelFilter>(
          semanticLabel: l10n.diagnosticsLogsFilterSemantics,
          segments: [
            M3ESegment(
              value: DiagnosticsLogLevelFilter.all,
              label: l10n.diagnosticsLogsLevelAll,
            ),
            M3ESegment(
              value: DiagnosticsLogLevelFilter.warning,
              label: l10n.diagnosticsLogsLevelWarning,
            ),
            M3ESegment(
              value: DiagnosticsLogLevelFilter.error,
              label: l10n.diagnosticsLogsLevelError,
            ),
          ],
          selected: {_level},
          onSelectionChanged: (selection) {
            if (selection.isNotEmpty) setState(() => _level = selection.first);
          },
        ),
        const SizedBox(height: kSettingsElementSpacing),
        M3ETextField(
          key: const Key('diagnosticsLogSearch'),
          controller: _search,
          placeholder: l10n.diagnosticsLogsSearchHint,
          leading: const Icon(Icons.search_rounded),
          onChanged: (value) => setState(() => _keyword = value),
        ),
        const SizedBox(height: kSettingsSmallSpacing),
        Text(
          l10n.diagnosticsLogsResultCount(filtered.length),
          style: M3ETheme.of(context).typeScale.bodySmall.copyWith(
            color: M3ETheme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: kSettingsElementSpacing),
        if (logs.entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: EmptyState(
              icon: Icons.history_rounded,
              message: l10n.diagnosticsLogsEmpty,
              hint: l10n.diagnosticsLogsEmptyHint,
            ),
          )
        else if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: EmptyState(
              icon: Icons.filter_alt_off_rounded,
              message: l10n.diagnosticsLogsFilteredEmpty,
              hint: l10n.diagnosticsLogsFilteredEmptyHint,
            ),
          )
        else
          for (final entry in filtered.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: kSettingsSmallSpacing),
              child: _LogEntryRow(
                key: ValueKey(
                  'diagnosticsLogEntry-${entry.time.millisecondsSinceEpoch}-'
                  '${entry.logger}',
                ),
                entry: entry,
              ),
            ),
        const SizedBox(height: kSettingsSmallSpacing),
        _openDirectoryRow(context, provider, l10n),
      ],
    );
  }

  Widget _openDirectoryRow(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
  ) {
    return SettingsSectionCard(
      children: [
        SettingsTileRow(
          key: const Key('diagnosticsLogsOpenDirectory'),
          icon: Icons.folder_open_rounded,
          title: l10n.diagnosticsLogsOpenDirectory,
          subtitle: l10n.diagnosticsLogsOpenDirectoryHint,
          onPressed: () => unawaited(_openDirectory(context, provider, l10n)),
        ),
      ],
    );
  }

  List<DiagnosticLogEntry> _filter(List<DiagnosticLogEntry> entries) {
    return [
      for (final entry in entries)
        if (_matchesLevel(entry) && entry.matchesKeyword(_keyword)) entry,
    ];
  }

  bool _matchesLevel(DiagnosticLogEntry entry) {
    final level = entry.level.toUpperCase();
    return switch (_level) {
      DiagnosticsLogLevelFilter.all => true,
      DiagnosticsLogLevelFilter.warning =>
        level == 'WARNING' || level == 'SEVERE' || level == 'SHOUT',
      DiagnosticsLogLevelFilter.error => level == 'SEVERE' || level == 'SHOUT',
    };
  }

  Future<void> _copy(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
    List<DiagnosticLogEntry> filtered,
  ) async {
    final notifications = context.read<NotificationService?>();
    if (filtered.isEmpty) {
      notifications?.showSnackBar(l10n.diagnosticsLogsCopyEmpty);
      return;
    }
    final ok = await provider.copyLogEntries(filtered);
    notifications?.showSnackBar(
      ok
          ? l10n.diagnosticsLogsCopied(filtered.length)
          : l10n.diagnosticsActionCopyFailed,
      isError: !ok,
    );
  }

  Future<void> _openDirectory(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
  ) async {
    final notifications = context.read<NotificationService?>();
    final ok = await provider.revealLogDirectory();
    if (!ok) {
      notifications?.showErrorSnackBar(l10n.diagnosticsLogsOpenDirectoryFailed);
    }
  }
}

class _LogEntryRow extends StatelessWidget {
  const _LogEntryRow({super.key, required this.entry});

  final DiagnosticLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m3e = M3ETheme.of(context);
    final level = diagnosticLogLevelText(l10n, entry.level);
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      onPressed: null,
      semanticLabel:
          '${diagnosticLogLevelText(l10n, entry.level)}, ${entry.message}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(
              Icons.article_rounded,
              size: 18,
              color: diagnosticLogLevelColor(context, entry.level),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${diagnosticShortTime(entry.time)} · $level · ${entry.logger}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: m3e.typeScale.bodySmall.copyWith(
                    color: m3e.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(entry.message, style: m3e.typeScale.bodyMedium),
                if (entry.detail case final detail? when detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: m3e.typeScale.bodySmall.copyWith(
                      color: m3e.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
