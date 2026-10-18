import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../services/local_endpoints_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/device_id.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_dialogs.dart';
import 'sync_pairing_dialogs.dart';

/// 同步高级设置子页：设备身份 / 口令 / 网络地址与端口 / 地址簿 / 传输方式。
///
/// 这些是排障与手工接入才用得到的底层信息，从首屏搬到子页——首屏只留配对与
/// 设备（见 `sync_settings_page.dart` 的信息架构说明）。
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
      provider.enabled,
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
            const SizedBox(height: kSettingsSectionSpacing),
            _transportsSection(context, provider, l10n),
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
        // 手工路径：只拿到口令（没有配对码）时在这里输入。
        SettingsNavTile(
          key: const Key('settingsSyncPassphraseJoinItem'),
          icon: Icons.password_rounded,
          title: l10n.syncPassphraseJoin,
          subtitle: l10n.syncPassphraseJoinHint,
          onTap: () => unawaited(showSyncJoinDialog(context, provider, l10n)),
        ),
        for (final endpoint in endpoints ?? const <LocalEndpoint>[])
          SettingsCopyTile(
            key: Key('settingsSyncLocalAddress-${endpoint.address}'),
            icon: Icons.lan_rounded,
            title: endpoint.address,
            subtitle: endpoint.interfaceName,
            copyText: endpoint.address,
            copiedMessage: l10n.syncLocalAddressCopied,
          ),
        if (endpoints != null && endpoints.isEmpty)
          SettingsInfoTile(
            icon: Icons.wifi_off_rounded,
            title: l10n.syncLocalAddressesEmptyTitle,
            subtitle: l10n.syncLocalAddressesEmpty,
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

  /// 地址簿：已认领但未进名册的条目（点开可看详情 / 删除）+ 未认领候选。
  ///
  /// 配对码一次可导 8 个地址，全展开会把名册撑成「尚未接触」墙；未认领候选
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
      footer: SettingsSectionHint(text: l10n.syncPeersHint),
      children: [
        for (final group in claimedGroups.entries)
          SettingsNavTile(
            key: Key('settingsSyncPeer-${group.key}'),
            icon: Icons.link_rounded,
            title: group.value.first.name.isEmpty
                ? group.value.first.host
                : group.value.first.name,
            subtitle:
                '${group.value.map((entry) => entry.host).join(', ')} · ${l10n.syncPeerNotContacted}',
            onTap: () => unawaited(showSyncCandidatesDialog(
              context,
              provider: provider,
              l10n: l10n,
              candidates: group.value,
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

  /// 传输：局域网（含权限动作）与 WebDAV（含配置入口）。
  Widget _transportsSection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    final lanState =
        _transportState(context, provider, l10n, SyncTransportKind.lan);
    final webdavState =
        _transportState(context, provider, l10n, SyncTransportKind.webdav);
    final webdavEnabled =
        provider.enabledTransports.contains(SyncTransportKind.webdav);
    return SettingsSectionCard(
      title: l10n.syncTransportSection,
      children: [
        SettingsSwitchTile(
          switchKey: const Key('settingsSyncLanSwitch'),
          icon: Icons.wifi_rounded,
          title: l10n.syncLanTitle,
          subtitle: lanState.text,
          subtitleColor: lanState.color,
          value: provider.enabledTransports.contains(SyncTransportKind.lan),
          onChanged: (value) => unawaited(
              provider.setTransportEnabled(SyncTransportKind.lan, value)),
        ),
        // 权限被拒时给可行动入口（手动地址救不了权限，只能授权或转 WebDAV）。
        if (_needsLanPermission(provider))
          SettingsNavTile(
            key: const Key('settingsSyncLanPermissionItem'),
            icon: provider.lanPermissionPermanentlyDenied
                ? Icons.settings_rounded
                : Icons.lock_open_rounded,
            title: provider.lanPermissionPermanentlyDenied
                ? l10n.syncOpenSystemSettings
                : l10n.syncLanPermissionTitle,
            subtitle: provider.lanPermissionPermanentlyDenied
                ? l10n.syncLanPermissionPermanentSubtitle
                : l10n.syncLanPermissionSubtitle,
            onTap: () => unawaited(
                provider.lanPermissionPermanentlyDenied
                    ? provider.openSystemSettings()
                    : _requestLanPermission(context, provider, l10n)),
          ),
        SettingsSwitchTile(
          switchKey: const Key('settingsSyncWebdavSwitch'),
          icon: Icons.cloud_rounded,
          title: l10n.syncWebdavTitle,
          subtitle: webdavState.text,
          subtitleColor: webdavState.color,
          value: webdavEnabled,
          onChanged: (value) => unawaited(
              provider.setTransportEnabled(SyncTransportKind.webdav, value)),
        ),
        // 配置入口只在 WebDAV 启用后才有意义（未启用时开关副文案已说明）。
        if (webdavEnabled)
          SettingsNavTile(
            key: const Key('settingsSyncWebdavConfigItem'),
            icon: Icons.settings_rounded,
            title: l10n.syncWebdavConfigTitle,
            subtitle: provider.webdav.isConfigured
                ? provider.webdav.baseUrl
                : l10n.syncWebdavNotConfigured,
            onTap: () =>
                unawaited(showWebdavConfigDialog(context, provider, l10n)),
          ),
      ],
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

  /// 传输副文案：只说状态词（运行中 / 已关闭 / 未配置 / 启动失败 / 缺少权限）。
  ///
  /// 用户主动关闭的传输先于状态判定：开关状态由 `enabled` 表达，关闭后不再
  /// 显示「未配置 / 启动失败」这类残留原因。状态色只作增强：不可用 / 启动失败
  /// 走 warning，运行中且有成功记录走 success。最后成功时间与原始失败细节
  /// 不进首屏（日志子页的失败行里有）。
  static ({String text, Color? color}) _transportState(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    String kind,
  ) {
    final status = provider.transportStatus(kind);
    if (status == null) {
      return (text: l10n.syncTransportNotConfigured, color: null);
    }
    if (!status.enabled) {
      return (text: l10n.syncTransportDisabled, color: null);
    }
    final semantic = AppSemanticColors.of(context);
    final state = switch (status.unavailableReason) {
      SyncUnavailableReason.notConfigured => l10n.syncTransportNotConfigured,
      // 启动类失败只说「启动失败」；原因码细节在日志子页的失败弹层里。
      SyncUnavailableReason.startFailed => l10n.syncTransportStartFailed,
      SyncUnavailableReason.permissionDenied =>
        l10n.syncTransportPermissionDenied,
      _ =>
        status.running ? l10n.syncTransportRunning : l10n.syncTransportStopped,
    };
    final available = status.running && status.unavailableReason == null;
    return (
      text: state,
      color: available
          ? (provider.transportLastSuccessAt(kind) > 0
              ? semantic.success
              : null)
          : semantic.warning,
    );
  }

  /// 局域网因缺少权限而不可用（Android 17+：手动地址也无效，只能授权或转 WebDAV）。
  static bool _needsLanPermission(SyncProvider provider) =>
      provider.lanPermissionNeeded &&
      provider.enabledTransports.contains(SyncTransportKind.lan) &&
      provider.transportStatus(SyncTransportKind.lan)?.unavailableReason ==
          SyncUnavailableReason.permissionDenied;

  /// 用户显式申请权限；仍被拒时给「去系统设置」的下一步动作。
  static Future<void> _requestLanPermission(
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
}
