import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'any_listen_page.dart';
import '../domain/models/bili_account.dart';
import '../domain/models/source.dart' show SourceKind;
import '../domain/models/source_script.dart';
import '../l10n/app_localizations.dart';
import '../providers/sources_provider.dart';
import '../services/bili_account_service.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/settings/settings_reorderable_rows.dart';
import '../widgets/settings/settings_tiles.dart';
import 'bili_account_page.dart';

/// AppLocalizations 查找：集成测试等场景会直接挂载本页而不注册 delegate，
/// 此时回退到简体中文，保证与中文正式环境文案一致（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 音源管理页：LX 脚本导入 / 启停 / 排序 / 删除 + 内置平台账号（哔哩哔哩）。
///
/// 与设置页共用同一套 M3E 语言：`SettingsSectionCard` + 设置行
/// （`CardListSurface` 形状、`cardList.gap` 行距、`M3ETypeScale` 排版），
/// 渠道排序复用 [SettingsReorderableRows] 的拖拽手柄模式。
/// 分层：只依赖 [SourcesProvider] / 平台账号服务与 domain 模型，
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
            semanticLabel: l10n.anyListenEntry,
            icon: const Icon(Icons.cloud_rounded),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AnyListenPage(provider: context.read<SourcesProvider>()),
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<SourcesProvider>(
        builder: (context, provider, _) {
          final biliAccount = context.watch<BiliAccountService?>();
          if (!provider.initialized) {
            return const Center(child: M3ELoadingIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(kSettingsPadding),
            children: [
              _buildStatusSection(context, l10n, provider),
              if (biliAccount != null) ...[
                const SizedBox(height: kSettingsSectionSpacing),
                _buildPlatformAccountsSection(context, l10n, biliAccount),
              ],
              const SizedBox(height: kSettingsSectionSpacing),
              _buildImportSection(context, l10n, provider),
              const SizedBox(height: kSettingsSectionSpacing),
              _buildSortSection(context, l10n, provider),
              const SizedBox(height: kSettingsSectionSpacing),
              _buildScriptsSection(context, l10n, provider),
            ],
          );
        },
      ),
    );
  }

  /// 内置平台账号：目前只有 B 站（登录后字幕歌词同源优先）。
  Widget _buildPlatformAccountsSection(
    BuildContext context,
    AppLocalizations l10n,
    BiliAccountService account,
  ) {
    final loggedIn = account.status == BiliAccountStatus.loggedIn;
    return SettingsSectionCard(
      title: l10n.sourcesPlatformAccounts,
      children: [
        SettingsNavTile(
          key: const Key('sourcesBiliAccountItem'),
          icon: Icons.account_circle_rounded,
          title: l10n.biliAccountTitle,
          subtitle: loggedIn
              ? l10n.biliAccountTileLoggedIn
              : l10n.biliAccountTileLoggedOut,
          onTap: () => openSettingsSubPage(context, const BiliAccountPage()),
        ),
      ],
    );
  }

  /// 当前状态：状态图标 + 当前音源/错误/作者 + 源能力 chips；有更新提示时
  /// 同组追加警告色的提示行（按钮就地处理）。
  Widget _buildStatusSection(
    BuildContext context,
    AppLocalizations l10n,
    SourcesProvider provider,
  ) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final semantic = AppSemanticColors.of(context);
    final active = provider.activeScript;
    final sources = provider.activeSourceEntries;
    final hasActive = provider.hasActiveSource;
    final alert = provider.lastUpdateAlert;

    final Widget statusRow = CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      onPressed: null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTileIcon(
            icon: hasActive
                ? Icons.check_circle_rounded
                : Icons.error_outline_rounded,
            containerColor: hasActive
                ? semantic.successContainer
                : scheme.errorContainer,
            foregroundColor: hasActive
                ? semantic.onSuccessContainer
                : scheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        active == null
                            ? l10n.sourcesNoneActive
                            : l10n.sourcesActiveSource(
                                active.name,
                                active.version,
                              ),
                        style: m3e.typeScale.bodyLarge.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (provider.isActivating) ...[
                      const SizedBox(width: kSettingsSmallSpacing),
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: M3EProgressIndicator.circular(
                          size: 18,
                          strokeWidth: 2,
                        ),
                      ),
                      const SizedBox(width: kSettingsSmallSpacing),
                      Text(
                        l10n.sourcesActivating,
                        style: m3e.typeScale.bodySmall.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                if (provider.activeError != null)
                  Text(
                    l10n.sourcesActivationFailed(provider.activeError!),
                    style: m3e.typeScale.bodySmall.copyWith(
                      color: scheme.error,
                    ),
                  ),
                if (active != null && active.author.isNotEmpty)
                  Text(
                    l10n.sourcesAuthor(active.author),
                    style: m3e.typeScale.bodySmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (sources.isNotEmpty) ...[
                  const SizedBox(height: kSettingsSmallSpacing),
                  Wrap(
                    spacing: kSettingsSmallSpacing,
                    runSpacing: kSettingsSmallSpacing,
                    children: [
                      for (final decl in sources)
                        M3EChip(
                          type: M3EChipType.assist,
                          label: '${decl.name} · ${decl.actions.join('/')}',
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return SettingsSectionCard(
      title: l10n.sourcesStatusSection,
      children: [
        statusRow,
        if (alert != null)
          CardListSurface(
            position: SettingsRowPosition.of(context),
            padding: kSettingsRowPadding,
            // 「有可用更新」是提醒语义：统一 warning 容器色。
            color: semantic.warningContainer,
            onPressed: null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 20,
                      color: semantic.onWarningContainer,
                    ),
                    const SizedBox(width: kSettingsSmallSpacing),
                    Expanded(
                      child: Text(
                        l10n.sourcesUpdateAlertTitle,
                        style: m3e.typeScale.titleSmall.copyWith(
                          color: semantic.onWarningContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  alert.log,
                  style: m3e.typeScale.bodySmall.copyWith(
                    color: semantic.onWarningContainer,
                  ),
                ),
                const SizedBox(height: kSettingsSmallSpacing),
                _buildUpdateAlertActions(context, l10n, provider, active),
              ],
            ),
          ),
      ],
    );
  }

  /// 导入脚本：三条导航行（文件 / 粘贴 / 链接），链接导入进行中给行尾进度。
  Widget _buildImportSection(
    BuildContext context,
    AppLocalizations l10n,
    SourcesProvider provider,
  ) {
    return SettingsSectionCard(
      title: l10n.sourcesImportSection,
      children: [
        SettingsNavTile(
          key: const Key('sourcesImportFileItem'),
          icon: Icons.file_open_rounded,
          title: l10n.sourcesImportFromFile,
          subtitle: l10n.sourcesImportFromFileSubtitle,
          onTap: () => _importFromFile(context, provider),
        ),
        SettingsNavTile(
          key: const Key('sourcesImportTextItem'),
          icon: Icons.edit_note_rounded,
          title: l10n.sourcesImportFromText,
          subtitle: l10n.sourcesImportFromTextSubtitle,
          onTap: () => _importFromText(context, provider),
        ),
        SettingsNavTile(
          key: const Key('sourcesImportUrlItem'),
          icon: Icons.link_rounded,
          title: l10n.sourcesImportFromUrl,
          subtitle: l10n.sourcesImportFromUrlSubtitle,
          // 下载中禁用整行并显示进度（点按不再重复发起）。
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
    );
  }

  /// 渠道排序：拖拽手柄排序 + 启停开关；有自定义顺序时给「重置」动作行。
  Widget _buildSortSection(
    BuildContext context,
    AppLocalizations l10n,
    SourcesProvider provider,
  ) {
    // 渠道 = 可搜索源 + 内置发现平台的并集（含停用项，便于再次启用）。
    final channels = provider.channels;
    return SettingsSectionCard(
      title: l10n.sourcesSortTitle,
      // 空态解释（无渠道）与排序规则提示共用卡片下方说明位。
      footer: channels.isEmpty
          ? SettingsSectionHint(text: l10n.sourcesNoSearchableSources)
          : SettingsSectionHint(text: l10n.sourcesSortHint),
      children: [
        if (channels.isNotEmpty)
          SettingsReorderableRows(
            itemCount: channels.length,
            itemKey: (index) => ValueKey(channels[index].key),
            itemBuilder: (context, index) =>
                _channelRow(context, l10n, provider, channels[index], index),
            onReorder: provider.reorderChannel,
          ),
        // 重置动作只在有自定义顺序时出现（默认顺序下重置无意义）。
        if (provider.sourceOrder.isNotEmpty)
          SettingsNavTile(
            key: const Key('sourcesSortResetItem'),
            icon: Icons.restart_alt_rounded,
            title: l10n.sourcesSortReset,
            subtitle: l10n.sourcesSortResetSubtitle,
            onTap: provider.resetChannelOrder,
          ),
      ],
    );
  }

  /// 单个渠道行：开关（启停）+ 行尾拖拽手柄（排序），行序即发现页/搜索顺序。
  Widget _channelRow(
    BuildContext context,
    AppLocalizations l10n,
    SourcesProvider provider,
    SourceEntry entry,
    int index,
  ) {
    final kindLabel = entry.kind == SourceKind.lx
        ? l10n.sourcesKindLx
        : l10n.sourcesKindBuiltin;
    final supporting = StringBuffer('${index + 1}. ${entry.key} · $kindLabel');
    if (!entry.enabled) {
      supporting.write(' · ${l10n.sourcesChannelDisabled}');
    }
    return SettingsSwitchTile(
      switchKey: ValueKey('sourcesChannelSwitch_${entry.key}'),
      icon: entry.kind == SourceKind.lx
          ? Icons.code_rounded
          : Icons.radio_rounded,
      title: entry.name,
      subtitle: supporting.toString(),
      value: entry.enabled,
      onChanged: (value) => provider.setChannelEnabled(entry.key, value),
      trailing: ReorderableDragStartListener(
        index: index,
        child: Icon(
          Icons.drag_handle_rounded,
          color: M3ETheme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 已导入脚本：开关启停 + 行尾菜单（更新 / 删除）；空态在卡片下方给引导。
  Widget _buildScriptsSection(
    BuildContext context,
    AppLocalizations l10n,
    SourcesProvider provider,
  ) {
    final scripts = provider.scripts;
    return SettingsSectionCard(
      title: l10n.sourcesImportedScripts(scripts.length),
      footer: scripts.isEmpty
          ? SettingsSectionHint(text: l10n.sourcesNoScripts)
          : null,
      children: [
        for (final script in scripts)
          _scriptRow(context, l10n, provider, script),
      ],
    );
  }

  Widget _scriptRow(
    BuildContext context,
    AppLocalizations l10n,
    SourcesProvider provider,
    SourceScriptInfo script,
  ) {
    final isActive = provider.activeScriptId == script.id;
    return SettingsSwitchTile(
      switchKey: ValueKey('sourcesScriptSwitch_${script.id}'),
      icon: Icons.code_rounded,
      title: script.name,
      subtitle: [
        if (script.version.isNotEmpty) script.version,
        if (script.author.isNotEmpty) l10n.sourcesScriptByAuthor(script.author),
        if (script.description.isNotEmpty) script.description,
      ].join(' · '),
      value: isActive,
      // 激活进行中禁用整行：避免并发切换脚本与引擎重启打架。
      enabled: !provider.isActivating,
      onChanged: (value) {
        if (value) {
          unawaited(_activate(context, provider, script));
        } else {
          unawaited(provider.deactivate());
        }
      },
      trailing: M3EMenu.entries(
        position: M3EMenuAnchorPosition.bottomEnd,
        anchorBuilder: (context, open) => M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.more_vert_rounded),
          semanticLabel: l10n.sourcesScriptActions,
          onPressed: open,
        ),
        onSelected: (value) {
          if (value == 'delete') {
            _confirmDelete(context, provider, script);
          } else if (value == 'update') {
            _updateScript(context, provider, script);
          }
        },
        entries: [
          if (script.hasUpdateUrl)
            M3EMenuEntry(
              label: l10n.sourcesUpdateNow,
              value: 'update',
              enabled: _updatingScriptId == null,
            ),
          M3EMenuEntry(
            label: l10n.delete,
            value: 'delete',
            isDestructive: true,
          ),
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
        M3ESnackbar.show(context, message: l10n.sourcesActivated(script.name));
      }
    } catch (e) {
      if (context.mounted) {
        M3ESnackbar.show(context, message: l10n.sourcesActivateFailed('$e'));
      }
    }
  }

  /// 一键在线更新：检查 → 应用 → SnackBar 反馈（按钮 loading 由调用方渲染）。
  ///
  /// [fromAlert] 为 true 时成功后清除更新提示行（提示已处理完毕）。
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
            updated.version.isEmpty ? updated.name : updated.version,
          ),
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

  /// 更新提示卡的动作行：三个动作同权重（更新 / 打开地址 / 忽略），
  /// 统一走 button group，按下即分发命令（selectedIndex 恒空、不留选中态）。
  ///
  /// 动作随状态增删（脚本无 updateUrl / 提示无网址时不出现），因此用
  /// 并列的 handlers 按下标分发，不依赖固定顺序。
  Widget _buildUpdateAlertActions(
    BuildContext context,
    AppLocalizations l10n,
    SourcesProvider provider,
    SourceScriptInfo? active,
  ) {
    final alert = provider.lastUpdateAlert!;
    final handlers = <VoidCallback>[];
    final actions = <M3EButtonGroupAction>[];

    if (active != null && active.hasUpdateUrl) {
      handlers.add(
        () => _updateScript(context, provider, active, fromAlert: true),
      );
      actions.add(
        M3EButtonGroupAction(
          icon: const Icon(Icons.system_update_alt_rounded),
          label: _updatingScriptId == active.id
              ? _updatingLabel(l10n)
              : Text(l10n.sourcesUpdateNow),
          enabled: _updatingScriptId == null,
        ),
      );
    }

    final updateUrl = alert.updateUrl;
    if (updateUrl != null) {
      handlers.add(() => launchUrl(Uri.parse(updateUrl)));
      actions.add(
        M3EButtonGroupAction(
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(l10n.sourcesOpenUpdateUrl),
        ),
      );
    }

    handlers.add(provider.clearUpdateAlert);
    actions.add(
      M3EButtonGroupAction(
        icon: const Icon(Icons.close_rounded),
        label: Text(l10n.sourcesUpdateDismiss),
      ),
    );

    return M3EButtonGroup(
      type: M3EButtonGroupType.standard,
      style: M3EButtonStyle.tonal,
      actions: actions,
      onSelectedIndexChanged: (index) {
        if (index != null) handlers[index]();
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    SourcesProvider provider,
    SourceScriptInfo script,
  ) async {
    final l10n = _l10n(context);
    // 弹层 dialog 挂 root navigator（M3EDialog.show 语义）；本页位于设置弹层
    // 的嵌套 Navigator 内，页面 context 上的 pop 会误退本页，关闭要显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.sourcesDeleteScriptTitle,
        content: Text(l10n.sourcesDeleteScriptConfirm(script.name)),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
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
    // 同 _confirmDelete：弹层在 root navigator，关闭需显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.sourcesDisclaimerTitle,
        content: Text(l10n.sourcesDisclaimerBody),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
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
        M3ESnackbar.show(context, message: l10n.sourcesImportFailed('$e'));
      }
    }
  }

  Future<void> _importFromText(
    BuildContext context,
    SourcesProvider provider,
  ) async {
    final l10n = _l10n(context);
    final controller = TextEditingController();
    // 同 _confirmDelete：弹层在 root navigator，关闭需显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
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
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(controller.text),
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
        M3ESnackbar.show(context, message: l10n.sourcesImportFailed('$e'));
      }
    }
  }

  Future<void> _importFromUrl(
    BuildContext context,
    SourcesProvider provider,
  ) async {
    final l10n = _l10n(context);
    final controller = TextEditingController();
    // 同 _confirmDelete：弹层在 root navigator，关闭需显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
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
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(controller.text.trim()),
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
          message: l10n.sourcesImportFailed(_readableError(e)),
        );
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
