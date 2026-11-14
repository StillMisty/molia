import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/any_listen.dart';
import '../l10n/app_localizations.dart';
import '../providers/sources_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/icon_swap.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// AppLocalizations 查找：测试/独立挂载场景未注册 delegate 时回退简体中文
/// （与音源管理页同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// any-listen 接入配置页：服务器地址 / 令牌 / 启用开关 / 连接测试 / 保存。
///
/// 与设置页共用同一套 M3E 语言（`SettingsSectionCard` + `CardListSurface` 行、
/// `M3ETypeScale` 排版）；分层：只依赖 [SourcesProvider] 与 domain 模型，
/// 不直接 import `lib/sources/**`（R5）。保存/连接测试/配置刷新全部走 provider：
/// - 传入 [provider] 时直接使用（集成测试 / 独立打开场景）；
/// - 不传时从 `context.read<SourcesProvider>()` 获取（正式 App 由
///   composition root 注册）。
class AnyListenPage extends StatefulWidget {
  const AnyListenPage({super.key, this.provider});

  /// 可选：音源管理 provider。为空时从 context 读取。
  final SourcesProvider? provider;

  @override
  State<AnyListenPage> createState() => _AnyListenPageState();
}

class _AnyListenPageState extends State<AnyListenPage> {
  /// 文本输入落盘防抖：逐字写会反复重载音源，停顿后再保存。
  static const Duration _saveDelay = Duration(milliseconds: 400);

  final _serverUrlController = TextEditingController();
  final _tokenController = TextEditingController();

  late final SourcesProvider _provider;
  Timer? _saveTimer;
  bool _pendingSave = false;
  bool _enabled = false;
  bool _loading = true;
  bool _testing = false;
  bool _tokenVisible = false;
  String? _serverUrlError;
  String? _testMessage;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    _provider = widget.provider ?? context.read<SourcesProvider>();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // 防抖窗口内退出页面：补写一次，避免最后一段输入丢失。dispose 里不再
    // 查 l10n（祖先查找在卸载阶段不安全），只做纯领域校验。
    if (_pendingSave) {
      final raw = _serverUrlController.text.trim();
      final valid = raw.isEmpty
          ? !_enabled
          : AnyListenConfig.validateServerUrl(raw) == null;
      if (valid) {
        unawaited(_provider.saveAnyListenConfig(_formConfig()));
      }
    }
    _serverUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 刷新走 provider：独立打开（manager 未 init）时也从本地读回配置。
    await _provider.reloadAnyListenConfig();
    final config = _provider.anyListenConfig;
    if (!mounted) return;
    setState(() {
      _serverUrlController.text = config.serverUrl;
      _tokenController.text = config.token;
      _enabled = config.enabled;
      _loading = false;
    });
  }

  AnyListenConfig _formConfig() => AnyListenConfig(
    serverUrl: AnyListenConfig.normalizeServerUrl(_serverUrlController.text),
    token: _tokenController.text.trim(),
    enabled: _enabled,
  );

  /// 地址校验：未启用时允许留空（用于清除配置）。
  String? _validateAddress(AppLocalizations l10n) {
    final raw = _serverUrlController.text.trim();
    if (raw.isEmpty) {
      return _enabled ? l10n.anyListenServerUrlRequiredToEnable : null;
    }
    return AnyListenConfig.validateServerUrl(raw);
  }

  /// 文本变化：清掉旧错误并安排一次落盘。
  void _onFieldChanged() {
    if (_serverUrlError != null) {
      setState(() => _serverUrlError = null);
    }
    _scheduleSave();
  }

  void _scheduleSave() {
    _pendingSave = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(_persist()));
  }

  /// 即时写入当前表单；地址不合法时只显示行内错误，不落盘。
  Future<void> _persist() async {
    _saveTimer?.cancel();
    if (!_pendingSave) return;
    _pendingSave = false;
    final l10n = _l10n(context);
    final error = _validateAddress(l10n);
    if (error != null) {
      if (mounted) setState(() => _serverUrlError = error);
      return;
    }
    if (mounted) setState(() => _serverUrlError = null);
    final saved = await _provider.saveAnyListenConfig(_formConfig());
    if (!mounted) return;
    if (!saved) {
      M3ESnackbar.show(context, message: l10n.anyListenSaveFailed);
    }
  }

  /// 启用开关：先校验地址，再立即落盘（不等防抖）。
  Future<void> _setEnabled(bool value) async {
    if (value) {
      final error = _validateAddress(_l10n(context));
      if (error != null) {
        setState(() => _serverUrlError = error);
        return;
      }
    }
    setState(() => _enabled = value);
    _scheduleSave();
    await _persist();
  }

  Future<void> _test() async {
    final l10n = _l10n(context);
    final raw = _serverUrlController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _serverUrlError = l10n.anyListenServerUrlRequired;
        _testMessage = null;
      });
      return;
    }
    final error = AnyListenConfig.validateServerUrl(raw);
    if (error != null) {
      setState(() {
        _serverUrlError = error;
        _testMessage = null;
      });
      return;
    }

    setState(() {
      _serverUrlError = null;
      _testing = true;
      _testMessage = null;
    });
    // 用表单当前值探测，不要求先保存。
    final result = await _provider.testAnyListenConfig(_formConfig());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result.ok;
      _testMessage = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return SettingsSubPage.body(
      title: l10n.anyListenEntry,
      body: _loading
          ? const Center(child: M3ELoadingIndicator())
          : SettingsSubPageList(
              children: [
                SettingsSectionCard(children: [_introRow(context, l10n)]),
                const SizedBox(height: kSettingsSectionSpacing),
                SettingsSectionCard(
                  title: l10n.anyListenServerSection,
                  footer: SettingsSectionHint(text: l10n.settingsAutoSaveHint),
                  children: [
                    _fieldRow(
                      context,
                      icon: Icons.dns_rounded,
                      label: l10n.anyListenServerUrl,
                      child: M3ETextField(
                        controller: _serverUrlController,
                        keyboardType: TextInputType.url,
                        variant: M3ETextFieldVariant.outlined,
                        placeholder: l10n.anyListenServerUrlHint,
                        errorText: _serverUrlError,
                        leading: const Icon(Icons.dns_rounded),
                        onChanged: (_) => _onFieldChanged(),
                      ),
                    ),
                    _fieldRow(
                      context,
                      icon: Icons.key_rounded,
                      label: l10n.anyListenToken,
                      child: M3ETextField(
                        controller: _tokenController,
                        obscureText: !_tokenVisible,
                        onChanged: (_) => _onFieldChanged(),
                        variant: M3ETextFieldVariant.outlined,
                        placeholder: l10n.anyListenTokenPlaceholder,
                        leading: const Icon(Icons.key_rounded),
                        trailing: M3EIconButton(
                          variant: M3EIconButtonVariant.standard,
                          semanticLabel: _tokenVisible
                              ? l10n.anyListenTokenHide
                              : l10n.anyListenTokenShow,
                          icon: IconSwap<bool>(
                            value: _tokenVisible,
                            builder: (context, visible) => Icon(
                              visible
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                            ),
                          ),
                          onPressed: () =>
                              setState(() => _tokenVisible = !_tokenVisible),
                        ),
                      ),
                    ),
                    SettingsSwitchTile(
                      switchKey: const Key('anyListenEnableSwitch'),
                      icon: Icons.cloud_rounded,
                      title: l10n.anyListenEnable,
                      subtitle: l10n.anyListenEnableSubtitle,
                      value: _enabled,
                      onChanged: (value) => unawaited(_setEnabled(value)),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(
                        top: kSettingsSmallSpacing,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: M3EButton.tonal(
                          key: const Key('anyListenTestButton'),
                          enabled: !_testing,
                          onPressed: _test,
                          icon: _testing
                              ? const _ButtonSpinner()
                              : const Icon(Icons.network_check_rounded),
                          label: Text(l10n.anyListenTest),
                        ),
                      ),
                    ),
                    if (_testMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: kSettingsSmallSpacing,
                        ),
                        child: _testResultRow(context, _testMessage!),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  /// 说明行：品牌图标底 + 段落（骨架实现的边界说明；标题不重复顶栏文案）。
  Widget _introRow(BuildContext context, AppLocalizations l10n) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      onPressed: null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsTileIcon(icon: Icons.info_outline_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.anyListenIntroBody,
                  style: m3e.typeScale.bodyMedium.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.anyListenIntroHint,
                  style: m3e.typeScale.bodySmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 输入行：图标 + 行标题 + 输入框（设置行形状，与其它行同源）。
  Widget _fieldRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      onPressed: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsTileLead(icon: icon, title: label),
          const SizedBox(height: kSettingsSmallSpacing),
          child,
        ],
      ),
    );
  }

  /// 连接测试结果：成功/失败成对语义色 + 一句话。
  Widget _testResultRow(BuildContext context, String message) {
    final m3e = M3ETheme.of(context);
    final semantic = AppSemanticColors.of(context);
    final color = _testOk ? semantic.success : m3e.colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          _testOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
          size: 18,
          color: color,
        ),
        const SizedBox(width: kSettingsSmallSpacing),
        Expanded(
          child: Text(
            message,
            style: m3e.typeScale.bodySmall.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// 按钮内联进度（保存 / 连接测试的进行态）。
class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: M3EProgressIndicator.circular(size: 16, strokeWidth: 2),
    );
  }
}
