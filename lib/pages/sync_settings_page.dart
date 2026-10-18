import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/sync_pairing.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_advanced_page.dart';
import 'sync_content_page.dart';
import 'sync_labels.dart';
import 'sync_log_page.dart';
import 'sync_pairing_dialogs.dart';

/// 跨设备同步设置页：一页闭环的**配对工作台**。
///
/// 信息架构（首屏只留用户真正要做的事）：①开关 + 五态结论 ②配对（复制 /
/// 二维码 / 加入其它设备）③已配对设备名册 ④同步内容 / 日志 / 高级设置入口。
/// 设备名、设备 id、口令、地址列表、端口、传输方式、地址簿这些底层细节全部
/// 收进「高级设置」子页（`sync_advanced_page.dart`）——首屏少即是多。
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
                  onChanged: (value) => unawaited(provider.setEnabled(value)),
                ),
              ],
            ),
            if (provider.enabled) ...[
              const SizedBox(height: kSettingsSectionSpacing),
              _pairingSection(context, provider, l10n, snapshot.data),
              const SizedBox(height: kSettingsSectionSpacing),
              _peersSection(context, provider, l10n),
              const SizedBox(height: kSettingsSectionSpacing),
              _entriesSection(context, provider, l10n),
            ],
          ],
        ),
      ),
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

  /// ③ 已配对设备：名册内联；空名册给一句引导（配对是首屏卡片的事）。
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
        // 高级：设备名 / 口令 / 地址与端口 / 传输方式 / 地址簿。
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
}
