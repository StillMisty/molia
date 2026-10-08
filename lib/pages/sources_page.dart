import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'any_listen_page.dart';
import '../domain/models/source.dart' show SourceKind;
import '../domain/models/source_script.dart';
import '../l10n/app_localizations.dart';
import '../providers/sources_provider.dart';
import '../theme/app_semantic_colors.dart';

/// AppLocalizations 查找：集成测试等场景会直接挂载本页而不注册 delegate，
/// 此时回退到简体中文，保证与中文正式环境文案一致（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 音源管理页：导入 / 启停 / 删除 LX Music 音源脚本，设置默认音质。
///
/// 分层（Wave 7）：只依赖 [SourcesProvider] 与 domain 模型，
/// 不直接 import `lib/sources/**`（R5）。
class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key});

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  /// 正在执行在线更新的脚本 id（同一时间只允许一个，按钮显示 loading）。
  String? _updatingScriptId;

  /// URL 导入下载中（对应列表项禁用并显示进度）。
  bool _importingFromUrl = false;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.sourcesTitle),
        automaticallyImplyLeading: true,
        actions: [
          M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            tooltip: l10n.anyListenEntry,
            icon: const Icon(Icons.cloud_rounded),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AnyListenPage(
                    provider: context.read<SourcesProvider>(),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<SourcesProvider>(
        builder: (context, provider, _) {
          if (kIsWeb) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.sourcesWebUnsupported),
              ),
            );
          }
          if (!provider.initialized) {
            return const Center(child: M3ELoadingIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildStatusCard(context, provider),
              const SizedBox(height: 16),
              _buildImportCard(context, provider),
              const SizedBox(height: 16),
              _buildQualityCard(context, provider),
              const SizedBox(height: 16),
              _buildSortCard(context, provider),
              const SizedBox(height: 16),
              _buildScriptsCard(context, provider),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusCard(BuildContext context, SourcesProvider provider) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final semantic = AppSemanticColors.of(context);
    final active = provider.activeScript;
    final sources = provider.activeSourceEntries;
    return M3ECard(
      variant: M3ECardVariant.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                provider.hasActiveSource
                    ? Icons.check_circle_rounded
                    : Icons.error_outline_rounded,
                // 成功态走统一语义色（不再硬编码 Colors.green）。
                color: provider.hasActiveSource
                    ? semantic.success
                    : theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  active == null
                      ? l10n.sourcesNoneActive
                      : l10n.sourcesActiveSource(active.name, active.version),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (provider.isActivating) ...[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: M3EProgressIndicator.circular(
                    size: 18,
                    strokeWidth: 2,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.sourcesActivating,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
          if (provider.activeError != null) ...[
            const SizedBox(height: 8),
            Text(
              l10n.sourcesActivationFailed(provider.activeError!),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          if (active != null && active.author.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              l10n.sourcesAuthor(active.author),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (sources.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: sources
                  .map((decl) => M3EChip(
                        type: M3EChipType.assist,
                        label: '${decl.name} · ${decl.actions.join('/')}',
                        onPressed: () {},
                      ))
                  .toList(),
            ),
          ],
          if (provider.lastUpdateAlert != null) ...[
            const SizedBox(height: 12),
            Material(
              // 「有可用更新」是提醒语义：统一 warning 容器色。
              color: semantic.warningContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.sourcesUpdateAlertTitle,
                      style: TextStyle(
                        color: semantic.onWarningContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      provider.lastUpdateAlert!.log,
                      style: TextStyle(color: semantic.onWarningContainer),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (active != null && active.hasUpdateUrl)
                          M3EButton.filled(
                            onPressed: _updatingScriptId != null
                                ? null
                                : () => _updateScript(
                                      context,
                                      provider,
                                      active,
                                      fromAlert: true,
                                    ),
                            child: _updatingScriptId == active.id
                                ? _updatingLabel(l10n)
                                : Text(l10n.sourcesUpdateNow),
                          ),
                        if (provider.lastUpdateAlert!.updateUrl != null)
                          M3EButton.text(
                            onPressed: () => launchUrl(
                                Uri.parse(provider.lastUpdateAlert!.updateUrl!)),
                            child: Text(l10n.sourcesOpenUpdateUrl),
                          ),
                        M3EButton.text(
                          onPressed: provider.clearUpdateAlert,
                          child: Text(l10n.sourcesUpdateDismiss),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImportCard(BuildContext context, SourcesProvider provider) {
    final l10n = _l10n(context);
    return M3ECard(
      variant: M3ECardVariant.elevated,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          M3EListItem(
            leading: const Icon(Icons.file_open_rounded),
            headline: l10n.sourcesImportFromFile,
            supportingText: l10n.sourcesImportFromFileSubtitle,
            onTap: () => _importFromFile(context, provider),
          ),
          const M3EDivider(),
          M3EListItem(
            leading: const Icon(Icons.edit_note_rounded),
            headline: l10n.sourcesImportFromText,
            supportingText: l10n.sourcesImportFromTextSubtitle,
            onTap: () => _importFromText(context, provider),
          ),
          const M3EDivider(),
          M3EListItem(
            leading: const Icon(Icons.link_rounded),
            headline: l10n.sourcesImportFromUrl,
            supportingText: l10n.sourcesImportFromUrlSubtitle,
            enabled: !_importingFromUrl,
            onTap: _importingFromUrl
                ? null
                : () => _importFromUrl(context, provider),
            trailing: _importingFromUrl
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: M3EProgressIndicator.circular(
                      size: 18,
                      strokeWidth: 2,
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildQualityCard(BuildContext context, SourcesProvider provider) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    return M3ECard(
      variant: M3ECardVariant.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.sourcesDefaultQuality,
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: provider.qualityOptions
                .map((option) => M3EChip(
                      type: M3EChipType.filter,
                      label: _qualityDisplayName(l10n, option),
                      selected: provider.preferredQuality == option.value,
                      onPressed: () =>
                          provider.setPreferredQuality(option.value),
                    ))
                .toList(),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.sourcesQualityHint,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildSortCard(BuildContext context, SourcesProvider provider) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    // 渠道 = 可搜索源 + 内置发现平台的并集（含停用项，便于再次启用）。
    final channels = provider.channels;
    return M3ECard(
      variant: M3ECardVariant.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.sourcesSortTitle,
                    style: theme.textTheme.titleMedium),
              ),
              if (provider.sourceOrder.isNotEmpty)
                M3EButton.text(
                  onPressed: provider.resetChannelOrder,
                  child: Text(l10n.sourcesSortReset),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.sourcesSortHint,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (channels.isEmpty)
            Text(l10n.sourcesNoSearchableSources)
          else
            ...List.generate(channels.length, (index) {
              final entry = channels[index];
              final kindLabel = entry.kind == SourceKind.lx
                  ? l10n.sourcesKindLx
                  : l10n.sourcesKindBuiltin;
              final supporting = StringBuffer(
                '${index + 1}. ${entry.key} · $kindLabel',
              );
              if (!entry.enabled) {
                supporting.write(' · ${l10n.sourcesChannelDisabled}');
              }
              return M3EListItem(
                leading: M3ESwitch(
                  value: entry.enabled,
                  semanticLabel: entry.name,
                  onChanged: (value) =>
                      provider.setChannelEnabled(entry.key, value),
                ),
                headline: entry.name,
                supportingText: supporting.toString(),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    M3EIconButton(
                      variant: M3EIconButtonVariant.standard,
                      tooltip: l10n.sourcesMoveUp,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                      onPressed: index > 0
                          ? () => provider.moveChannel(entry.key, -1)
                          : null,
                    ),
                    M3EIconButton(
                      variant: M3EIconButtonVariant.standard,
                      tooltip: l10n.sourcesMoveDown,
                      icon: const Icon(Icons.arrow_downward_rounded, size: 20),
                      onPressed: index < channels.length - 1
                          ? () => provider.moveChannel(entry.key, 1)
                          : null,
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildScriptsCard(BuildContext context, SourcesProvider provider) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final scripts = provider.scripts;
    return M3ECard(
      variant: M3ECardVariant.elevated,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(l10n.sourcesImportedScripts(scripts.length),
                style: theme.textTheme.titleMedium),
          ),
          if (scripts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.sourcesNoScripts),
            )
          else
            ...scripts.map((script) {
              final isActive = provider.activeScriptId == script.id;
              return M3EListItem(
                leading: Icon(
                  isActive
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: isActive ? theme.colorScheme.primary : null,
                ),
                headline: script.name,
                supportingText: [
                  if (script.version.isNotEmpty) script.version,
                  if (script.author.isNotEmpty)
                    l10n.sourcesScriptByAuthor(script.author),
                  if (script.description.isNotEmpty) script.description,
                ].join(' · '),
                onTap: isActive
                    ? null
                    : () => _activate(context, provider, script),
                trailing: M3EMenu.entries(
                  position: M3EMenuAnchorPosition.bottomEnd,
                  anchorBuilder: (context, open) => M3EIconButton(
                    variant: M3EIconButtonVariant.standard,
                    icon: Icon(Icons.more_vert_rounded),
                    onPressed: open,
                  ),
                  onSelected: (value) {
                    if (value == 'delete') {
                      _confirmDelete(context, provider, script);
                    } else if (value == 'activate') {
                      _activate(context, provider, script);
                    } else if (value == 'deactivate') {
                      provider.deactivate();
                    } else if (value == 'update') {
                      _updateScript(context, provider, script);
                    }
                  },
                  entries: [
                    if (!isActive)
                      M3EMenuEntry(
                        label: l10n.sourcesEnable,
                        value: 'activate',
                      ),
                    if (isActive)
                      M3EMenuEntry(
                        label: l10n.sourcesDisable,
                        value: 'deactivate',
                      ),
                    if (script.hasUpdateUrl)
                      M3EMenuEntry(
                        label: l10n.sourcesUpdateNow,
                        value: 'update',
                        enabled: _updatingScriptId == null,
                      ),
                    M3EMenuEntry(
                      label: l10n.delete,
                      value: 'delete',
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _activate(
    BuildContext context,
    SourcesProvider provider,
    SourceScriptInfo script,
  ) async {
    final l10n = _l10n(context);
    try {
      await provider.activate(script.id);
      if (context.mounted) {
        M3ESnackbar.show(
            context, message: l10n.sourcesActivated(script.name));
      }
    } catch (e) {
      if (context.mounted) {
        M3ESnackbar.show(
            context, message: l10n.sourcesActivateFailed('$e'));
      }
    }
  }

  /// 一键在线更新：检查 → 应用 → SnackBar 反馈（按钮 loading 由调用方渲染）。
  ///
  /// [fromAlert] 为 true 时成功后清除更新提示卡（提示已处理完毕）。
  Future<void> _updateScript(
    BuildContext context,
    SourcesProvider provider,
    SourceScriptInfo script, {
    bool fromAlert = false,
  }) async {
    if (_updatingScriptId != null) return;
    final l10n = _l10n(context);
    setState(() => _updatingScriptId = script.id);
    try {
      final check = await provider.checkScriptUpdate(script.id);
      if (!check.hasUpdate) {
        if (context.mounted) {
          M3ESnackbar.show(context, message: l10n.sourcesUpdateNoUpdate);
        }
        return;
      }
      final updated = await provider.applyScriptUpdate(script.id);
      if (context.mounted) {
        M3ESnackbar.show(
          context,
          message: l10n.sourcesUpdateSuccess(
              updated.version.isEmpty ? updated.name : updated.version),
        );
      }
      if (fromAlert) provider.clearUpdateAlert();
    } catch (e) {
      final message = e is SourceScriptException && e.htmlPage
          ? l10n.sourcesUpdateManualHint
          : l10n.sourcesUpdateFailed(_readableError(e));
      if (context.mounted) {
        M3ESnackbar.show(context, message: message);
      }
    } finally {
      if (mounted) setState(() => _updatingScriptId = null);
    }
  }

  Widget _updatingLabel(AppLocalizations l10n) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: M3EProgressIndicator.circular(size: 16, strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(l10n.sourcesUpdating),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    SourcesProvider provider,
    SourceScriptInfo script,
  ) async {
    final l10n = _l10n(context);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.sourcesDeleteScriptTitle,
        content: Text(l10n.sourcesDeleteScriptConfirm(script.name)),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await provider.removeScript(script.id);
    }
  }

  Future<bool> _showDisclaimer(BuildContext context) async {
    final l10n = _l10n(context);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.sourcesDisclaimerTitle,
        content: Text(l10n.sourcesDisclaimerBody),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.sourcesContinueImport),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _importFromFile(
    BuildContext context,
    SourcesProvider provider,
  ) async {
    final l10n = _l10n(context);
    if (!await _showDisclaimer(context)) return;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['js', 'txt'],
      );
      if (files.isEmpty) return;
      final bytes = await files.first.readAsBytes();
      if (bytes.isEmpty) return;
      final script = _decodeScript(bytes);
      if (script == null) return;
      await provider.importScript(script, activate: true);
    } catch (e) {
      if (context.mounted) {
        M3ESnackbar.show(
            context, message: l10n.sourcesImportFailed('$e'));
      }
    }
  }

  Future<void> _importFromText(
    BuildContext context,
    SourcesProvider provider,
  ) async {
    final l10n = _l10n(context);
    final controller = TextEditingController();
    final script = await M3EDialog.show<String>(
      context,
      dialog: M3EDialog(
        title: l10n.sourcesPasteTitle,
        content: SizedBox(
          width: 480,
          child: M3ETextField(
            controller: controller,
            maxLines: 12,
            variant: M3ETextFieldVariant.outlined,
            placeholder: l10n.sourcesPasteHint,
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.sourcesImportAction),
          ),
        ],
      ),
    );
    if (script == null || script.trim().isEmpty) return;
    if (!context.mounted) return;
    if (!await _showDisclaimer(context)) return;
    try {
      await provider.importScript(script, activate: true);
    } catch (e) {
      if (context.mounted) {
        M3ESnackbar.show(
            context, message: l10n.sourcesImportFailed('$e'));
      }
    }
  }

  Future<void> _importFromUrl(
    BuildContext context,
    SourcesProvider provider,
  ) async {
    final l10n = _l10n(context);
    final controller = TextEditingController();
    final input = await M3EDialog.show<String>(
      context,
      dialog: M3EDialog(
        title: l10n.sourcesImportFromUrl,
        content: SizedBox(
          width: 420,
          child: M3ETextField(
            controller: controller,
            variant: M3ETextFieldVariant.outlined,
            placeholder: 'https://example.com/source.js',
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.sourcesDownloadAndImport),
          ),
        ],
      ),
    );
    if (input == null || input.trim().isEmpty) return;
    if (!mounted) return;
    if (!await _showDisclaimer(this.context)) return;
    if (!mounted) return;
    setState(() => _importingFromUrl = true);
    try {
      await provider.importFromUrl(input);
    } catch (e) {
      if (mounted) {
        M3ESnackbar.show(
            this.context,
            message: l10n.sourcesImportFailed(_readableError(e)));
      }
    } finally {
      if (mounted) setState(() => _importingFromUrl = false);
    }
  }

  String? _decodeScript(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

/// 从异常中提取可读原因（去掉 `Exception: ` 前缀；领域异常直接用 message）。
String _readableError(Object error) {
  if (error is SourceScriptException) return error.message;
  final text = error.toString();
  const prefix = 'Exception: ';
  return text.startsWith(prefix) ? text.substring(prefix.length) : text;
}

/// 音质显示名（[SourceQualityOption.value] 的界面文案）；
/// 未知音质沿用领域层的通用显示名。
String _qualityDisplayName(AppLocalizations l10n, SourceQualityOption option) {
  switch (option.value) {
    case 'flac24bit':
      return l10n.sourcesQualityHiRes;
    case 'flac':
      return l10n.sourcesQualityLossless;
    case 'wav':
      return l10n.sourcesQualityWav;
    case 'ape':
      return l10n.sourcesQualityApe;
    case '320k':
      return l10n.sourcesQuality320k;
    case '192k':
      return l10n.sourcesQuality192k;
    case '128k':
      return l10n.sourcesQuality128k;
    default:
      return option.displayName;
  }
}
