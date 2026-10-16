import 'dart:async';

import 'package:intl/intl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/settings/settings_tiles.dart';

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
              SettingsInfoTile(
                icon: Icons.phone_android_rounded,
                title: provider.deviceName,
                subtitle: l10n.syncPeerThisDevice(_shortId(provider.deviceId)),
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
    final title = peer.name.isEmpty ? _shortId(peer.deviceId) : peer.name;
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
        title: l10n.syncPeerDetailTitle,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.syncPeerAddress(host)),
              if (peer != null && peer.deviceId.isNotEmpty)
                Text(l10n.syncPeerDeviceId(_shortId(peer.deviceId))),
              if (peer != null && peer.lastPullAt > 0)
                Text(l10n.syncPeerLastSync(_time(peer.lastPullAt))),
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
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
        ],
      ),
    );
  }

  /// 添加设备：地址必填（IP / 主机名），名称可选；添加后立刻跑一轮，
  /// 用户马上能看到「接触成功 / 不可达」而不是等下一次定时同步。
  Future<void> _showAddDialog(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    final host = TextEditingController();
    final name = TextEditingController();
    final navigator = Navigator.of(context, rootNavigator: true);
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.syncPeerAddTitle,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              M3ETextField(
                controller: host,
                label: l10n.syncPeerHostLabel,
                placeholder: l10n.syncPeerHostHint,
                leading: const Icon(Icons.lan_rounded),
              ),
              const SizedBox(height: 12),
              M3ETextField(
                controller: name,
                label: l10n.syncPeerNameLabel,
                leading: const Icon(Icons.edit_rounded),
              ),
            ],
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.filled(
            onPressed: () async {
              final value = host.text.trim();
              if (value.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.syncPeerHostInvalid)));
                return;
              }
              navigator.pop();
              await provider.addManualPeer(value, name: name.text);
              await provider.syncNow(manual: true);
            },
            child: Text(l10n.syncSave),
          ),
        ],
      ),
    );
    host.dispose();
    name.dispose();
  }

  /// 对端副标题：传输 + 最后同步 + 落后/时钟偏移/最近失败（有什么说什么）。
  static String _peerSubtitle(AppLocalizations l10n, SyncPeerState peer) {
    final parts = <String>[
      if (peer.transport.isNotEmpty) _transportLabel(l10n, peer.transport),
      if (peer.lastPullAt > 0 || peer.lastPushAt > 0)
        l10n.syncPeerLastSync(_time(peer.lastPullAt > peer.lastPushAt
            ? peer.lastPullAt
            : peer.lastPushAt))
      else
        l10n.syncPeerNever,
      if (peer.behindBy != null && peer.behindBy! > 0)
        l10n.syncPeerBehind(peer.behindBy!),
      if (peer.clockSkewMs != null && peer.clockSkewMs!.abs() > 60 * 1000)
        l10n.syncPeerClockSkew((peer.clockSkewMs!.abs() / 60000).round()),
      if (peer.lastError != null && peer.lastError!.isNotEmpty)
        l10n.syncPeerLastError(peer.lastError!),
    ];
    return parts.join(' · ');
  }

  static String _transportLabel(AppLocalizations l10n, String kind) =>
      switch (kind) {
        'lan' => l10n.syncLanTitle,
        'webdav' => l10n.syncWebdavTitle,
        _ => kind,
      };

  static String _time(int at) =>
      DateFormat('MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(at));

  static String _shortId(String deviceId) =>
      deviceId.length <= 6 ? deviceId : deviceId.substring(deviceId.length - 6);
}
