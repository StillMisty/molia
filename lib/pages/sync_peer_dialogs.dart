/// 已配对设备与手动地址相关弹层：对端详情、地址清单、未认领候选与手动连接。
///
/// 与 `sync_dialogs.dart` 分开：那边是传输配置 / 失败动作 / 口令、改名与本机
/// 网络地址的通用弹层，这边只服务设备区，两类改动原因不同（Divergent
/// Change）。附近设备的一键配对弹层在 `sync_nearby_pairing_dialogs.dart`。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/sync_peer_status.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/m3e_context.dart';
import '../utils/device_id.dart';
import '../utils/peer_address.dart';
import '../utils/sync_format.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_labels.dart';
import 'sync_notices.dart';

/// 对端展示名：用户命名优先，对端自报名仅兜底，都没有用短设备 id。
String syncPeerDisplayName(SyncPeerState peer, ManualPeer? manual) {
  final userNamed = manual?.name.trim() ?? '';
  if (userNamed.isNotEmpty) return userNamed;
  return peer.name.isEmpty ? shortDeviceId(peer.deviceId) : peer.name;
}

/// 对端副标题：状态词 + 上次成功 + 传输 / 落后 / 时钟偏移。
///
/// 行首必须是可读结论（已连接 / 未连接 / 云端已同步 / 上次同步 / 还没连上 /
/// 已失联），失败原因不铺在行里——详情弹层会给出上次尝试与最近失败。
String syncPeerSubtitle(
  AppLocalizations l10n,
  SyncPeerState peer,
  ManualPeer? manual, {
  required int nowMs,
  SyncRoundReport? report,
}) {
  final status = resolveSyncPeerConnection(peer, report: report, nowMs: nowMs);
  final lastSuccess = peer.lastSuccessAt;
  final cloud = peer.transport == SyncTransportKind.webdav;
  final lastSuccessText = lastSuccess > 0 ? syncTimeText(lastSuccess) : '';
  // 结论 + 上次成功合成一句：两段独立文案会重复「上次同步」。
  final statusText = switch (status) {
    // 从未成功接触过：失败尝试只能说明「还没连上」，不能说成「未连接 ·
    // 上次同步 …」，WebDAV 行也不能显示「云端未同步」（那是同步过又失败）。
    _ when lastSuccess <= 0 => l10n.syncPeerNever,
    SyncPeerConnectionStatus.lost => l10n.syncPeerLostSince(lastSuccessText),
    // never 只在没有任何接触证据时返回，已被上一分支覆盖；保留以满足穷尽性。
    SyncPeerConnectionStatus.never => l10n.syncPeerNever,
    SyncPeerConnectionStatus.connected => cloud
        ? l10n.syncPeerCloudSyncedSince(lastSuccessText)
        : l10n.syncPeerConnectedSince(lastSuccessText),
    SyncPeerConnectionStatus.unreachable => cloud
        ? l10n.syncPeerCloudNotSyncedSince(lastSuccessText)
        : l10n.syncPeerDisconnectedSince(lastSuccessText),
    // 本轮没尝试：时间本身就是状态（不再叠一个没信息量的「空闲」）。
    SyncPeerConnectionStatus.idle => l10n.syncPeerLastSuccess(lastSuccessText),
  };
  final parts = <String>[
    statusText,
    if (peer.transport.isNotEmpty) syncTransportLabel(l10n, peer.transport),
    if (manual != null) l10n.syncPeerManual,
    if (peer.behindBy != null && peer.behindBy! > 0)
      peer.behindBytes != null && peer.behindBytes! > 0
          ? l10n.syncPeerBehindBytes(
              peer.behindBy!,
              syncBytesText(peer.behindBytes!),
            )
          : l10n.syncPeerBehind(peer.behindBy!),
    if (peer.clockSkewMs != null && peer.clockSkewMs!.abs() > 60 * 1000)
      l10n.syncPeerClockSkew((peer.clockSkewMs!.abs() / 60000).round()),
  ];
  return parts.join(' · ');
}

/// 传输展示名（名册副标题用）。
String syncTransportLabel(AppLocalizations l10n, String kind) => switch (kind) {
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

/// 对端详情：地址入口 / 设备 id / 最后同步 + 移除本机记录 + 清理远端。
///
/// 「移除设备」只清本机名册与地址簿，不撤销同步授权：对方仍持有口令并在线
/// 时会被下一轮探测重新发现；真正停止与它同步需要更换口令（对所有设备生效）。
/// 地址明细收进地址清单弹层——一台设备可能有多条候选地址（双栈 / 多网卡），
/// 不铺在详情里。
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
  final lost = peer != null && peer.isLostAt(provider.nowMs);
  final entries = _manualEntriesFor(provider, host: host, deviceId: deviceId);
  // 自动发现的设备没有地址簿条目，也必须能移除；未认领地址只移除地址本身。
  final removable = deviceId.isNotEmpty || entries.isNotEmpty;
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
            if (peer != null && peer.lastSuccessAt > 0)
              Text(l10n.syncPeerLastSuccess(syncTimeText(peer.lastSuccessAt))),
            if (peer != null && peer.lastSeenAt > 0)
              Text(l10n.syncPeerLastAttempt(syncTimeText(peer.lastSeenAt))),
            if (peer?.lastError != null)
              Text(
                l10n.syncPeerLastError(syncIssueText(l10n, peer!.lastError!)),
                style: context.typeScale.bodySmall.copyWith(
                  color: AppSemanticColors.of(context).warning,
                ),
              ),
            if (lost)
              Text(
                l10n.syncPeerLostHint,
                style: context.typeScale.bodySmall.copyWith(
                  color: AppSemanticColors.of(context).warning,
                ),
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
                  unawaited(
                    showSyncPeerAddressesDialog(
                      context,
                      provider: provider,
                      l10n: l10n,
                      title: title,
                      entries: entries,
                    ),
                  );
                },
              ),
            ],
            if (removable) ...[
              const SizedBox(height: 12),
              Text(
                deviceId.isEmpty
                    ? l10n.syncPeerAddressDeleteConfirm
                    : l10n.syncPeerDeleteConfirm,
                style: context.typeScale.bodySmall,
              ),
            ],
            if (deviceId.isNotEmpty) ...[
              const SizedBox(height: 8),
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
        if (removable)
          M3EButton.text(
            onPressed: () async {
              navigator.pop();
              if (deviceId.isNotEmpty) {
                // 已知身份：名册 + 该设备的全部地址簿条目一并移除。
                await provider.removePeer(deviceId);
              } else {
                // 尚未认领的地址：只移除这条地址，不碰名册。
                for (final entry in entries) {
                  await provider.removeManualPeer(entry.host);
                }
              }
              if (!context.mounted) return;
              showSyncNotice(context, l10n.syncPeerRemoved);
            },
            child: Text(
              deviceId.isEmpty
                  ? l10n.syncPeerAddressDelete
                  : l10n.syncPeerDelete,
            ),
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
                    unawaited(
                      showSyncManualPeerDialog(
                        context,
                        provider,
                        l10n,
                        editing: entry,
                      ),
                    );
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
                    unawaited(
                      showSyncPeerDialog(
                        context,
                        provider: provider,
                        l10n: l10n,
                        host: entry.host,
                        title: entry.name.isEmpty ? entry.host : entry.name,
                      ),
                    );
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
/// 「设备在哪」），表单底部多一个「删除该地址」。提交后立即接触：成功 /
/// 没有真正跑（null）关闭弹层并提示，本轮没连上留在弹层里让用户改地址。
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
  late final TextEditingController _host = TextEditingController(
    text: widget.editing?.host ?? '',
  );
  late final TextEditingController _port = TextEditingController(
    text:
        '${(widget.editing?.probePort ?? 0) > 0 ? widget.editing!.probePort : ManualPeer.defaultProbePort}',
  );
  late final TextEditingController _name = TextEditingController(
    text: widget.editing?.name ?? '',
  );
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
    // 已认领过身份的地址 = 已配对设备换地址 / 重连：沿用原来的「立即接触」。
    final paired = _isKnownPairedHost(host, editing);
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
    // 同一路径也发一条附近设备探测：未配对设备会以候选形式出现在「附近
    // 设备」，点击即走一键配对，不需要在这里输入 / 粘贴配对信息。
    final probed = await widget.provider.probeAddress(host, probePort: port);
    if (!mounted) return;
    if (!paired && probed) {
      showSyncNoticeAndClose(context, l10n.syncNearbyManualProbeSent);
      return;
    }
    final contacted = await widget.provider.contactManualPeer(host);
    if (!mounted) return;
    // 接触成功 / 本轮没有真正跑（null = 调度器忙 / 同步关闭）都关闭弹层：
    // 地址已入簿，只有本轮明确没连上才留在弹层里让用户改地址。
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

  /// 该地址是否已认领过设备身份（编辑态自身或地址簿里的同地址条目）。
  bool _isKnownPairedHost(String host, ManualPeer? editing) {
    if (editing != null && editing.deviceId.isNotEmpty) return true;
    for (final entry in widget.provider.manualPeers) {
      if (entry.host == host && entry.deviceId.isNotEmpty) return true;
    }
    return false;
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
                placeholder: l10n.syncPeerProbePortHint(
                  ManualPeer.defaultProbePort,
                ),
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
                  style: context.typeScale.bodySmall,
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
                        style: context.typeScale.bodySmall.copyWith(
                          color: semantic.warning,
                        ),
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
