import 'dart:async';

import 'package:flutter/services.dart';
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
///
/// 列表最后一项是主推荐（弹层的 filled 确认按钮），其余收进内容区。
List<SyncIssueAction> syncIssueActions(SyncIssue? issue) => switch (issue?.code) {
      SyncIssueCode.permissionDenied => const [
          SyncIssueAction.useWebdav,
          SyncIssueAction.grantPermission,
        ],
      // 未设口令时重试必败：只给「配置口令」，不给重试。
      SyncIssueCode.noPassphrase => const [SyncIssueAction.configurePassphrase],
      // 未配置 WebDAV 时重试同样必败：主推荐是「去配置」，重试只作次要出口。
      SyncIssueCode.notConfigured => const [
          SyncIssueAction.retry,
          SyncIssueAction.configureWebdav,
        ],
      SyncIssueCode.webdavDirFailed ||
      SyncIssueCode.webdavListFailed ||
      SyncIssueCode.webdavReadFailed ||
      SyncIssueCode.webdavDecryptFailed ||
      SyncIssueCode.webdavUploadFailed =>
        const [SyncIssueAction.configureWebdav, SyncIssueAction.retry],
      SyncIssueCode.allPeersUnreachable => _allPeersUnreachableActions(issue),
      // 局域网发现 / 读取失败：手动地址与 WebDAV 是两条真实出路（权限被拒
      // 时手动地址无效，那种情况由 permissionDenied 分支覆盖）。
      SyncIssueCode.startFailed ||
      SyncIssueCode.broadcastUnavailable ||
      SyncIssueCode.discoverySilent ||
      SyncIssueCode.peerReadFailed ||
      SyncIssueCode.peerDecryptFailed ||
      SyncIssueCode.peerPushFailed =>
        const [
          SyncIssueAction.addManualPeer,
          SyncIssueAction.useWebdav,
          SyncIssueAction.retry,
        ],
      _ => const [SyncIssueAction.retry],
    };

/// 全不可达的出路按传输分流：手动地址是局域网概念，WebDAV 全失败只给
/// 配置与重试（传输由引擎写进 [SyncIssue.args]；缺失时按局域网处理）。
List<SyncIssueAction> _allPeersUnreachableActions(SyncIssue? issue) =>
    issue?.args['transport'] == SyncTransportKind.webdav
        ? const [SyncIssueAction.configureWebdav, SyncIssueAction.retry]
        : const [
            SyncIssueAction.addManualPeer,
            SyncIssueAction.useWebdav,
            SyncIssueAction.retry,
          ];

/// 失败详情弹层：原因文案 + 按原因给动作（重试 / 去授权 / 去配置）。
///
/// 对话框 action 区保持「text 取消 + filled 主推荐」两颗：其余动作收进
/// 内容区（按钮列表），不把 action 区挤成按钮墙。
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
  final primary = actions.last;
  final secondary = actions.sublist(0, actions.length - 1);
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.syncIssueDialogTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              issue == null ? l10n.syncIssueUnknown : syncIssueText(l10n, issue),
            ),
            if (secondary.isNotEmpty) const SizedBox(height: 8),
            for (final action in secondary)
              Align(
                alignment: Alignment.centerLeft,
                child: _actionButton(
                  context,
                  provider: provider,
                  l10n: l10n,
                  action: action,
                  primary: false,
                  onConfigurePassphrase: onConfigurePassphrase,
                ),
              ),
          ],
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
        _actionButton(
          context,
          provider: provider,
          l10n: l10n,
          action: primary,
          primary: true,
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

/// 口令弹层（首屏开启同步后与设备子页共用）：显示 / 复制 / 重置。
Future<void> showSyncPassphraseDialog(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final passphrase = provider.passphrase ?? '';
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.syncPassphraseTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              passphrase,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.syncPassphraseTrustHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: passphrase));
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.copiedToClipboard(
                    l10n.syncPassphraseTitle))));
          },
          child: Text(l10n.syncPassphraseCopy),
        ),
        M3EButton.text(
          onPressed: () {
            navigator.pop();
            unawaited(_confirmPassphraseReset(context, provider, l10n));
          },
          child: Text(l10n.syncPassphraseReset),
        ),
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
      ],
    ),
  );
}

/// 重置口令二次确认：重置后全组需重新输入新口令。
Future<void> _confirmPassphraseReset(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.syncPassphraseReset,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Text(l10n.syncPassphraseResetConfirm),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
        M3EButton.filled(
          onPressed: () async {
            navigator.pop();
            await provider.resetPassphrase();
            if (!context.mounted) return;
            await showSyncPassphraseDialog(context, provider, l10n);
          },
          child: Text(l10n.syncPassphraseReset),
        ),
      ],
    ),
  );
}

/// 加入口令弹层：输入其它设备上的口令（无效输入在弹层内提示）。
Future<void> showSyncJoinDialog(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  await _showTextDialog(
    context,
    title: l10n.syncPassphraseJoinTitle,
    hint: l10n.syncPassphraseJoinHint,
    initialValue: '',
    saveLabel: l10n.syncSave,
    onSave: (value) async {
      try {
        await provider.joinWithPassphrase(value);
        return null;
      } on ArgumentError {
        return l10n.syncPassphraseInvalid;
      }
    },
  );
}

/// 设备改名弹层（名称是其它设备上识别本机的展示名）。
Future<void> showSyncRenameDialog(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  await _showTextDialog(
    context,
    title: l10n.syncDeviceNameDialogTitle,
    hint: l10n.syncRenameHint,
    initialValue: provider.deviceName,
    saveLabel: l10n.syncSave,
    onSave: (value) async {
      if (value.trim().isEmpty) return l10n.syncDeviceNameEmpty;
      await provider.setDeviceName(value.trim());
      return null;
    },
  );
}

/// 通用文本输入弹窗；[onSave] 返回错误文案或 null（null = 已保存/关闭）。
Future<void> _showTextDialog(
  BuildContext context, {
  required String title,
  required String hint,
  required String initialValue,
  required String saveLabel,
  required Future<String?> Function(String value) onSave,
}) async {
  final controller = TextEditingController(text: initialValue);
  final navigator = Navigator.of(context, rootNavigator: true);
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: title,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: M3ETextField(
          controller: controller,
          label: title,
          placeholder: hint,
          leading: const Icon(Icons.edit_rounded),
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(AppLocalizations.of(context)!.cancelButton),
        ),
        M3EButton.filled(
          onPressed: () async {
            final error = await onSave(controller.text);
            if (!context.mounted) return;
            if (error != null) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(error)));
              return;
            }
            navigator.pop();
          },
          child: Text(saveLabel),
        ),
      ],
    ),
  );
  controller.dispose();
}
