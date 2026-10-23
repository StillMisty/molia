import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/sync_nearby_pairing.dart';
import '../domain/models/sync_peer_status.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/device_id.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_advanced_page.dart';
import 'sync_content_page.dart';
import 'sync_dialogs.dart';
import 'sync_labels.dart';
import 'sync_log_page.dart';
import 'sync_nearby_pairing_dialogs.dart';
import 'sync_notices.dart';
import 'sync_peer_dialogs.dart';

/// 跨设备同步设置页：一页闭环的设备同步面板。
///
/// 信息架构（首屏只留用户真正要做的事）：①传输方式（局域网 / WebDAV 两路
/// 开关 + 最近一轮结论）②已配对设备名册（含连接状态）③附近设备（一键配对 +
/// 确认码）④同步内容 / 日志 / 高级设置入口。设备名、设备 id、口令、
/// 网络地址（一行入口，明细进弹窗）、端口、地址簿这些底层细节收进「高级设置」
/// 子页（`sync_advanced_page.dart`）。
///
/// 没有独立总开关：传输开关就是总闸，两路都关 = 同步完全停（轮次 / 入站 /
/// 调度器一并停摆）。传输状态必须留在首屏——「开关已开而实际没有监听」
/// 是排查同步事故的主要来源，不能再藏在子页里。
///
/// 信任模型：口令即信任根，持有口令的设备完全互信（ADR-0003）。同步何时跑
/// 由调度器声明式决定，页面不提供「立即同步」这类手动主操作。配对只有一条
/// 路径：附近设备走 `MSP/1` 发现 + 6 位确认码，点击即发起；旧配对码
/// （复制 / 粘贴 / 扫码）已删除，不识别、不迁移。
class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  /// 本页持有的 provider：dispose 时不能再依赖 context，先存一份用于停扫描。
  SyncProvider? _provider;

  /// 附近设备空态：`startScan` 的探测波次很短，但服务端不会在「扫完仍为空」
  /// 时再推事件；用一个本地计时把「正在查找」切换到「没有发现设备」。
  Timer? _nearbySettleTimer;
  bool _nearbySearchSettled = false;
  bool _lanEnabled = false;

  /// 局域网传输是否真正运行：授权前开关可能已开启但传输不可用，
  /// 授权成功后由 false → true 触发一次附近设备扫描。
  bool _lanRunning = false;

  @override
  void initState() {
    super.initState();
    // 进入设置页 = 本机地址缓存的真实失效点：网络切换后重进即可看到新地址
    // （附近设备探测与手动地址兜底也走这份缓存）。
    final provider = context.read<SyncProvider>();
    _provider = provider;
    _lanEnabled = _isLanEnabled(provider);
    _lanRunning = _isLanRunning(provider);
    provider.refreshLocalEndpoints();
    // 打开同步页自动检查一轮：设备行显示的是「最近一轮是否真的接触成功」，
    // 不跑一轮就只能是旧状态。首帧后再触发，避免在构建期通知 provider；
    // 走调度器的 check 轮（省电 / 蜂窝暂停 / 已有轮次在跑时由调度器跳过）。
    // 局域网已开时同时开始附近设备探测（探测失败 / 后台由服务拒绝，空态可重试）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = _provider;
      if (current == null) return;
      unawaited(current.checkConnections());
      if (_isLanEnabled(current)) unawaited(_startNearbyScan(current));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // provider 通知会触发 didChangeDependencies：局域网开关变化时重扫
    // 附近设备（端口 / 地址变化由扫描端自己处理）。开关原本已开、只是
    // 传输从不可用变为运行（例如刚授权）时也要补一次扫描。
    final provider = context.watch<SyncProvider>();
    _provider = provider;
    final lanEnabled = _isLanEnabled(provider);
    final lanRunning = _isLanRunning(provider);
    if (_lanEnabled != lanEnabled) {
      _lanEnabled = lanEnabled;
      _lanRunning = lanRunning;
      if (lanEnabled) {
        _scheduleNearbyScan();
      } else {
        _cancelNearbySettle();
        _nearbySearchSettled = false;
        provider.stopNearbyScan();
      }
      return;
    }
    final becameRunning = lanRunning && !_lanRunning;
    _lanRunning = lanRunning;
    if (becameRunning) _scheduleNearbyScan();
  }

  @override
  void dispose() {
    _nearbySettleTimer?.cancel();
    _nearbySettleTimer = null;
    // 离开同步页就停止探测并清空候选：候选只服务这一页，后台不保留。
    _provider?.stopNearbyScan();
    super.dispose();
  }

  static bool _isLanEnabled(SyncProvider provider) =>
      provider.enabledTransports.contains(SyncTransportKind.lan);

  static bool _isLanRunning(SyncProvider provider) =>
      _isLanEnabled(provider) &&
      (provider.transportStatus(SyncTransportKind.lan)?.running ?? false);

  /// 传输开关在事件里变化：等本帧结束再探测，避免在 build / didChangeDependencies
  /// 期间同步推流触发重入。
  void _scheduleNearbyScan() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = _provider;
      if (provider == null || !_isLanEnabled(provider)) return;
      unawaited(_startNearbyScan(provider));
    });
  }

  Future<void> _startNearbyScan(SyncProvider provider) async {
    _nearbySettleTimer?.cancel();
    if (mounted && _nearbySearchSettled) {
      setState(() => _nearbySearchSettled = false);
    }
    final started = await provider.startNearbyScan();
    if (!mounted) return;
    if (!started) {
      // 后台 / 蜂窝 / 传输刚停都会拒绝扫描：直接给「没发现 + 重试」，
      // 不能永远停在「正在查找」。
      if (!_nearbySearchSettled) {
        setState(() => _nearbySearchSettled = true);
      }
      return;
    }
    _nearbySettleTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted || _nearbySearchSettled) return;
      setState(() => _nearbySearchSettled = true);
    });
  }

  void _cancelNearbySettle() {
    _nearbySettleTimer?.cancel();
    _nearbySettleTimer = null;
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
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          _transportsSection(context, provider, l10n),
          const SizedBox(height: kSettingsSectionSpacing),
          _peersSection(context, provider, l10n),
          const SizedBox(height: kSettingsSectionSpacing),
          _nearbySection(context, provider, l10n),
          const SizedBox(height: kSettingsSectionSpacing),
          _entriesSection(context, provider, l10n),
        ],
      ),
    );
  }

  /// ① 传输方式：局域网（含权限动作）与 WebDAV（含配置入口）。
  ///
  /// 开关即总闸：两路都关 = 同步完全停。footer 承担原总开关副文案的职责——
  /// 最近一轮结论 + 相对时间；两路都关时改为一句「同步不会运行」的提示，
  /// 免得「没同步」被误读成故障。
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
      footer: SettingsSectionHint(
        text: provider.enabledTransports.isEmpty
            ? l10n.syncTransportAllOffHint
            : _statusSubtitle(provider, l10n),
      ),
      children: [
        SettingsSwitchTile(
          switchKey: const Key('settingsSyncLanSwitch'),
          icon: Icons.wifi_rounded,
          title: l10n.syncLanTitle,
          subtitle: lanState.text,
          subtitleColor: lanState.color,
          value: provider.enabledTransports.contains(SyncTransportKind.lan),
          onChanged: (value) =>
              unawaited(_setLanEnabled(context, provider, l10n, value)),
        ),
        // 权限未授予时给常驻、可行动的入口（与桌面歌词未授权提示同款）：
        // 拒绝后开关会回到关闭，但警告行保留「去授权」，不用再开一次开关。
        if (provider.lanPermissionNeedsAttention)
          _lanPermissionNotice(context, provider, l10n),
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

  /// ② 已配对设备：名册内联（含连接状态）；空名册给一句引导（配对在下方
  /// 「附近设备」卡片）。
  ///
  /// 地址簿里尚未进名册的条目（手填地址的残留）在高级设置里，首屏只显示
  /// 真正的「设备」。
  Widget _peersSection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    final manualByDevice = <String, ManualPeer>{
      for (final entry in provider.manualPeers)
        if (entry.deviceId.isNotEmpty) entry.deviceId: entry,
    };
    return SettingsSectionCard(
      title: l10n.syncPeersSection,
      footer: SettingsSectionHint(
        text: _peersFooter(provider, l10n, manualByDevice),
      ),
      children: [
        if (provider.peers.isEmpty)
          SettingsInfoTile(
            key: const Key('settingsSyncPeersEmpty'),
            icon: Icons.devices_other_rounded,
            title: l10n.syncPeersEmptyTitle,
            subtitle: l10n.syncPeersEmptySubtitle,
          ),
        for (final peer in provider.peers)
          _peerRow(
              context, provider, l10n, peer, manualByDevice[peer.deviceId]),
      ],
    );
  }

  /// 设备区脚注：同步中给「正在同步…」，完成后给本轮已同步设备名（最多
  /// 两个 + 「另有 N 台」）；一台都没有就说「本轮没有连上设备」。
  ///
  /// 用传输中性的「已同步」而不是「已连接」：WebDAV 设备只是云端同步过，
  /// 不代表在线（行内状态另有「云端已同步 / 云端未同步」）。这是设备区自己
  /// 的状态，不做全局 App 状态条。空名册且从未跑过一轮时保留原来的配对引导；
  /// 有名册但没有报告时只能说「还没有连接记录」，不能断言本轮没连上。
  static String _peersFooter(
    SyncProvider provider,
    AppLocalizations l10n,
    Map<String, ManualPeer> manualByDevice,
  ) {
    if (provider.syncing) return l10n.syncSyncing;
    final report = provider.lastReport;
    if (report == null) {
      return provider.peers.isEmpty
          ? l10n.syncPeersHint
          : l10n.syncRoundNoRecords;
    }
    final synced = [
      for (final peer in provider.peers)
        if (resolveSyncPeerConnection(
              peer,
              report: report,
              nowMs: provider.nowMs,
            ) ==
            SyncPeerConnectionStatus.connected)
          syncPeerDisplayName(peer, manualByDevice[peer.deviceId]),
    ];
    if (synced.isEmpty) return l10n.syncRoundNoConnectedPeers;
    final names = synced.take(2).join(l10n.syncPeerNameSeparator);
    final remaining = synced.length - 2;
    return remaining > 0
        ? l10n.syncRoundSyncedMore(names, remaining)
        : l10n.syncRoundSynced(names);
  }

  /// ③ 附近设备（`MSP/1` 候选）：局域网已开时自动探测，点击即配对。
  ///
  /// 这里只展示「未配对」候选：已在名册里的设备由上面的设备卡负责状态，
  /// 同一台机器不能在两处出现两种说法。局域网关闭时只说明下一步，不重复
  /// 放一个开关（开关只有传输卡一处）。
  Widget _nearbySection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    return SettingsSectionCard(
      title: l10n.syncNearbySection,
      footer: SettingsSectionHint(text: l10n.syncNearbyFooter),
      children: [
        if (!_isLanEnabled(provider))
          SettingsInfoTile(
            key: const Key('settingsSyncNearbyLanOff'),
            icon: Icons.wifi_off_rounded,
            title: l10n.syncNearbyLanOffTitle,
            subtitle: l10n.syncNearbyLanOffHint,
          )
        else
          StreamBuilder<List<SyncNearbyDevice>>(
            stream: provider.nearbyDevices,
            builder: (context, snapshot) {
              final pairedIds = {
                for (final peer in provider.peers) peer.deviceId,
              };
              final devices = [
                for (final device
                    in snapshot.data ?? const <SyncNearbyDevice>[])
                  if (device.deviceId != provider.deviceId &&
                      !pairedIds.contains(device.deviceId))
                    device,
              ];
              if (devices.isEmpty) {
                return SettingsRows(
                  children: [
                    SettingsInfoTile(
                      key: const Key('settingsSyncNearbyEmpty'),
                      icon: Icons.devices_other_rounded,
                      title: _nearbySearchSettled
                          ? l10n.syncNearbyEmptyTitle
                          : l10n.syncNearbySearching,
                      subtitle: _nearbySearchSettled
                          ? l10n.syncNearbyEmptyHint
                          : l10n.syncNearbySearchHint,
                    ),
                    SettingsNavTile(
                      key: const Key('settingsSyncNearbyRescan'),
                      icon: Icons.refresh_rounded,
                      title: l10n.syncNearbyRescan,
                      subtitle: l10n.syncNearbySearchHint,
                      onTap: () => unawaited(_startNearbyScan(provider)),
                    ),
                  ],
                );
              }
              return SettingsRows(
                children: [
                  for (final device in devices)
                    SettingsNavTile(
                      key: Key('settingsSyncNearby-${device.deviceId}'),
                      icon: Icons.devices_other_rounded,
                      title: _nearbyDeviceName(device),
                      subtitle: device.hasGroup
                          ? '${l10n.syncNearbyTapToPair} · '
                              '${l10n.syncNearbyHasGroup}'
                          : l10n.syncNearbyTapToPair,
                      onTap: () => unawaited(
                        showSyncNearbyPairingDialog(
                          context,
                          provider: provider,
                          device: device,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  static String _nearbyDeviceName(SyncNearbyDevice device) {
    final name = device.name.trim();
    return name.isEmpty ? shortDeviceId(device.deviceId) : name;
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
        nowMs: provider.nowMs,
        report: provider.lastReport,
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

  /// ④ 同步内容 / 日志 / 高级设置（「同步什么」「发生了什么」与底层明细）。
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
        // 高级：设备名 / 口令 / 地址与端口 / 地址簿。
        SettingsNavTile(
          key: const Key('settingsSyncAdvancedItem'),
          icon: Icons.settings_rounded,
          title: l10n.syncAdvancedTitle,
          subtitle: l10n.syncAdvancedSubtitle,
          onTap: () => openSettingsSubPage(context, const SyncAdvancedPage()),
        ),
      ],
    );
  }

  /// 传输卡片 footer：五态结论 + 相对时间（如「未发现对端 · 3 分钟前」）；
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
      nowMs: provider.nowMs,
      atMs: report.finishedAt,
    )}';
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
      nowMs: provider.nowMs,
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

  /// 开 / 关局域网：未授权时不假装开启，回退到关闭并提示授权。
  Future<void> _setLanEnabled(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    bool value,
  ) async {
    final enabled =
        await provider.setTransportEnabled(SyncTransportKind.lan, value);
    if (enabled || !value || !context.mounted) return;
    _showLanPermissionNotice(context, provider, l10n);
  }

  /// 底栏权限提示：文案 / 动作与桌面歌词未授权提示保持一致。
  void _showLanPermissionNotice(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    final permanent = provider.lanPermissionPermanentlyDenied;
    showSyncNotice(
      context,
      l10n.syncLanPermissionNeeded,
      isError: true,
      actionLabel:
          permanent ? l10n.syncOpenSystemSettings : l10n.syncLanPermissionGrant,
      onAction: () => unawaited(permanent
          ? provider.openSystemSettings()
          : _setLanEnabled(context, provider, l10n, true)),
    );
  }

  /// 常驻警告行（与桌面歌词未授权的 `⚠ 需要悬浮窗权限 + 去授权` 同款）。
  ///
  /// 拒绝后开关已经关闭，这一行仍保留入口：不必再开一次开关就能重试授权，
  /// 永久拒绝时动作改为「去系统设置」。
  Widget _lanPermissionNotice(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    final permanent = provider.lanPermissionPermanentlyDenied;
    final theme = Theme.of(context);
    return Padding(
      key: const Key('settingsSyncLanPermissionItem'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: AppSemanticColors.of(context).warning,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l10n.syncLanPermissionNeeded,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          M3EButton.icon(
            key: const Key('settingsSyncLanPermissionGrant'),
            style: M3EButtonStyle.text,
            onPressed: () => unawaited(permanent
                ? provider.openSystemSettings()
                : _setLanEnabled(context, provider, l10n, true)),
            icon: const Icon(Icons.lock_open_rounded, size: 18),
            label: Text(
              permanent
                  ? l10n.syncOpenSystemSettings
                  : l10n.syncLanPermissionGrant,
            ),
          ),
        ],
      ),
    );
  }
}
