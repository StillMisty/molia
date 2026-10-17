import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/sync_pairing.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../services/local_endpoints_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/device_id.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_content_page.dart';
import 'sync_dialogs.dart';
import 'sync_labels.dart';
import 'sync_log_page.dart';
import 'sync_pairing_dialogs.dart';

/// 跨设备同步设置页：**一页闭环**的配对工作台。
///
/// 信息架构：①开关 + 五态结论 ②本机（设备名 / 设备 id / 口令 / 地址列表 /
/// 端口 / 配对信息）③设备（名册内联 + 添加设备）④传输（局域网 / WebDAV）
/// ⑤同步内容入口 ⑥日志入口。配对是「把本机信息交给对端、把对端地址收进
/// 名册」的一件事，本机与设备信息同屏，配对码一次把双方需要的信息交出去。
/// 子页只留「同步内容」与「同步日志」两个明细面。
///
/// 信任模型：口令即信任根，持有口令的设备完全互信（ADR-0003）。同步何时跑
/// 由调度器声明式决定，页面不提供「立即同步」这类手动主操作；口令与设备 id
/// 都在本页直接可见可复制，配对码把这两样与地址候选打包给对端。
class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

/// 本机信息（地址列表 + 配对码）：与口令 / 端口同源，改动后重建。
typedef _LocalInfo = ({List<LocalEndpoint> endpoints, SyncPairingCode? code});

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  late Future<_LocalInfo> _localInfo;
  Object? _localInfoSignature;

  @override
  void initState() {
    super.initState();
    // 进入设置页 = 本机地址缓存的真实失效点：网络切换后重进即可看到新地址。
    context.read<SyncProvider>().refreshLocalEndpoints();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // provider 通知会触发 didChangeDependencies：只有影响配对码的输入
    // （口令 / 设备名 / 端口 / 开关）变化时才重新枚举地址与重组码。
    final provider = context.watch<SyncProvider>();
    final ports = provider.lanDiscoveryPorts;
    final signature = Object.hash(
      provider.enabled,
      provider.passphrase,
      provider.deviceName,
      provider.deviceId,
      ports.v4,
      ports.v6,
      provider.lanHttpPort,
    );
    if (_localInfoSignature == signature) return;
    _localInfoSignature = signature;
    _localInfo = _loadLocalInfo(provider);
  }

  static Future<_LocalInfo> _loadLocalInfo(SyncProvider provider) async {
    final endpoints = await provider.localEndpoints();
    final code = await provider.pairingCode();
    return (endpoints: endpoints, code: code);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.settingsSyncTitle),
        automaticallyImplyLeading: true,
      ),
      body: FutureBuilder<_LocalInfo>(
        future: _localInfo,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.all(kSettingsPadding),
          children: [
            SettingsSectionCard(
              title: l10n.syncGeneralSection,
              children: [
                SettingsSwitchTile(
                  switchKey: const Key('settingsSyncSwitch'),
                  icon: Icons.sync_rounded,
                  title: l10n.syncEnabledTitle,
                  // 启用后副文案让位给状态结论（一句话）；关闭时才是能力说明。
                  subtitle: provider.enabled
                      ? _statusSubtitle(provider, l10n)
                      : l10n.syncEnabledSubtitle,
                  value: provider.enabled,
                  onChanged: (value) => unawaited(
                      _toggleEnabled(context, provider, value, l10n)),
                ),
              ],
            ),
            if (provider.enabled) ...[
              const SizedBox(height: kSettingsSectionSpacing),
              _localSection(context, provider, l10n, snapshot.data),
              const SizedBox(height: kSettingsSectionSpacing),
              _peersSection(context, provider, l10n),
              const SizedBox(height: kSettingsSectionSpacing),
              _transportsSection(context, provider, l10n),
              const SizedBox(height: kSettingsSectionSpacing),
              _entriesSection(context, provider, l10n),
            ],
          ],
        ),
      ),
    );
  }

  /// ② 本机：设备名 / 设备 id / 口令 / 加入 / 配对信息 / 地址列表 / 端口。
  Widget _localSection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    _LocalInfo? info,
  ) {
    final passphrase = provider.passphrase;
    final code = info?.code;
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
        SettingsNavTile(
          key: const Key('settingsSyncJoinItem'),
          icon: Icons.login_rounded,
          title: l10n.syncPassphraseJoin,
          subtitle: l10n.syncPassphraseJoinHint,
          onTap: () => unawaited(showSyncJoinDialog(context, provider, l10n)),
        ),
        // 分享配对信息：点行 = 复制（含口令，SnackBar 明示）；行尾二维码
        // 按钮才展开二维码弹层（那儿还有一次明确警告）。
        if (code != null)
          SettingsCopyTile(
            key: const Key('settingsSyncPairingShareItem'),
            icon: Icons.qr_code_2_rounded,
            title: l10n.syncPairingShareTitle,
            subtitle: l10n.syncPairingShareSubtitle,
            copyText: code.encode(),
            copiedMessage: l10n.syncPairingCopied,
            trailing: M3EIconButton(
              key: const Key('settingsSyncPairingQrItem'),
              icon: const Icon(Icons.qr_code_rounded),
              variant: M3EIconButtonVariant.tonal,
              semanticLabel: l10n.syncPairingShowQr,
              onPressed: () => unawaited(
                showSyncPairingShareDialog(context, code: code, l10n: l10n),
              ),
            ),
          )
        else
          SettingsInfoTile(
            key: const Key('settingsSyncPairingShareItem'),
            icon: Icons.qr_code_2_rounded,
            title: l10n.syncPairingShareTitle,
            subtitle: l10n.syncPairingNeedsPassphrase,
          ),
        for (final endpoint in info?.endpoints ?? const <LocalEndpoint>[])
          SettingsCopyTile(
            key: Key('settingsSyncLocalAddress-${endpoint.address}'),
            icon: Icons.lan_rounded,
            title: endpoint.address,
            subtitle: endpoint.interfaceName,
            copyText: endpoint.address,
            copiedMessage: l10n.syncLocalAddressCopied,
          ),
        if (info != null && info.endpoints.isEmpty)
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

  /// ③ 设备：名册内联 + 地址簿里未进名册的条目 + 添加设备。
  Widget _peersSection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    final manualByDevice = <String, ManualPeer>{
      for (final entry in provider.manualPeers)
        if (entry.deviceId.isNotEmpty) entry.deviceId: entry,
    };
    final rosterIds = {for (final peer in provider.peers) peer.deviceId};
    // 地址簿里没进名册的条目：认领到身份的（配对码导入即带 id）按设备合并
    // 成一行（点开列出该设备的全部地址）；未认领的候选地址再折叠（见下）。
    final missing = [
      for (final entry in provider.manualPeers)
        if (!rosterIds.contains(entry.deviceId)) entry,
    ];
    final unclaimed = [for (final entry in missing) if (entry.deviceId.isEmpty) entry];
    final claimedGroups = <String, List<ManualPeer>>{};
    for (final entry in missing) {
      if (entry.deviceId.isEmpty) continue;
      claimedGroups.putIfAbsent(entry.deviceId, () => []).add(entry);
    }
    return SettingsSectionCard(
      title: l10n.syncPeersSection,
      footer: SettingsSectionHint(text: l10n.syncPeersHint),
      children: [
        for (final peer in provider.peers)
          _peerRow(context, provider, l10n, peer, manualByDevice[peer.deviceId]),
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
        // 未认领的候选地址：单个直接列（可点开看详情 / 删除）；多个折叠成
        // 一行——配对码一次可导 8 个地址，全展开会把名册撑成「尚未接触」墙。
        // N=1 直列比「候选地址 1 个」更可读，是有意的：只有 N>1 才折叠。
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
        SettingsNavTile(
          key: const Key('settingsSyncAddPeerItem'),
          icon: Icons.add_link_rounded,
          title: l10n.syncPeerAdd,
          subtitle: l10n.syncPeerAddSubtitle,
          onTap: () => unawaited(showSyncAddPeerDialog(context, provider, l10n)),
        ),
      ],
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
    final title = syncPeerDisplayName(peer, manual);
    return SettingsNavTile(
      key: Key('settingsSyncPeer-${peer.deviceId}'),
      icon: manual == null ? Icons.sync_alt_rounded : Icons.link_rounded,
      title: title,
      subtitle: syncPeerSubtitle(
        l10n,
        peer,
        manual,
        nowMs: provider.engine.state.nowMs(),
      ),
      onTap: () => unawaited(showSyncPeerDialog(
        context,
        provider: provider,
        l10n: l10n,
        host: manual?.host,
        title: title,
        peer: peer,
      )),
    );
  }

  /// 地址簿里尚未进名册的未认领条目（手动填的地址 / 配对码里没带身份的）：
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

  /// ④ 传输：局域网（含权限动作）与 WebDAV（含配置入口）。
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

  /// ⑤⑥ 同步内容与日志入口（其余「同步什么 / 发生了什么」的明细）。
  Widget _entriesSection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    return SettingsSectionCard(
      children: [
        SettingsNavTile(
          key: const Key('settingsSyncContentItem'),
          icon: Icons.tune_rounded,
          title: l10n.syncContentSection,
          subtitle: _contentSubtitle(provider, l10n),
          onTap: () => openSettingsSubPage(context, const SyncContentPage()),
        ),
        SettingsNavTile(
          key: const Key('settingsSyncLogItem'),
          icon: Icons.receipt_long_rounded,
          title: l10n.syncLogTitle,
          subtitle: _logSubtitle(provider, l10n),
          onTap: () => openSettingsSubPage(context, const SyncLogPage()),
        ),
      ],
    );
  }

  /// 开关副文案：五态结论 + 相对时间（如「未发现对端 · 3 分钟前」）；
  /// 未跑过任何一轮时只说「尚未同步」。
  static String _statusSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final report = provider.lastReport;
    if (report == null) return l10n.syncNever;
    final peersSeen = report.peersSeen;
    final conclusion = report.outcome == SyncOutcome.ok && peersSeen > 0
        ? l10n.syncStatusSyncedPeers(peersSeen)
        : syncOutcomeText(l10n, report.outcome);
    return '$conclusion · ${syncRelativeTimeText(
      l10n,
      nowMs: provider.engine.state.nowMs(),
      atMs: report.finishedAt,
    )}';
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

  /// 内容入口副文案：全开只说「全部类别」，否则给关闭项数。
  static String _contentSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final off = provider.categories.values.where((on) => !on).length;
    return off == 0 ? l10n.syncContentAllOn : l10n.syncContentOffCount(off);
  }

  /// 日志入口副文案：最近一轮结论 + 时间；没有记录时说「暂无记录」。
  static String _logSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final entries = provider.log;
    if (entries.isEmpty) return l10n.syncLogEmpty;
    final latest = entries.first;
    return '${syncOutcomeText(l10n, latest.outcome)} · ${syncRelativeTimeText(
      l10n,
      nowMs: provider.engine.state.nowMs(),
      atMs: latest.at,
    )}';
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

  Future<void> _toggleEnabled(
    BuildContext context,
    SyncProvider provider,
    bool value,
    AppLocalizations l10n,
  ) async {
    final hadPassphrase = provider.passphrase != null;
    await provider.setEnabled(value);
    if (!context.mounted) return;
    // 首次开启自动生成口令：立刻展示，用户才复制得到（其它设备要输入它）。
    if (value && !hadPassphrase && provider.passphrase != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.syncGeneratedHint)));
      await showSyncPassphraseDialog(context, provider, l10n);
    }
  }
}
