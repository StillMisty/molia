import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/sync_pairing.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/sync_pairing_scanner.dart';
import 'sync_advanced_page.dart';
import 'sync_content_page.dart';
import 'sync_dialogs.dart';
import 'sync_labels.dart';
import 'sync_log_page.dart';
import 'sync_notices.dart';
import 'sync_pairing_dialogs.dart';
import 'sync_peer_status.dart';

/// 跨设备同步设置页：一页闭环的**配对工作台**。
///
/// 信息架构（首屏只留用户真正要做的事）：①传输方式（局域网 / WebDAV 两路
/// 开关 + 最近一轮结论）②配对（分享 = 复制 / 二维码；加入 = 粘贴 / 扫码）
/// ③已配对设备名册 ④同步内容 / 日志 / 高级设置入口。设备名、设备 id、口令、
/// 网络地址（一行入口，明细进弹窗）、端口、地址簿这些底层细节收进「高级设置」
/// 子页（`sync_advanced_page.dart`）。
///
/// 没有独立总开关：传输开关就是总闸，两路都关 = 同步完全停（轮次 / 入站 /
/// 调度器一并停摆）。传输状态必须留在首屏——「开关已开而实际没有监听」
/// 是排查同步事故的主要来源，不能再藏在子页里。
///
/// 信任模型：口令即信任根，持有口令的设备完全互信（ADR-0003）。同步何时跑
/// 由调度器声明式决定，页面不提供「立即同步」这类手动主操作；配对码把口令、
/// 设备身份与地址候选打包交给对端，本页只需要「复制 / 扫码 / 加入」三件事。
class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  /// 本机配对码（未设口令时为 null）：与口令 / 端口同源，改动后重建。
  late Future<SyncPairingCode?> _pairing;
  Object? _pairingSignature;

  /// 扫码入口可用性（平台 × GMS，见 [SyncPairingScanner.isAvailable]）。
  ///
  /// 探测中与不可用都不构建按钮：不做 loading 占位（闪动比没有按钮更糟），
  /// 也不给「无 GMS 设备」留一个点开才知道不可用的死胡同入口。
  bool _scanAvailable = false;

  @override
  void initState() {
    super.initState();
    // 进入设置页 = 本机地址缓存的真实失效点：网络切换后重进即可看到新地址
    // （配对码的地址候选也走这份缓存）。
    context.read<SyncProvider>().refreshLocalEndpoints();
    unawaited(_probeScanAvailability());
    // 打开同步页自动跑一轮检查：设备行显示的是「最近一轮是否真的接触成功」，
    // 不跑一轮就只能是旧状态。首帧后再触发，避免在构建期通知 provider；
    // 已有轮次在跑时不重复排队（引擎自己的合并只服务变更 / 入站请求）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<SyncProvider>();
      if (!provider.enabled || provider.syncing) return;
      unawaited(provider.syncNow(manual: true));
    });
  }

  Future<void> _probeScanAvailability() async {
    final available = await SyncPairingScanner.isAvailable();
    if (!mounted || available == _scanAvailable) return;
    setState(() => _scanAvailable = available);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // provider 通知会触发 didChangeDependencies：只有影响配对码的输入
    // （口令 / 设备名 / 端口 / 传输开关）变化时才重新枚举地址与重组码。
    // 端口随传输启停变化，所以签名里用两路开关的实际状态，而不是总开关。
    final provider = context.watch<SyncProvider>();
    final ports = provider.lanDiscoveryPorts;
    final signature = Object.hash(
      provider.enabledTransports.contains(SyncTransportKind.lan),
      provider.enabledTransports.contains(SyncTransportKind.webdav),
      provider.passphrase,
      provider.deviceName,
      provider.deviceId,
      ports.v4,
      ports.v6,
      provider.lanHttpPort,
    );
    if (_pairingSignature == signature) return;
    _pairingSignature = signature;
    _pairing = provider.pairingCode();
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
      body: FutureBuilder<SyncPairingCode?>(
        future: _pairing,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.all(kSettingsPadding),
          children: [
            _transportsSection(context, provider, l10n),
            const SizedBox(height: kSettingsSectionSpacing),
            _pairingSection(context, provider, l10n, snapshot.data),
            const SizedBox(height: kSettingsSectionSpacing),
            _peersSection(context, provider, l10n),
            const SizedBox(height: kSettingsSectionSpacing),
            _entriesSection(context, provider, l10n),
          ],
        ),
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
            onTap: () => unawaited(provider.lanPermissionPermanentlyDenied
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

  /// ② 配对：分享配对码（复制 / 二维码）+ 加入其它设备（粘贴 / 扫码）。
  ///
  /// 口令随配对码一起交给对端，首屏不单列口令行；手填地址这类兜底路径在
  /// 高级设置里（`sync_advanced_page.dart`）。
  Widget _pairingSection(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    SyncPairingCode? code,
  ) {
    return SettingsSectionCard(
      title: l10n.syncPairingSection,
      children: [
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
        // 加入其它设备 = 粘贴配对码 / 扫码（移动端）：两条动作路径都在卡片里，
        // 不再有输入弹层——配对码是加入同步的唯一入口，地址兜底在高级设置里。
        SettingsNavTile(
          key: const Key('settingsSyncPasteCodeItem'),
          icon: Icons.content_paste_rounded,
          title: l10n.syncPairingPasteTitle,
          subtitle: l10n.syncPairingPasteSubtitle,
          onTap: () => unawaited(_pastePairingCode()),
        ),
        // 扫码入口 = 平台 × GMS 可用性（无 GMS / 桌面隐藏，只给粘贴）。
        if (_scanAvailable)
          SettingsNavTile(
            key: const Key('settingsSyncScanCodeItem'),
            icon: Icons.qr_code_scanner_rounded,
            title: l10n.syncPairingScanTitle,
            subtitle: l10n.syncPairingScanSubtitle,
            onTap: () => unawaited(_scanPairingCode()),
          ),
      ],
    );
  }

  /// 粘贴配对码：读剪贴板即导入（口令随码传递、地址按码收敛，见
  /// [importSyncPairingText]）；剪贴板里没有码时给一句「先去复制」的提示。
  Future<void> _pastePairingCode() async {
    final provider = context.read<SyncProvider>();
    final l10n = AppLocalizations.of(context)!;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    await importSyncPairingText(
      context,
      provider: provider,
      l10n: l10n,
      raw: data?.text ?? '',
    );
  }

  /// 扫码导入：相机 → 配对码文本 → 与粘贴走同一条导入路径。
  Future<void> _scanPairingCode() async {
    final provider = context.read<SyncProvider>();
    final l10n = AppLocalizations.of(context)!;
    final result = await showSyncPairingScanner(
      context,
      onOpenSettings: provider.openSystemSettings,
    );
    if (result == null || !mounted) return;
    await importSyncPairingText(
      context,
      provider: provider,
      l10n: l10n,
      raw: result,
    );
  }

  /// ④ 已配对设备：名册内联；空名册给一句引导（配对是首屏卡片的事）。
  ///
  /// 地址簿里尚未进名册的条目（配对码导入 / 手填地址的残留）在高级设置里，
  /// 首屏只显示真正的「设备」。
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

  /// 设备区脚注：同步中给「正在同步…」，完成后给本轮已连接设备名（最多
  /// 两个 + 「等 N 台」）；一台都没有就说「本轮没有连上设备」。
  ///
  /// 这是设备区自己的状态，不做全局 App 状态条。空名册且从未跑过一轮时保留
  /// 原来的配对引导，避免首屏出现一句没有上下文的「没有连上设备」。
  static String _peersFooter(
    SyncProvider provider,
    AppLocalizations l10n,
    Map<String, ManualPeer> manualByDevice,
  ) {
    if (provider.syncing) return l10n.syncSyncing;
    final report = provider.lastReport;
    if (report == null && provider.peers.isEmpty) return l10n.syncPeersHint;
    final connected = [
      for (final peer in provider.peers)
        if (resolveSyncPeerConnection(
              peer,
              report: report,
              nowMs: provider.nowMs,
            ) ==
            SyncPeerConnectionStatus.connected)
          syncPeerDisplayName(peer, manualByDevice[peer.deviceId]),
    ];
    if (connected.isEmpty) return l10n.syncRoundNoConnectedPeers;
    final names = connected.take(2).join(l10n.syncPeerNameSeparator);
    final remaining = connected.length - 2;
    return remaining > 0
        ? l10n.syncRoundConnectedMore(names, remaining)
        : l10n.syncRoundConnected(names);
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

  /// ⑤ 同步内容 / 日志 / 高级设置（「同步什么」「发生了什么」与底层明细）。
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
    showSyncNotice(
      context,
      l10n.syncLanPermissionDenied,
      isError: true,
      actionLabel: l10n.syncOpenSystemSettings,
      onAction: () => unawaited(provider.openSystemSettings()),
    );
  }
}
