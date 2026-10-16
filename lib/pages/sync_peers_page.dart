import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/device_id.dart';
import '../utils/peer_address.dart';
import '../utils/sync_format.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_labels.dart';

/// 已配对设备（同步名册）：本机 + 每台对端的最近接触情况 + 手动地址簿。
///
/// 为什么单独一页：名册条数随设备数增长，放在设置首屏会把主要动作
/// （立即同步、传输开关）挤下去；这里只读为主，操作集中在行内弹层。
/// 「添加设备」只对**发现失败**有意义——权限被拒时手动地址同样无效
/// （Android 17 的局域网保护是网关级的，见 ADR-0003 v2 §3）。
class SyncPeersPage extends StatelessWidget {
  const SyncPeersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    final manualByDevice = <String, ManualPeer>{
      for (final entry in provider.manualPeers)
        if (entry.deviceId.isNotEmpty) entry.deviceId: entry,
    };
    final pendingManual = [
      for (final entry in provider.manualPeers)
        if (entry.deviceId.isEmpty) entry,
    ];

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.syncPeersTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            title: l10n.syncPeersSection,
            footer: SettingsSectionHint(text: l10n.syncPeersHint),
            children: [
              // 本机行可点：复制完整设备 id（排查 / 填写对端地址时要用）。
              SettingsNavTile(
                key: const Key('settingsSyncPeerSelfItem'),
                icon: Icons.phone_android_rounded,
                title: provider.deviceName,
                subtitle:
                    l10n.syncPeerThisDevice(shortDeviceId(provider.deviceId)),
                onTap: () => _copyDeviceId(context, provider, l10n),
              ),
              for (final peer in provider.peers)
                _peerRow(context, provider, l10n, peer, manualByDevice[peer.deviceId]),
              for (final entry in pendingManual)
                SettingsNavTile(
                  key: Key('settingsSyncPeer-${entry.host}'),
                  icon: Icons.link_rounded,
                  title: entry.name.isEmpty ? entry.host : entry.name,
                  subtitle: '${entry.host} · ${l10n.syncPeerNotContacted}',
                  onTap: () => _showPeerDialog(
                    context,
                    provider,
                    l10n,
                    host: entry.host,
                    title: entry.name.isEmpty ? entry.host : entry.name,
                  ),
                ),
              SettingsNavTile(
                key: const Key('settingsSyncAddPeerItem'),
                icon: Icons.add_link_rounded,
                title: l10n.syncPeerAdd,
                subtitle: l10n.syncPeerAddSubtitle,
                onTap: () => _showAddDialog(context, provider, l10n),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 名册行：手动添加的对端可点开详情（含删除），广播发现的只读。
  Widget _peerRow(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    SyncPeerState peer,
    ManualPeer? manual,
  ) {
    final title = _displayName(peer, manual);
    if (manual == null) {
      return SettingsInfoTile(
        key: Key('settingsSyncPeer-${peer.deviceId}'),
        icon: Icons.sync_alt_rounded,
        title: title,
        subtitle: _peerSubtitle(l10n, peer),
      );
    }
    return SettingsNavTile(
      key: Key('settingsSyncPeer-${peer.deviceId}'),
      icon: Icons.link_rounded,
      title: title,
      subtitle: '${_peerSubtitle(l10n, peer)} · ${l10n.syncPeerManual}',
      onTap: () => _showPeerDialog(
        context,
        provider,
        l10n,
        host: manual.host,
        title: title,
        peer: peer,
      ),
    );
  }

  /// 展示名：用户在地址簿里的命名优先（按 deviceId 匹配），对端自报的设备名
  /// 仅兜底，都没有时用短设备 id。
  static String _displayName(SyncPeerState peer, ManualPeer? manual) {
    final userNamed = manual?.name.trim() ?? '';
    if (userNamed.isNotEmpty) return userNamed;
    return peer.name.isEmpty ? shortDeviceId(peer.deviceId) : peer.name;
  }

  /// 复制完整设备 id（对端填地址 / 报问题时要用；行内展示的是短号）。
  Future<void> _copyDeviceId(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    await Clipboard.setData(ClipboardData(text: provider.deviceId));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.syncPeerDeviceIdCopied)));
  }

  /// 手动对端详情：地址 / 端点 / 设备 id + 删除（二次确认）。
  Future<void> _showPeerDialog(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n, {
    required String host,
    required String title,
    SyncPeerState? peer,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
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
              Text(l10n.syncPeerAddress(host)),
              if (peer != null && peer.deviceId.isNotEmpty)
                Text(l10n.syncPeerDeviceId(shortDeviceId(peer.deviceId))),
              if (peer != null && peer.lastPullAt > 0)
                Text(l10n.syncPeerLastSync(syncTimeText(peer.lastPullAt))),
              const SizedBox(height: 12),
              Text(
                l10n.syncPeerDeleteConfirm,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () async {
              navigator.pop();
              await provider.removeManualPeer(host);
            },
            child: Text(l10n.syncPeerDelete),
          ),
          M3EButton.text(
            onPressed: () {
              navigator.pop();
              unawaited(provider.syncNow(manual: true));
            },
            child: Text(l10n.syncSyncNow),
          ),
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
        ],
      ),
    );
  }

  /// 添加设备：地址 + 探测端口 + 可选名称；提交后立即尝试接触，
  /// 接触成功才关闭弹层（失败在弹层内给文案，用户可改地址重试）。
  Future<void> _showAddDialog(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    await M3EDialog.show<void>(
      context,
      dialog: _AddPeerDialog(provider: provider, l10n: l10n),
    );
  }

  /// 对端副标题：传输 + 最后同步 + 落后/时钟偏移/最近失败（有什么说什么）。
  static String _peerSubtitle(AppLocalizations l10n, SyncPeerState peer) {
    final parts = <String>[
      if (peer.transport.isNotEmpty) _transportLabel(l10n, peer.transport),
      if (peer.lastPullAt > 0 || peer.lastPushAt > 0)
        l10n.syncPeerLastSync(syncTimeText(peer.lastPullAt > peer.lastPushAt
            ? peer.lastPullAt
            : peer.lastPushAt))
      else
        l10n.syncPeerNever,
      if (peer.behindBy != null && peer.behindBy! > 0)
        l10n.syncPeerBehind(peer.behindBy!),
      if (peer.clockSkewMs != null && peer.clockSkewMs!.abs() > 60 * 1000)
        l10n.syncPeerClockSkew((peer.clockSkewMs!.abs() / 60000).round()),
      if (peer.lastError != null)
        l10n.syncPeerLastError(syncIssueText(l10n, peer.lastError!)),
    ];
    return parts.join(' · ');
  }

  static String _transportLabel(AppLocalizations l10n, String kind) =>
      switch (kind) {
        SyncTransportKind.lan => l10n.syncLanTitle,
        SyncTransportKind.webdav => l10n.syncWebdavTitle,
        _ => kind,
      };
}

/// 添加设备弹层：校验地址 / 端口，提交后立即接触；失败留在弹层内。
class _AddPeerDialog extends StatefulWidget {
  const _AddPeerDialog({required this.provider, required this.l10n});

  final SyncProvider provider;
  final AppLocalizations l10n;

  @override
  State<_AddPeerDialog> createState() => _AddPeerDialogState();
}

class _AddPeerDialogState extends State<_AddPeerDialog> {
  final _host = TextEditingController();
  final _port =
      TextEditingController(text: '${ManualPeer.defaultProbePort}');
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

  Future<void> _submit() async {
    final l10n = widget.l10n;
    final host = _host.text.trim();
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
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    setState(() {
      _busy = false;
      _duplicate = !added;
      _contactError = l10n.syncPeerUnreachable;
    });
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
