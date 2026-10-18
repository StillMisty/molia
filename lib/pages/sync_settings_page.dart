import 'dart:async';

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
import 'sync_advanced_page.dart';
import 'sync_content_page.dart';
import 'sync_dialogs.dart';
import 'sync_labels.dart';
import 'sync_log_page.dart';
import 'sync_pairing_dialogs.dart';

/// 跨设备同步设置页：一页闭环的**配对工作台**。
///
/// 信息架构（首屏只留用户真正要做的事）：①传输方式（局域网 / WebDAV 两路
/// 开关 + 最近一轮结论）②配对（复制 / 二维码 / 加入其它设备）③已配对设备
/// 名册 ④同步内容 / 日志 / 高级设置入口。设备名、设备 id、口令、地址列表、
/// 端口、地址簿这些底层细节收进「高级设置」子页（`sync_advanced_page.dart`）。
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

  @override
  void initState() {
    super.initState();
    // 进入设置页 = 本机地址缓存的真实失效点：网络切换后重进即可看到新地址
    // （配对码的地址候选也走这份缓存）。
    context.read<SyncProvider>().refreshLocalEndpoints();
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

  /// ② 配对：复制配对码（行尾二维码按钮）/ 加入其它设备。
  ///
  /// 口令随配对码一起交给对端，首屏不再单列口令行；「输入已有口令加入」这类
  /// 手工路径在高级设置里（`sync_advanced_page.dart`）。
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
        // 加入其它设备：粘贴对方配对码 / 手机端扫码 / 手动填地址，都在同一个
        // 弹层里（配对码是主路径，地址是发现失败时的兜底）。
        SettingsNavTile(
          key: const Key('settingsSyncJoinItem'),
          icon: Icons.login_rounded,
          title: l10n.syncPeerAdd,
          subtitle: l10n.syncPeerAddSubtitle,
          onTap: () => unawaited(showSyncAddPeerDialog(context, provider, l10n)),
        ),
      ],
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
      footer: provider.peers.isEmpty
          ? null
          : SettingsSectionHint(text: l10n.syncPeersHint),
      children: [
        if (provider.peers.isEmpty)
          SettingsInfoTile(
            key: const Key('settingsSyncPeersEmpty'),
            icon: Icons.devices_other_rounded,
            title: l10n.syncPeersEmptyTitle,
            subtitle: l10n.syncPeersEmptySubtitle,
          ),
        for (final peer in provider.peers)
          _peerRow(context, provider, l10n, peer, manualByDevice[peer.deviceId]),
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
      nowMs: provider.engine.state.nowMs(),
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
}
