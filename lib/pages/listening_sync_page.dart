/// 设置 › 内容与来源 › 听歌同步。
///
/// 一个入口覆盖两个服务：总开关 + 隐私说明 + 两个服务行。连接前先看同意书；
/// 状态只反映本机（设备本地开关 / 凭证是否存在），不外泄口令或请求内容。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/scrobble.dart';
import '../l10n/app_localizations.dart';
import '../services/scrobble/scrobble_service.dart';
import '../theme/m3e_context.dart';
import '../widgets/empty_state.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

class ListeningSyncPage extends StatefulWidget {
  const ListeningSyncPage({super.key});

  @override
  State<ListeningSyncPage> createState() => _ListeningSyncPageState();
}

class _ListeningSyncPageState extends State<ListeningSyncPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 凭据在安全存储里：只在本页打开时读，启动路径不碰钥匙串。
    unawaited(context.read<ScrobbleService?>()?.init());
  }

  /// 服务名的唯一来源：设置行、同意书、断开确认与 Last.fm 对话框共用。
  String _targetName(ScrobbleTarget target) => switch (target) {
    ScrobbleTarget.listenBrainz => 'ListenBrainz',
    ScrobbleTarget.lastFm => 'Last.fm',
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final service = context.watch<ScrobbleService?>();
    if (l10n == null) return const SizedBox.shrink();
    final children = service == null
        ? [
            EmptyState(
              icon: Icons.cloud_off_rounded,
              message: l10n.listeningSyncUnavailable,
            ),
          ]
        : _sections(context, l10n, service);
    return SettingsSubPage(title: l10n.listeningSyncTitle, children: children);
  }

  List<Widget> _sections(
    BuildContext context,
    AppLocalizations l10n,
    ScrobbleService service,
  ) {
    return [
      SettingsSectionCard(
        title: l10n.listeningSyncTitle,
        footer: SettingsSectionHint(text: l10n.listeningSyncIntro),
        children: [
          SettingsSwitchTile(
            switchKey: const Key('listeningSyncMasterSwitch'),
            icon: Icons.sync_rounded,
            title: l10n.listeningSyncMaster,
            subtitle: l10n.listeningSyncMasterSubtitle,
            value: service.masterEnabled,
            onChanged: _busy
                ? (_) {}
                : (value) => service.setMasterEnabled(value),
          ),
        ],
      ),
      const SizedBox(height: kSettingsSectionSpacing),
      SettingsSectionCard(
        title: l10n.listeningSyncSentTitle,
        children: [
          _privacyTile(
            context,
            icon: Icons.outbox_rounded,
            text: l10n.listeningSyncSent,
          ),
          _privacyTile(
            context,
            icon: Icons.block_rounded,
            text: l10n.listeningSyncNotSent,
          ),
          _privacyTile(
            context,
            icon: Icons.public_rounded,
            text: l10n.listeningSyncNetwork,
          ),
        ],
      ),
      const SizedBox(height: kSettingsSectionSpacing),
      _targetSection(
        context,
        l10n,
        service,
        target: ScrobbleTarget.listenBrainz,
        icon: Icons.headphones_rounded,
        onConnect: _connectListenBrainz,
        projectUrl: Uri.parse('https://listenbrainz.org'),
        learnMore: l10n.listeningSyncLearnMoreListenBrainz,
      ),
      const SizedBox(height: kSettingsSectionSpacing),
      _targetSection(
        context,
        l10n,
        service,
        target: ScrobbleTarget.lastFm,
        icon: Icons.radio_rounded,
        onConnect: _connectLastFm,
        projectUrl: Uri.parse('https://www.last.fm'),
        learnMore: l10n.listeningSyncLearnMoreLastFm,
      ),
    ];
  }

  Widget _privacyTile(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: kSettingsRowPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: kSettingsSmallSpacing + 4),
          Expanded(
            child: Text(
              text,
              style: context.typeScale.bodyMedium.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _targetSection(
    BuildContext context,
    AppLocalizations l10n,
    ScrobbleService service, {
    required ScrobbleTarget target,
    required IconData icon,
    required Future<void> Function(ScrobbleService) onConnect,
    required Uri projectUrl,
    required String learnMore,
  }) {
    final title = _targetName(target);
    final status = service.statusOf(target);
    final connected =
        service.activeFor(target) || status == ScrobbleTargetStatus.connected;
    final queued = service.queuedFor(target);
    final statusText = _statusText(l10n, service, target, status, queued);
    return SettingsSectionCard(
      title: title,
      footer: Align(
        alignment: Alignment.centerLeft,
        child: M3EButton.text(
          onPressed: () => service.openExternal(projectUrl),
          child: Text(learnMore),
        ),
      ),
      children: [
        SettingsInfoTile(
          icon: icon,
          title: title,
          subtitle: statusText,
          trailing: connected
              ? M3EButton.text(
                  onPressed: _busy
                      ? null
                      : () => _disconnect(context, l10n, service, target),
                  child: Text(l10n.listeningSyncDisconnect),
                )
              : M3EButton.filled(
                  onPressed: _busy ? null : () => onConnect(service),
                  child: Text(l10n.listeningSyncConnect),
                ),
        ),
      ],
    );
  }

  String _statusText(
    AppLocalizations l10n,
    ScrobbleService service,
    ScrobbleTarget target,
    ScrobbleTargetStatus status,
    int queued,
  ) {
    final base = switch (status) {
      ScrobbleTargetStatus.disconnected => l10n.listeningSyncDisconnected,
      ScrobbleTargetStatus.connected =>
        service.accountOf(target).isEmpty
            ? l10n.listeningSyncConnected
            : l10n.listeningSyncConnectedAs(service.accountOf(target)),
      ScrobbleTargetStatus.needsConsent => l10n.listeningSyncNeedsConsent,
      ScrobbleTargetStatus.needsAuthorization => l10n.listeningSyncNeedsAuth,
      ScrobbleTargetStatus.retrying => l10n.listeningSyncRetrying,
      ScrobbleTargetStatus.error => l10n.listeningSyncError,
    };
    return queued > 0 ? '$base · ${l10n.listeningSyncQueued(queued)}' : base;
  }

  Future<void> _connectListenBrainz(ScrobbleService service) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await _ensureConsent(service, ScrobbleTarget.listenBrainz)) return;
    if (!mounted) return;
    final password = await _askToken();
    if (!mounted || password == null || password.trim().isEmpty) return;
    setState(() => _busy = true);
    final result = await service.connectListenBrainz(password);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case ScrobbleConnectResult.connected:
        M3ESnackbar.show(context, message: l10n.listeningSyncConnected);
      case ScrobbleConnectResult.invalidCredential:
        M3ESnackbar.show(context, message: l10n.listeningSyncTokenInvalid);
      case ScrobbleConnectResult.unreachable:
        M3ESnackbar.show(context, message: l10n.listeningSyncTokenUnreachable);
    }
  }

  Future<void> _connectLastFm(ScrobbleService service) async {
    final l10n = AppLocalizations.of(context)!;
    if (!service.lastFmConfigured) {
      M3ESnackbar.show(context, message: l10n.listeningSyncLastFmNotConfigured);
      return;
    }
    if (!await _ensureConsent(service, ScrobbleTarget.lastFm)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final stage = await service.beginLastFmAuthorization();
    if (!mounted) return;
    setState(() => _busy = false);
    if (stage != LastFmAuthStage.awaitingUser) {
      M3ESnackbar.show(context, message: l10n.listeningSyncLastFmFailed);
      return;
    }
    if (!await _confirmLastFm()) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final completed = await service.completeLastFmAuthorization();
    if (!mounted) return;
    setState(() => _busy = false);
    M3ESnackbar.show(
      context,
      message: completed == LastFmAuthStage.connected
          ? l10n.listeningSyncConnected
          : l10n.listeningSyncLastFmFailed,
    );
  }

  Future<bool> _ensureConsent(
    ScrobbleService service,
    ScrobbleTarget target,
  ) async {
    if (service.consentFor(target)) return true;
    final l10n = AppLocalizations.of(context)!;
    final name = _targetName(target);
    final agreed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.listeningSyncConsentTitle(name),
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.listeningSyncSent),
              const SizedBox(height: kSettingsSmallSpacing),
              Text(l10n.listeningSyncNotSent),
              const SizedBox(height: kSettingsSmallSpacing),
              Text(l10n.listeningSyncNetwork),
              const SizedBox(height: kSettingsElementSpacing),
              Text(l10n.listeningSyncConsentBody),
            ],
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
            child: Text(l10n.listeningSyncCancel),
          ),
          M3EButton.filled(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: Text(l10n.listeningSyncConsentAgree),
          ),
        ],
      ),
    );
    if (agreed != true) return false;
    await service.grantConsent(target);
    return true;
  }

  Future<String?> _askToken() {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final navigator = Navigator.of(context, rootNavigator: true);
    return M3EDialog.show<String>(
      context,
      dialog: M3EDialog(
        title: l10n.listeningSyncTokenTitle,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: M3ETextField(
            controller: controller,
            label: l10n.listeningSyncTokenLabel,
            placeholder: l10n.listeningSyncTokenHint,
            obscureText: true,
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.listeningSyncCancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(controller.text.trim()),
            child: Text(l10n.listeningSyncConnect),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<bool> _confirmLastFm() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: _targetName(ScrobbleTarget.lastFm),
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(l10n.listeningSyncLastFmWaiting),
        ),
        actions: [
          M3EButton.text(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
            child: Text(l10n.listeningSyncCancel),
          ),
          M3EButton.filled(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: Text(l10n.listeningSyncLastFmConfirm),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _disconnect(
    BuildContext context,
    AppLocalizations l10n,
    ScrobbleService service,
    ScrobbleTarget target,
  ) async {
    final name = _targetName(target);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.listeningSyncDisconnectTitle(name),
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(l10n.listeningSyncDisconnectBody),
        ),
        actions: [
          M3EButton.text(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
            child: Text(l10n.listeningSyncCancel),
          ),
          M3EButton.filled(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: Text(l10n.listeningSyncDisconnect),
          ),
        ],
      ),
    );
    if (confirmed == true) await service.disconnect(target);
  }
}
