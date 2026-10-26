import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../domain/models/bili_account.dart';
import '../l10n/app_localizations.dart';
import '../services/bili_account_service.dart';
import '../theme/app_theme.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// AppLocalizations 查找：独立挂载 / 测试场景回退简体中文。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 哔哩哔哩账号：扫码登录 / 登录态 / 退出。
///
/// 只服务 B 站字幕歌词：登录后的 Cookie 只在字幕与账号资料请求里使用；
/// 播放、搜索、评论和字幕 CDN 继续匿名（见 ADR-0016）。
class BiliAccountPage extends StatefulWidget {
  const BiliAccountPage({super.key});

  @override
  State<BiliAccountPage> createState() => _BiliAccountPageState();
}

class _BiliAccountPageState extends State<BiliAccountPage>
    with WidgetsBindingObserver {
  late final BiliAccountService _service;
  Timer? _pollTimer;
  BiliQrLoginSession? _session;
  BiliQrPollStatus _qrStatus = BiliQrPollStatus.waiting;
  bool _starting = false;
  bool _polling = false;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service = context.read<BiliAccountService>();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _service.init();
    if (!mounted) return;
    if (_service.status == BiliAccountStatus.loggedIn) {
      unawaited(_service.refreshProfile());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    _service.cancelQrLogin();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _session != null && !_polling) {
      unawaited(_poll());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return SettingsSubPage.body(
      title: l10n.biliAccountTitle,
      body: Consumer<BiliAccountService>(
        builder: (context, service, _) {
          if (service.status == BiliAccountStatus.unknown) {
            return const Center(child: M3ELoadingIndicator());
          }
          return SettingsSubPageList(
            children: [
              if (service.status == BiliAccountStatus.loggedIn)
                ..._buildLoggedIn(context, l10n, service)
              else
                ..._buildLoggedOut(context, l10n, service),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildLoggedIn(
    BuildContext context,
    AppLocalizations l10n,
    BiliAccountService service,
  ) {
    final name = service.account?.userName;
    return [
      SettingsSectionCard(
        title: l10n.biliAccountStatusSection,
        children: [
          SettingsInfoTile(
            icon: Icons.account_circle_rounded,
            title: name == null
                ? l10n.biliAccountLoggedIn
                : l10n.biliAccountLoggedInAs(name),
            subtitle: l10n.biliAccountTitle,
          ),
        ],
      ),
      if (!service.lastLoginPersisted) ...[
        const SizedBox(height: kSettingsSmallSpacing),
        SettingsSectionHint(text: l10n.biliAccountLoginPersistFailed),
      ],
      const SizedBox(height: kSettingsSectionSpacing),
      SettingsSectionCard(
        children: [
          SettingsNavTile(
            key: const Key('biliAccountLogoutItem'),
            icon: Icons.logout_rounded,
            title: l10n.biliAccountLogoutAction,
            subtitle: '',
            onTap: _loggingOut ? null : () => unawaited(_confirmLogout(l10n)),
          ),
        ],
      ),
      const SizedBox(height: kSettingsSectionSpacing),
      SettingsSectionHint(text: l10n.biliAccountPrivacyHint),
    ];
  }

  List<Widget> _buildLoggedOut(
    BuildContext context,
    AppLocalizations l10n,
    BiliAccountService service,
  ) {
    return [
      SettingsSectionCard(
        title: l10n.biliAccountStatusSection,
        children: [
          SettingsInfoTile(
            icon: Icons.account_circle_rounded,
            title: l10n.biliAccountLoggedOut,
            subtitle: l10n.biliAccountTitle,
          ),
        ],
      ),
      if (service.sessionExpired) ...[
        const SizedBox(height: kSettingsSmallSpacing),
        SettingsSectionHint(text: l10n.biliAccountSessionExpired),
      ],
      const SizedBox(height: kSettingsSectionSpacing),
      SettingsSectionCard(
        children: [
          CardListSurface(
            position: SettingsRowPosition.of(context),
            padding: kSettingsRowPadding,
            onPressed: null,
            child: Text(
              l10n.biliAccountLoginIntro,
              style: M3ETheme.of(context).typeScale.bodyMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: kSettingsSectionSpacing),
      if (_session == null)
        SettingsSectionCard(
          children: [
            CardListSurface(
              position: SettingsRowPosition.of(context),
              padding: kSettingsRowPadding,
              onPressed: null,
              child: Center(
                child: M3EButton.filled(
                  key: const Key('biliAccountLoginButton'),
                  onPressed: _starting ? null : () => unawaited(_startLogin()),
                  icon: const Icon(Icons.qr_code_rounded),
                  label: Text(l10n.biliAccountLoginAction),
                ),
              ),
            ),
          ],
        )
      else
        SettingsSectionCard(
          title: l10n.biliAccountLoginAction,
          children: [
            CardListSurface(
              position: SettingsRowPosition.of(context),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              onPressed: null,
              child: _qrView(context, l10n),
            ),
          ],
        ),
      if (_session == null && _qrStatus == BiliQrPollStatus.failed) ...[
        const SizedBox(height: kSettingsSmallSpacing),
        SettingsSectionHint(text: l10n.biliAccountQrFailed),
      ],
      const SizedBox(height: kSettingsSectionSpacing),
      SettingsSectionHint(text: l10n.biliAccountPrivacyHint),
    ];
  }

  Widget _qrView(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final typeScale = M3ETheme.of(context).typeScale;
    final showQr =
        _qrStatus == BiliQrPollStatus.waiting ||
        _qrStatus == BiliQrPollStatus.scanned;
    final statusText = switch (_qrStatus) {
      BiliQrPollStatus.waiting => l10n.biliAccountQrHint,
      BiliQrPollStatus.scanned => l10n.biliAccountQrScanned,
      BiliQrPollStatus.expired => l10n.biliAccountQrExpired,
      BiliQrPollStatus.failed => l10n.biliAccountQrFailed,
      BiliQrPollStatus.confirmed => l10n.biliAccountLoginSuccess,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showQr)
          Container(
            color: kQrBackgroundColor,
            padding: const EdgeInsets.all(12),
            child: QrImageView(
              key: const Key('biliAccountQrImage'),
              data: _session!.url,
              size: 220,
              backgroundColor: kQrBackgroundColor,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: kQrModuleColor,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: kQrModuleColor,
              ),
              semanticsLabel: l10n.biliAccountQrSemantics,
            ),
          ),
        const SizedBox(height: 12),
        Text(
          statusText,
          textAlign: TextAlign.center,
          style: typeScale.bodyMedium.copyWith(
            color: showQr ? scheme.onSurface : scheme.error,
          ),
        ),
        if (!showQr) ...[
          const SizedBox(height: 12),
          M3EButton.tonal(
            key: const Key('biliAccountQrRefreshButton'),
            onPressed: _starting ? null : () => unawaited(_startLogin()),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(l10n.biliAccountQrRefresh),
          ),
        ],
      ],
    );
  }

  Future<void> _startLogin() async {
    setState(() {
      _starting = true;
      _session = null;
      _qrStatus = BiliQrPollStatus.waiting;
    });
    _stopPolling();
    try {
      final session = await _service.startQrLogin();
      if (!mounted) {
        _service.cancelQrLogin();
        return;
      }
      setState(() {
        _session = session;
        _starting = false;
      });
      _startPolling();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _qrStatus = BiliQrPollStatus.failed;
      });
    }
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_poll()),
    );
    unawaited(_poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    if (_polling || !mounted || _session == null) return;
    _polling = true;
    try {
      final result = await _service.pollQrLogin();
      if (!mounted) return;
      switch (result.status) {
        case BiliQrPollStatus.confirmed:
          _stopPolling();
          setState(() {
            _session = null;
            _qrStatus = BiliQrPollStatus.confirmed;
          });
          M3ESnackbar.show(
            context,
            message: _l10n(context).biliAccountLoginSuccess,
          );
        case BiliQrPollStatus.expired:
        case BiliQrPollStatus.failed:
          _stopPolling();
          setState(() => _qrStatus = result.status);
        case BiliQrPollStatus.waiting:
        case BiliQrPollStatus.scanned:
          setState(() => _qrStatus = result.status);
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _confirmLogout(AppLocalizations l10n) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.biliAccountLogoutAction,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(l10n.biliAccountLogoutConfirm),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
            child: Text(l10n.biliAccountLogoutAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _loggingOut = true);
    try {
      await _service.logout();
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.biliAccountLoggedOut);
    } catch (_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.biliAccountLogoutFailed);
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }
}
