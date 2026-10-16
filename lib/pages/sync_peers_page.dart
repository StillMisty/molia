import 'package:intl/intl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/settings/settings_tiles.dart';

/// 已配对设备（同步名册）：本机 + 每台对端的最近接触情况。
///
/// 为什么单独一页：名册条数随设备数增长，放在设置首屏会把主要动作（立即同步、
/// 传输开关）挤下去；这里只读、不承载操作，符合「首屏给结论、子页给明细」。
class SyncPeersPage extends StatelessWidget {
  const SyncPeersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    final peers = provider.peers;
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
                subtitle: l10n.syncPeerThisDevice(
                  _shortId(provider.deviceId),
                ),
              ),
              for (final peer in peers)
                SettingsInfoTile(
                  key: Key('settingsSyncPeer-${peer.deviceId}'),
                  icon: Icons.sync_alt_rounded,
                  title: peer.name.isEmpty
                      ? _shortId(peer.deviceId)
                      : peer.name,
                  subtitle: _peerSubtitle(l10n, peer),
                ),
            ],
          ),
        ],
      ),
    );
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
