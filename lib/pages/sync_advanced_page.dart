import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../services/local_endpoints_service.dart';
import '../utils/device_id.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_dialogs.dart';
import 'sync_pairing_dialogs.dart';

/// 同步高级设置子页：设备身份 / 口令 / 网络地址与端口 / 地址簿。
///
/// 这些是排障与手工接入才用得到的底层信息，从首屏搬到子页——首屏只留用户
/// 真正要做的事：传输方式、配对与设备（见 `sync_settings_page.dart` 的信息
/// 架构说明）。
class SyncAdvancedPage extends StatefulWidget {
  const SyncAdvancedPage({super.key});

  @override
  State<SyncAdvancedPage> createState() => _SyncAdvancedPageState();
}

class _SyncAdvancedPageState extends State<SyncAdvancedPage> {
  late Future<List<LocalEndpoint>> _endpoints;
  Object? _endpointsSignature;

  @override
  void initState() {
    super.initState();
    // 进入页 = 本机地址缓存的真实失效点：网络切换后重进即可看到新地址。
    context.read<SyncProvider>().refreshLocalEndpoints();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.watch<SyncProvider>();
    final ports = provider.lanDiscoveryPorts;
    final signature = Object.hash(
      provider.enabledTransports.contains(SyncTransportKind.lan),
      ports.v4,
      ports.v6,
      provider.lanHttpPort,
    );
    if (_endpointsSignature == signature) return;
    _endpointsSignature = signature;
    _endpoints = provider.localEndpoints();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.syncAdvancedTitle),
        automaticallyImplyLeading: true,
      ),
      body: FutureBuilder<List<LocalEndpoint>>(
        future: _endpoints,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.all(kSettingsPadding),
          children: [
            _localSection(context, provider, l10n, snapshot.data),
            const SizedBox(height: kSettingsSectionSpacing),
            _peersSection(context, provider, l10n),
          ],
        ),
      ),
    );
  }

  /// 本机：设备名 / 设备 id / 口令 / 加入口令 / 地址列表 / 端口。
  Widget _localSection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    List<LocalEndpoint>? endpoints,
  ) {
    final passphrase = provider.passphrase;
    return SettingsSectionCard(
      title: l10n.syncLocalSection,
      footer: SettingsSectionHint(text: l10n.syncLocalSectionHint),
      children: [
        SettingsNavTile(
          key: const Key('settingsSyncDeviceNameItem'),
          icon: Icons.devices_rounded,
          title: l10n.syncDeviceNameTitle,
          subtitle: provider.deviceName,
          onTap: () =>
              unawaited(showSyncRenameDialog(context, provider, l10n)),
        ),
        SettingsCopyTile(
          key: const Key('settingsSyncPeerSelfItem'),
          icon: Icons.phone_android_rounded,
          title: l10n.syncPeerThisDeviceTitle,
          subtitle: l10n.syncPeerThisDevice(shortDeviceId(provider.deviceId)),
          copyText: provider.deviceId,
          copiedMessage: l10n.syncPeerDeviceIdCopied,
        ),
        SettingsNavTile(
          key: const Key('settingsSyncPassphraseItem'),
          icon: Icons.key_rounded,
          title: l10n.syncPassphraseTitle,
          subtitle: passphrase == null
              ? l10n.syncPassphraseNotSet
              : provider.maskedPassphrase,
          onTap: () =>
              unawaited(showSyncPassphraseDialog(context, provider, l10n)),
        ),
        // 网络地址：一行入口（双栈 + 多网卡的地址明细收进弹窗，不撑长卡片）。
        SettingsNavTile(
          key: const Key('settingsSyncLocalAddressesItem'),
          icon: Icons.lan_rounded,
          title: l10n.syncNetworkAddresses,
          subtitle: endpoints == null
              ? l10n.syncNetworkAddressesCount(0)
              : endpoints.isEmpty
                  ? l10n.syncLocalAddressesEmptyTitle
                  : l10n.syncNetworkAddressesCount(endpoints.length),
          onTap: () => unawaited(showSyncLocalAddressesDialog(
            context,
            provider: provider,
            l10n: l10n,
          )),
        ),
        SettingsInfoTile(
          key: const Key('settingsSyncProbePortItem'),
          icon: Icons.settings_ethernet_rounded,
          title: l10n.syncLocalProbePort,
          subtitle: _probePortSubtitle(l10n, provider.lanDiscoveryPorts),
        ),
        SettingsInfoTile(
          key: const Key('settingsSyncHttpPortItem'),
          icon: Icons.http_rounded,
          title: l10n.syncLocalHttpPort,
          subtitle: provider.lanHttpPort > 0
              ? '${provider.lanHttpPort}'
              : l10n.syncLocalHttpPortUnavailable,
        ),
      ],
    );
  }

  /// 地址簿：手动连接入口 + 已认领但未进名册的条目（点开可看详情 / 删除）
  /// + 未认领候选。
  ///
  /// 配对码一次可导 8 个地址，全展开会把名册撑成「还没连上」墙；未认领候选
  /// 多个折叠成一行，N=1 直列（比「候选地址 1 个」更可读）。
  Widget _peersSection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    final rosterIds = {for (final peer in provider.peers) peer.deviceId};
    final missing = [
      for (final entry in provider.manualPeers)
        if (!rosterIds.contains(entry.deviceId)) entry,
    ];
    final unclaimed = [
      for (final entry in missing)
        if (entry.deviceId.isEmpty) entry,
    ];
    final claimedGroups = <String, List<ManualPeer>>{};
    for (final entry in missing) {
      if (entry.deviceId.isEmpty) continue;
      claimedGroups.putIfAbsent(entry.deviceId, () => []).add(entry);
    }
    return SettingsSectionCard(
      title: l10n.syncPeersSection,
      footer: SettingsSectionHint(text: l10n.syncManualConnectHint),
      children: [
        // 手动连接：自动发现失败（多网段 / 防火墙 / VPN）时的兜底路径。
        SettingsNavTile(
          key: const Key('settingsSyncManualConnectItem'),
          icon: Icons.add_link_rounded,
          title: l10n.syncManualConnect,
          subtitle: l10n.syncManualConnectSubtitle,
          onTap: () => unawaited(showSyncManualPeerDialog(
            context,
            provider,
            l10n,
          )),
        ),
        for (final group in claimedGroups.entries)
          SettingsNavTile(
            key: Key('settingsSyncPeer-${group.key}'),
            icon: Icons.link_rounded,
            title: group.value.first.name.isEmpty
                ? group.value.first.host
                : group.value.first.name,
            subtitle:
                '${l10n.syncPeerAddressCount(group.value.length)} · ${l10n.syncPeerNever}',
            onTap: () => unawaited(showSyncPeerAddressesDialog(
              context,
              provider: provider,
              l10n: l10n,
              title: group.value.first.name.isEmpty
                  ? group.value.first.host
                  : group.value.first.name,
              entries: group.value,
            )),
          ),
        if (unclaimed.length == 1)
          _pendingManualRow(context, provider, l10n, unclaimed.single)
        else if (unclaimed.length > 1)
          SettingsNavTile(
            key: const Key('settingsSyncPeerCandidatesItem'),
            icon: Icons.link_rounded,
            title: l10n.syncPeerCandidatesTitle(unclaimed.length),
            subtitle: l10n.syncPeerCandidatesSubtitle,
            onTap: () => unawaited(showSyncCandidatesDialog(
              context,
              provider: provider,
              l10n: l10n,
              candidates: unclaimed,
            )),
          ),
      ],
    );
  }

  /// 地址簿里尚未进名册的未认领条目（手填地址 / 配对码里没带身份的）：
  /// 点开可看详情 / 删除。
  Widget _pendingManualRow(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    ManualPeer entry,
  ) {
    final title = entry.name.isEmpty ? entry.host : entry.name;
    return SettingsNavTile(
      key: Key('settingsSyncPeer-${entry.host}'),
      icon: Icons.link_rounded,
      title: title,
      subtitle: '${entry.host} · ${l10n.syncPeerNotContacted}',
      onTap: () => unawaited(showSyncPeerDialog(
        context,
        provider: provider,
        l10n: l10n,
        host: entry.host,
        title: title,
      )),
    );
  }

  /// 探测端口副标题：两族同值折叠成一个数字；独立降级（端口不同 / 单族
  /// 不可用）时按族列出，用户才能按族把地址 + 端口一起交给对端。
  static String _probePortSubtitle(
    AppLocalizations l10n,
    ({int v4, int v6}) ports,
  ) {
    if (ports.v4 == 0 && ports.v6 == 0) {
      return l10n.syncLocalProbePortUnavailable;
    }
    if (ports.v4 == ports.v6) return '${ports.v4}';
    return l10n.syncLocalProbePortPerFamily(
      ports.v4 > 0 ? '${ports.v4}' : '—',
      ports.v6 > 0 ? '${ports.v6}' : '—',
    );
  }
}
