import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../data/sync/sync_passphrase.dart';
import '../data/sync/sync_state_store.dart';
import '../domain/models/device_sync.dart';
import '../domain/models/sync_pairing.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/device_id.dart';
import '../utils/peer_address.dart';
import '../utils/sync_format.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/sync_pairing_qr.dart';
import '../widgets/sync_pairing_scanner.dart';
import 'sync_labels.dart';

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
      SyncIssueCode.probePortUnavailable ||
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
        () => showSyncAddPeerDialog(context, provider, l10n),
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

/// 配对信息分享弹层：二维码 + 可复制文本 + 口令授权警告。
///
/// [code] 由设置页组装（含口令）；本弹层不做二次确认——警告文案已明确
/// 「等同授权对方读取全部同步数据」。
Future<void> showSyncPairingShareDialog(
  BuildContext context, {
  required SyncPairingCode code,
  required AppLocalizations l10n,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final text = code.encode();
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.syncPairingShareTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: SizedBox(
                  // 尺寸随弹层宽度（留出边距），上限 240：再大也没有扫码收益。
                  width: math.min(settingsDialogWidth(context) * 0.7, 240),
                  child: SyncPairingQr(data: text),
                ),
              ),
              const SizedBox(height: kSettingsElementSpacing),
              SelectableText(
                text,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: kSettingsSmallSpacing),
              Text(
                l10n.syncPairingWarning,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppSemanticColors.of(context).warning,
                    ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.syncPairingCopied)),
            );
          },
          child: Text(l10n.syncPairingCopy),
        ),
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
      ],
    ),
  );
}

/// 对端展示名：用户命名优先，对端自报名仅兜底，都没有用短设备 id。
String syncPeerDisplayName(SyncPeerState peer, ManualPeer? manual) {
  final userNamed = manual?.name.trim() ?? '';
  if (userNamed.isNotEmpty) return userNamed;
  return peer.name.isEmpty ? shortDeviceId(peer.deviceId) : peer.name;
}

/// 对端副标题：传输 + 最后同步 + 失联/忽略/落后/时钟偏移/最近失败。
String syncPeerSubtitle(
  AppLocalizations l10n,
  SyncPeerState peer,
  ManualPeer? manual, {
  required int nowMs,
}) {
  final parts = <String>[
    if (manual != null) l10n.syncPeerManual,
    if (peer.transport.isNotEmpty) syncTransportLabel(l10n, peer.transport),
    if (peer.lastPullAt > 0 || peer.lastPushAt > 0)
      l10n.syncPeerLastSync(syncTimeText(peer.lastPullAt > peer.lastPushAt
          ? peer.lastPullAt
          : peer.lastPushAt))
    else
      l10n.syncPeerNever,
    if (peer.isLostAt(nowMs)) l10n.syncPeerLost,
    if (peer.behindBy != null && peer.behindBy! > 0)
      peer.behindBytes != null && peer.behindBytes! > 0
          ? l10n.syncPeerBehindBytes(
              peer.behindBy!,
              syncBytesText(peer.behindBytes!),
            )
          : l10n.syncPeerBehind(peer.behindBy!),
    if (peer.clockSkewMs != null && peer.clockSkewMs!.abs() > 60 * 1000)
      l10n.syncPeerClockSkew((peer.clockSkewMs!.abs() / 60000).round()),
    if (peer.lastError != null)
      l10n.syncPeerLastError(syncIssueText(l10n, peer.lastError!)),
  ];
  return parts.join(' · ');
}

/// 传输展示名（名册副标题用）。
String syncTransportLabel(AppLocalizations l10n, String kind) =>
    switch (kind) {
      SyncTransportKind.lan => l10n.syncLanTitle,
      SyncTransportKind.webdav => l10n.syncWebdavTitle,
      _ => kind,
    };

/// 手动对端详情：地址 / 端点 / 设备 id + 删除（二次确认）。
///
/// 多设备处置动作也在这里：**本地忽略**（幽灵 / 已失联设备不再参与合并）
/// 与**显式清理远端文件**（不做自动删除）。
Future<void> showSyncPeerDialog(
  BuildContext context, {
  required SyncProvider provider,
  required AppLocalizations l10n,
  String? host,
  required String title,
  SyncPeerState? peer,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final deviceId = peer?.deviceId ?? '';
  final ignored = deviceId.isNotEmpty && provider.isPeerIgnored(deviceId);
  final lost = peer != null && peer.isLostAt(provider.engine.state.nowMs());
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      // 标题用展示名（用户命名优先）：与名册行保持同一称谓。
      title: title,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (host != null) Text(l10n.syncPeerAddress(host)),
            if (peer != null && peer.deviceId.isNotEmpty)
              Text(l10n.syncPeerDeviceId(shortDeviceId(peer.deviceId))),
            if (peer != null && peer.lastPullAt > 0)
              Text(l10n.syncPeerLastSync(syncTimeText(peer.lastPullAt))),
            if (lost)
              Text(
                l10n.syncPeerLostHint,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppSemanticColors.of(context).warning),
              ),
            if (ignored)
              Text(
                l10n.syncPeerIgnoredHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (host != null) ...[
              const SizedBox(height: 12),
              Text(
                l10n.syncPeerDeleteConfirm,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (deviceId.isNotEmpty) ...[
              const SizedBox(height: 8),
              SettingsNavTile(
                key: Key('settingsSyncPeerIgnore-$deviceId'),
                icon: ignored
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                title: ignored ? l10n.syncPeerUnignore : l10n.syncPeerIgnore,
                subtitle: l10n.syncPeerIgnoreHint,
                onTap: () async {
                  navigator.pop();
                  await provider.setPeerIgnored(deviceId, !ignored);
                },
              ),
              SettingsNavTile(
                key: Key('settingsSyncPeerCleanup-$deviceId'),
                icon: Icons.delete_sweep_rounded,
                title: l10n.syncPeerCleanupRemote,
                subtitle: l10n.syncPeerCleanupRemoteHint,
                onTap: () async {
                  navigator.pop();
                  await _confirmCleanupRemote(
                    context,
                    provider,
                    l10n,
                    deviceId: deviceId,
                  );
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (host != null)
          M3EButton.text(
            onPressed: () async {
              navigator.pop();
              await provider.removeManualPeer(host);
            },
            child: Text(l10n.syncPeerDelete),
          ),
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
      ],
    ),
  );
}

/// 清理远端文件：二次确认后执行（不做自动删除）。
Future<void> _confirmCleanupRemote(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n, {
  required String deviceId,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.syncPeerCleanupRemote,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Text(l10n.syncPeerCleanupRemoteConfirm),
      ),
      actions: [
        M3EButton.text(
          onPressed: () async {
            navigator.pop();
            final result = await provider.cleanupRemote(deviceId);
            if (!context.mounted) return;
            final message = result.error != null
                ? l10n.syncPeerCleanupRemoteFailed(
                    syncIssueText(l10n, result.error!),
                  )
                : result.removed
                    ? l10n.syncPeerCleanupRemoteDone
                    : l10n.syncPeerCleanupRemoteNone;
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          },
          child: Text(l10n.delete),
        ),
        M3EButton.text(
          onPressed: () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
      ],
    ),
  );
}

/// 未认领的地址候选：折叠行点开后的列表（可逐个看详情 / 删除）。
Future<void> showSyncCandidatesDialog(
  BuildContext context, {
  required SyncProvider provider,
  required AppLocalizations l10n,
  required List<ManualPeer> candidates,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.syncPeerCandidatesTitle(candidates.length),
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in candidates)
                SettingsNavTile(
                  key: Key('settingsSyncPeer-${entry.host}'),
                  icon: Icons.link_rounded,
                  title: entry.name.isEmpty ? entry.host : entry.name,
                  subtitle: '${entry.host} · ${l10n.syncPeerNotContacted}',
                  onTap: () {
                    navigator.pop();
                    unawaited(showSyncPeerDialog(
                      context,
                      provider: provider,
                      l10n: l10n,
                      host: entry.host,
                      title: entry.name.isEmpty ? entry.host : entry.name,
                    ));
                  },
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
      ],
    ),
  );
}

/// 添加设备弹层：地址或配对码（粘贴 / 扫码）+ 探测端口 + 可选名称；
/// 提交后立即尝试接触，接触成功才关闭弹层（失败在弹层内给文案）。
Future<void> showSyncAddPeerDialog(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  await M3EDialog.show<void>(
    context,
    dialog: SyncAddPeerDialog(provider: provider, l10n: l10n),
  );
}

/// 配对码口令冲突时的处置（弹层内二次确认）。
enum _PassphraseConflictChoice { replace, addressOnly }

/// 添加设备弹层（也承接配对码导入与扫码结果）。
class SyncAddPeerDialog extends StatefulWidget {
  const SyncAddPeerDialog({
    super.key,
    required this.provider,
    required this.l10n,
  });

  final SyncProvider provider;
  final AppLocalizations l10n;

  @override
  State<SyncAddPeerDialog> createState() => _SyncAddPeerDialogState();
}

class _SyncAddPeerDialogState extends State<SyncAddPeerDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '${ManualPeer.defaultProbePort}');
  final _name = TextEditingController();
  String? _hostError;
  String? _portError;
  String? _contactError;
  bool _duplicate = false;
  bool _busy = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _name.dispose();
    super.dispose();
  }

  /// 扫码（仅移动端）：结果填进地址框走同一条提交路径。
  Future<void> _scan() async {
    final result = await showSyncPairingScanner(
      context,
      onOpenSettings: widget.provider.openSystemSettings,
    );
    if (result == null || !mounted) return;
    _host.text = result;
    await _submit();
  }

  Future<void> _submit() async {
    final raw = _host.text;
    final code = SyncPairingCode.tryParse(raw);
    if (code != null) {
      await _submitPairingCode(code);
      return;
    }
    await _submitAddress();
  }

  /// 普通地址：校验地址 / 端口，提交后立即接触；失败留在弹层内。
  Future<void> _submitAddress() async {
    final l10n = widget.l10n;
    final host = normalizePeerHost(_host.text);
    final port = parseProbePort(_port.text);
    if (host.isEmpty) {
      setState(() => _hostError = l10n.syncPeerHostInvalid);
      return;
    }
    if (!isValidPeerHost(host)) {
      setState(() => _hostError = l10n.syncPeerHostFormatInvalid);
      return;
    }
    if (port == null) {
      setState(() => _portError = l10n.syncPeerPortInvalid);
      return;
    }

    setState(() {
      _hostError = null;
      _portError = null;
      _contactError = null;
      _busy = true;
    });
    final added = await widget.provider.addManualPeer(
      host,
      name: _name.text,
      probePort: port,
    );
    final contacted = await widget.provider.contactManualPeer(host);
    if (!mounted) return;
    // 接触成功 / 本轮被排队（结果未知）都关闭弹层：地址已入簿，只有失败
    // 才留在弹层里让用户改地址。重复地址在成功路径也给「已更新」提示。
    final message = switch (contacted) {
      null => l10n.syncPeerContactQueued,
      true => added ? l10n.syncPeerAdded : l10n.syncPeerUpdated,
      false => null,
    };
    if (message != null) {
      _finish(message);
      return;
    }
    setState(() {
      _busy = false;
      _duplicate = !added;
      _contactError = l10n.syncPeerUnreachable;
    });
  }

  /// 配对码：地址逐个入簿（带码里的探测 / 端点端口与设备身份），口令按
  /// 「本机已设且不同 → 确认」处理后立即接触首个地址。
  Future<void> _submitPairingCode(SyncPairingCode code) async {
    final l10n = widget.l10n;
    if (code.addresses.isEmpty) {
      setState(() => _hostError = l10n.syncPairingNoAddress);
      return;
    }
    setState(() {
      _hostError = null;
      _portError = null;
      _contactError = null;
      _busy = true;
    });

    final current = widget.provider.passphrase;
    var applyPassphrase = current == null || current.trim().isEmpty;
    if (!applyPassphrase && !SyncPassphrase.matches(code.passphrase, current)) {
      final choice = await _confirmPassphraseConflict();
      if (!mounted) return;
      if (choice == null) {
        setState(() => _busy = false);
        return;
      }
      applyPassphrase = choice == _PassphraseConflictChoice.replace;
    }
    if (applyPassphrase) {
      try {
        await widget.provider.joinWithPassphrase(code.passphrase);
      } on ArgumentError {
        // 码里的口令过短（手工拼的码）：按非法口令处理，不落入未捕获异常。
        if (!mounted) return;
        setState(() {
          _busy = false;
          _hostError = l10n.syncPassphraseInvalid;
        });
        return;
      }
    }

    final primary = await widget.provider.importPairingAddresses(code);
    if (!mounted) return;
    if (primary == null) {
      setState(() {
        _busy = false;
        _hostError = l10n.syncPairingNoAddress;
      });
      return;
    }
    final contacted = await widget.provider.contactManualPeer(primary);
    if (!mounted) return;
    final message = switch (contacted) {
      null => l10n.syncPeerContactQueued,
      true => l10n.syncPairingImported,
      false => null,
    };
    if (message != null) {
      _finish(message);
      return;
    }
    setState(() {
      _busy = false;
      _contactError = l10n.syncPeerUnreachable;
    });
  }

  /// 本机已有别的口令：替换会影响其它设备，让用户明确选择。
  Future<_PassphraseConflictChoice?> _confirmPassphraseConflict() async {
    final l10n = widget.l10n;
    final navigator = Navigator.of(context, rootNavigator: true);
    return M3EDialog.show<_PassphraseConflictChoice>(
      context,
      dialog: M3EDialog(
        title: l10n.syncPairingPassphraseConflictTitle,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(l10n.syncPairingPassphraseConflictBody),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(
              _PassphraseConflictChoice.addressOnly,
            ),
            child: Text(l10n.syncPairingAddressOnly),
          ),
          M3EButton.filled(
            onPressed: () =>
                navigator.pop(_PassphraseConflictChoice.replace),
            child: Text(l10n.syncPairingReplacePassphrase),
          ),
        ],
      ),
    );
  }

  void _finish(String message) {
    Navigator.of(context, rootNavigator: true).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final navigator = Navigator.of(context, rootNavigator: true);
    final semantic = AppSemanticColors.of(context);
    return M3EDialog(
      title: l10n.syncPeerAddTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              M3ETextField(
                controller: _host,
                label: l10n.syncPeerHostLabel,
                placeholder: l10n.syncPeerHostHint,
                leading: const Icon(Icons.lan_rounded),
                trailing: SyncPairingScanner.isSupported
                    ? M3EIconButton(
                        key: const Key('settingsSyncPairingScanButton'),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        variant: M3EIconButtonVariant.tonal,
                        semanticLabel: l10n.syncPairingScanTitle,
                        onPressed: _busy ? null : () => unawaited(_scan()),
                      )
                    : null,
                errorText: _hostError,
                enabled: !_busy,
              ),
              const SizedBox(height: 12),
              M3ETextField(
                controller: _port,
                label: l10n.syncPeerProbePortLabel,
                placeholder:
                    l10n.syncPeerProbePortHint(ManualPeer.defaultProbePort),
                leading: const Icon(Icons.settings_ethernet_rounded),
                errorText: _portError,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              M3ETextField(
                controller: _name,
                label: l10n.syncPeerNameLabel,
                leading: const Icon(Icons.edit_rounded),
                enabled: !_busy,
              ),
              if (_duplicate) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.syncPeerAlreadyAdded,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (_contactError != null) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: semantic.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _contactError!,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: semantic.warning),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: _busy ? null : () => navigator.pop(),
          child: Text(l10n.cancelButton),
        ),
        M3EButton.filled(
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: Text(_busy ? l10n.syncPeerContacting : l10n.syncSave),
        ),
      ],
    );
  }
}
