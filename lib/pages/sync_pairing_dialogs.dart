/// 配对与名册相关弹层与流程：分享配对信息（二维码 / 复制）、导入配对码
/// （粘贴 / 扫码的共用出口）、手动连接、对端详情与地址清单。
///
/// 与 `sync_dialogs.dart` 分开：那边是传输配置 / 失败动作 / 口令、改名与本机
/// 网络地址的通用弹层，这边只服务配对工作台，两类改动原因不同（Divergent
/// Change）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../data/sync/sync_passphrase.dart';
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
import 'sync_labels.dart';
import 'sync_notices.dart';

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
            showSyncNotice(context, l10n.syncPairingCopied);
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

/// 导入一段配对码文本（「粘贴配对码」与「扫码」的共用出口）。
///
/// 配对码是加入同步的唯一入口：口令随码传递、地址按码收敛（同设备的旧地址
/// 被替换，内网 IP 变动后重新粘贴即可换地址）。全过程不走弹层——口令冲突
/// 需要用户明确选择时才弹一次确认；结果用底栏提示分级反馈。首轮就连上时
/// 不提示：「已连通」通知（引擎事件）会单独出现，同一出口不重复弹两条。
Future<void> importSyncPairingText(
  BuildContext context, {
  required SyncProvider provider,
  required AppLocalizations l10n,
  required String raw,
}) async {
  final text = raw.trim();
  if (text.isEmpty) {
    showSyncNotice(context, l10n.syncClipboardNoPairingCode, isError: true);
    return;
  }
  final code = SyncPairingCode.tryParse(text);
  if (code == null) {
    showSyncNotice(
      context,
      // 前缀对但解析失败 = 码本身坏了；完全不是码 = 让用户先去复制。
      SyncPairingCode.looksLikeCode(text)
          ? l10n.syncPairingInvalidCode
          : l10n.syncClipboardNoPairingCode,
      isError: true,
    );
    return;
  }
  if (code.addresses.isEmpty) {
    showSyncNotice(context, l10n.syncPairingNoAddress, isError: true);
    return;
  }

  // 口令冲突：本机已有别的口令时让用户明确选择（换口令会影响已配对设备）。
  final current = provider.passphrase;
  var applyPassphrase = current == null || current.trim().isEmpty;
  if (!applyPassphrase && !SyncPassphrase.matches(code.passphrase, current)) {
    final choice = await _confirmPassphraseConflict(context, l10n);
    if (choice == null) return;
    applyPassphrase = choice == _PassphraseConflictChoice.replace;
  }
  if (applyPassphrase) {
    try {
      await provider.joinWithPassphrase(code.passphrase);
    } on ArgumentError {
      if (!context.mounted) return;
      showSyncNotice(context, l10n.syncPassphraseInvalid, isError: true);
      return;
    }
  }

  final primary = await provider.importPairingAddresses(code);
  if (!context.mounted) return;
  if (primary == null) {
    showSyncNotice(context, l10n.syncPairingNoAddress, isError: true);
    return;
  }
  final contacted = await provider.contactManualPeer(primary);
  if (!context.mounted) return;
  if (contacted == true) return;
  if (contacted == null) {
    showSyncNotice(context, l10n.syncPeerContactQueued);
    return;
  }
  final name = code.deviceName.trim().isNotEmpty
      ? code.deviceName.trim()
      : shortDeviceId(code.deviceId);
  showSyncNotice(context, l10n.syncPeerAddedOffline(name));
}

/// 配对码口令冲突时的处置（信任模型：换口令会影响全部已配对设备）。
enum _PassphraseConflictChoice { replace, addressOnly }

Future<_PassphraseConflictChoice?> _confirmPassphraseConflict(
  BuildContext context,
  AppLocalizations l10n,
) async {
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

/// 手动地址条目副标题：探测端口（0 = 用标准端口）。
String syncManualPeerSubtitle(AppLocalizations l10n, ManualPeer entry) {
  final port =
      entry.probePort > 0 ? entry.probePort : ManualPeer.defaultProbePort;
  return '${l10n.syncPeerProbePortLabel} $port';
}

/// 手动对端详情：地址入口 / 设备 id / 最后同步 + 忽略与清理远端 + 删除。
///
/// 多设备处置动作：**本地忽略**（幽灵 / 已失联设备不再参与合并）与
/// **显式清理远端文件**（不做自动删除）。地址明细收进地址清单弹层——
/// 一台设备可能有多条候选地址（双栈 / 多网卡），不铺在详情里。
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
  final entries = _manualEntriesFor(provider, host: host, deviceId: deviceId);
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
            if (entries.isNotEmpty) ...[
              const SizedBox(height: kSettingsSmallSpacing),
              SettingsNavTile(
                key: const Key('settingsSyncPeerAddressesItem'),
                icon: Icons.lan_rounded,
                title: l10n.syncNetworkAddresses,
                subtitle: l10n.syncPeerAddressCount(entries.length),
                onTap: () {
                  navigator.pop();
                  unawaited(showSyncPeerAddressesDialog(
                    context,
                    provider: provider,
                    l10n: l10n,
                    title: title,
                    entries: entries,
                  ));
                },
              ),
            ],
            if (entries.isNotEmpty) ...[
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
        if (entries.isNotEmpty)
          M3EButton.text(
            onPressed: () async {
              navigator.pop();
              // 「删除设备」= 移除它在本机地址簿里的全部地址（其它设备无关）。
              for (final entry in entries) {
                await provider.removeManualPeer(entry.host);
              }
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
/// 该设备在地址簿里的条目：已认领的按 deviceId 取（双栈 / 多网卡候选都在），
/// 未认领的按 host 取（只有这一条）。
List<ManualPeer> _manualEntriesFor(
  SyncProvider provider, {
  required String? host,
  required String deviceId,
}) {
  if (host != null) {
    return [
      for (final entry in provider.manualPeers)
        if (entry.host == host) entry,
    ];
  }
  if (deviceId.isEmpty) return const [];
  return [
    for (final entry in provider.manualPeers)
      if (entry.deviceId == deviceId) entry,
  ];
}

/// 某台设备的地址清单：地址簿里属于它的每条地址（可更新 / 删除）。
///
/// 设备换 IP 后就地改一条地址即可，不必删了重加；更新走手动连接表单
/// （预填当前值），删除带二次确认。
Future<void> showSyncPeerAddressesDialog(
  BuildContext context, {
  required SyncProvider provider,
  required AppLocalizations l10n,
  required String title,
  required List<ManualPeer> entries,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: title,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in entries)
                SettingsNavTile(
                  key: Key('settingsSyncPeerAddress-${entry.host}'),
                  icon: Icons.lan_rounded,
                  title: entry.host,
                  subtitle: syncManualPeerSubtitle(l10n, entry),
                  onTap: () {
                    navigator.pop();
                    unawaited(showSyncManualPeerDialog(
                      context,
                      provider,
                      l10n,
                      editing: entry,
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
            showSyncNotice(context, message);
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

/// 手动连接弹层：手填对端地址（自动发现失败时的兜底路径）。
///
/// [editing] 非空 = 更新这条地址（保留 deviceId 与已学到的端点端口，只改
/// 「设备在哪」），表单底部多一个「删除该地址」。提交后立即接触：成功 / 排队
/// 关闭弹层并提示，失败留在弹层里让用户改地址。
Future<void> showSyncManualPeerDialog(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n, {
  ManualPeer? editing,
}) async {
  await M3EDialog.show<void>(
    context,
    dialog: _ManualPeerDialog(provider: provider, l10n: l10n, editing: editing),
  );
}

class _ManualPeerDialog extends StatefulWidget {
  const _ManualPeerDialog({
    required this.provider,
    required this.l10n,
    this.editing,
  });

  final SyncProvider provider;
  final AppLocalizations l10n;
  final ManualPeer? editing;

  @override
  State<_ManualPeerDialog> createState() => _ManualPeerDialogState();
}

class _ManualPeerDialogState extends State<_ManualPeerDialog> {
  late final TextEditingController _host =
      TextEditingController(text: widget.editing?.host ?? '');
  late final TextEditingController _port = TextEditingController(
    text: '${(widget.editing?.probePort ?? 0) > 0 ? widget.editing!.probePort : ManualPeer.defaultProbePort}',
  );
  late final TextEditingController _name =
      TextEditingController(text: widget.editing?.name ?? '');
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

  Future<void> _submit() async {
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
    final editing = widget.editing;
    final added = editing == null
        ? await widget.provider.addManualPeer(
            host,
            name: _name.text,
            probePort: port,
          )
        : false;
    if (editing != null) {
      await widget.provider.moveManualPeer(
        editing.host,
        toHost: host,
        probePort: port,
        name: _name.text.trim(),
      );
    }
    final contacted = await widget.provider.contactManualPeer(host);
    if (!mounted) return;
    // 接触成功 / 本轮被排队（结果未知）都关闭弹层：地址已入簿，只有失败
    // 才留在弹层里让用户改地址。重复地址在成功路径也给「已更新」提示。
    final message = switch (contacted) {
      null => l10n.syncPeerContactQueued,
      true when editing != null => l10n.syncPeerAddressUpdated,
      true => added ? l10n.syncPeerAdded : l10n.syncPeerUpdated,
      false => null,
    };
    if (message != null) {
      showSyncNoticeAndClose(context, message);
      return;
    }
    setState(() {
      _busy = false;
      _duplicate = editing == null && !added;
      _contactError = l10n.syncPeerUnreachable;
    });
  }

  /// 删除该地址（仅编辑态）：从地址簿移除，二次确认（不影响其它设备）。
  Future<void> _delete() async {
    final l10n = widget.l10n;
    final editing = widget.editing;
    if (editing == null) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.syncPeerAddressDelete,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(l10n.syncPeerAddressDeleteConfirm),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.provider.removeManualPeer(editing.host);
    if (!mounted) return;
    showSyncNoticeAndClose(context, l10n.syncPeerAddressRemoved);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final navigator = Navigator.of(context, rootNavigator: true);
    final semantic = AppSemanticColors.of(context);
    final editing = widget.editing != null;
    return M3EDialog(
      title: editing ? l10n.syncPeerAddressEdit : l10n.syncManualConnect,
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
        if (editing)
          M3EButton.text(
            onPressed: _busy ? null : () => unawaited(_delete()),
            child: Text(l10n.syncPeerAddressDelete),
          ),
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
