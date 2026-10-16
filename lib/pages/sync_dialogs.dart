import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../data/sync/sync_state_store.dart';
import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_labels.dart';
import 'sync_peers_page.dart';

/// WebDAV 配置弹层（设置页与日志子页共用；密码单独走安全存储）。
Future<void> showWebdavConfigDialog(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  final password = await provider.readWebdavPassword() ?? '';
  if (!context.mounted) return;
  final config = provider.webdav;
  final server = TextEditingController(text: config.baseUrl);
  final username = TextEditingController(text: config.username);
  final passwordController = TextEditingController(text: password);
  final remoteDir = TextEditingController(text: config.remoteDir);
  final navigator = Navigator.of(context, rootNavigator: true);

  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.syncWebdavConfigTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              M3ETextField(
                controller: server,
                label: l10n.syncWebdavServer,
                placeholder: 'https://dav.example.com/dav',
                leading: const Icon(Icons.link_rounded),
              ),
              const SizedBox(height: 12),
              M3ETextField(
                controller: username,
                label: l10n.syncWebdavUsername,
                leading: const Icon(Icons.person_rounded),
              ),
              const SizedBox(height: 12),
              M3ETextField(
                controller: passwordController,
                label: l10n.syncWebdavPassword,
                obscureText: true,
                leading: const Icon(Icons.key_rounded),
              ),
              const SizedBox(height: 12),
              M3ETextField(
                controller: remoteDir,
                label: l10n.syncWebdavRemoteDir,
                leading: const Icon(Icons.folder_rounded),
              ),
            ],
          ),
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
        M3EButton.filled(
          onPressed: () async {
            await provider.setWebdavConfig(WebDavConfig(
              baseUrl: server.text.trim(),
              username: username.text.trim(),
              remoteDir: remoteDir.text.trim().isEmpty
                  ? 'molia-sync'
                  : remoteDir.text.trim(),
            ));
            await provider.setWebdavPassword(passwordController.text);
            navigator.pop();
          },
          child: Text(l10n.syncSave),
        ),
      ],
    ),
  );
  server.dispose();
  username.dispose();
  passwordController.dispose();
  remoteDir.dispose();
}

/// 失败原因对应的下一步动作（重试 / 去授权 / 去配置 / 改用 WebDAV / 添加手动地址）。
enum SyncIssueAction {
  retry,
  grantPermission,
  configureWebdav,
  configurePassphrase,
  addManualPeer,
  useWebdav,
}

/// 按失败原因给动作，不留死胡同；未知原因至少给「重试」。
List<SyncIssueAction> syncIssueActions(SyncIssue? issue) => switch (issue?.code) {
      SyncIssueCode.permissionDenied => const [
          SyncIssueAction.useWebdav,
          SyncIssueAction.grantPermission,
        ],
      SyncIssueCode.noPassphrase => const [
          SyncIssueAction.configurePassphrase,
          SyncIssueAction.retry,
        ],
      SyncIssueCode.notConfigured ||
      SyncIssueCode.webdavDirFailed ||
      SyncIssueCode.webdavListFailed ||
      SyncIssueCode.webdavReadFailed ||
      SyncIssueCode.webdavDecryptFailed ||
      SyncIssueCode.webdavUploadFailed =>
        const [SyncIssueAction.configureWebdav, SyncIssueAction.retry],
      // 局域网发现 / 读取失败：手动地址与 WebDAV 是两条真实出路（权限被拒
      // 时手动地址无效，那种情况由 permissionDenied 分支覆盖）。
      SyncIssueCode.startFailed ||
      SyncIssueCode.broadcastUnavailable ||
      SyncIssueCode.discoverySilent ||
      SyncIssueCode.peerReadFailed ||
      SyncIssueCode.peerDecryptFailed ||
      SyncIssueCode.peerPushFailed ||
      SyncIssueCode.allPeersUnreachable =>
        const [
          SyncIssueAction.addManualPeer,
          SyncIssueAction.useWebdav,
          SyncIssueAction.retry,
        ],
      _ => const [SyncIssueAction.retry],
    };

/// 失败详情弹层：原因文案 + 按原因给动作（重试 / 去授权 / 去配置）。
///
/// [onConfigurePassphrase] 由设置页注入（口令弹层在设置页）；日志子页缺省时
/// 走 SnackBar 指引，不留下无出口的按钮。
Future<void> showSyncIssueDialog(
  BuildContext context, {
  required SyncProvider provider,
  required SyncIssue? issue,
  required AppLocalizations l10n,
  Future<void> Function()? onConfigurePassphrase,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final actions = syncIssueActions(issue);
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.syncIssueDialogTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Text(
          issue == null ? l10n.syncIssueUnknown : syncIssueText(l10n, issue),
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
        for (var i = 0; i < actions.length; i++)
          _actionButton(
            context,
            provider: provider,
            l10n: l10n,
            action: actions[i],
            primary: i == actions.length - 1,
            onConfigurePassphrase: onConfigurePassphrase,
          ),
      ],
    ),
  );
}

Widget _actionButton(
  BuildContext context, {
  required SyncProvider provider,
  required AppLocalizations l10n,
  required SyncIssueAction action,
  required bool primary,
  Future<void> Function()? onConfigurePassphrase,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  void run(Future<void> Function() body) {
    navigator.pop();
    unawaited(body());
  }

  final (String label, Future<void> Function() body) = switch (action) {
    SyncIssueAction.retry => (
        l10n.syncRetry,
        () => provider.syncNow(manual: true),
      ),
    SyncIssueAction.grantPermission => provider.lanPermissionPermanentlyDenied
        ? (
            l10n.syncOpenSystemSettings,
            () => provider.openSystemSettings(),
          )
        : (
            l10n.syncActionGrantPermission,
            () => _grantLanPermission(context, provider, l10n),
          ),
    SyncIssueAction.configureWebdav => (
        l10n.syncActionConfigure,
        () => showWebdavConfigDialog(context, provider, l10n),
      ),
    SyncIssueAction.configurePassphrase => (
        l10n.syncActionConfigurePassphrase,
        () => onConfigurePassphrase != null
            ? onConfigurePassphrase()
            : _hintSettingsPage(context, l10n),
      ),
    SyncIssueAction.addManualPeer => (
        l10n.syncActionAddManualPeer,
        () => openSettingsSubPage(context, const SyncPeersPage()),
      ),
    SyncIssueAction.useWebdav => (
        l10n.syncActionUseWebdav,
        () => _useWebdav(context, provider, l10n),
      ),
  };
  // 最后一个动作是主推荐（filled），其余为文字按钮。
  return primary
      ? M3EButton.filled(
          onPressed: () => run(body),
          child: Text(label),
        )
      : M3EButton.text(
          onPressed: () => run(body),
          child: Text(label),
        );
}

/// 显式申请权限；仍被拒时给「去系统设置」的下一步动作。
Future<void> _grantLanPermission(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  final granted = await provider.requestLanPermission();
  if (granted || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(l10n.syncLanPermissionDenied),
      action: SnackBarAction(
        label: l10n.syncOpenSystemSettings,
        onPressed: () => unawaited(provider.openSystemSettings()),
      ),
    ),
  );
}

/// 启用 WebDAV；未配置时顺势打开配置弹层（用户少点一步）。
Future<void> _useWebdav(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  await provider.setTransportEnabled(SyncTransportKind.webdav, true);
  if (!context.mounted) return;
  if (provider.webdav.isConfigured) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.syncWebdavEnabled)));
    return;
  }
  await showWebdavConfigDialog(context, provider, l10n);
}

Future<void> _hintSettingsPage(
  BuildContext context,
  AppLocalizations l10n,
) async {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(l10n.syncConfigureOnSettingsPage)));
}
