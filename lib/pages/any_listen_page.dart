import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/any_listen.dart';
import '../providers/sources_provider.dart';
import '../theme/app_semantic_colors.dart';

/// any-listen 接入配置页：服务器地址 / 令牌 / 启用开关 / 连接测试 / 保存。
///
/// 分层（Wave 7）：只依赖 [SourcesProvider] 与 domain 模型，不直接
/// import `lib/sources/**`（R5）。保存/连接测试/配置刷新全部走 provider：
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
  final _serverUrlController = TextEditingController();
  final _tokenController = TextEditingController();

  bool _enabled = false;
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _tokenVisible = false;
  String? _serverUrlError;
  String? _testMessage;
  bool _testOk = false;

  SourcesProvider get _provider =>
      widget.provider ?? context.read<SourcesProvider>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
        serverUrl:
            AnyListenConfig.normalizeServerUrl(_serverUrlController.text),
        token: _tokenController.text.trim(),
        enabled: _enabled,
      );

  /// 地址校验：未启用时允许留空（用于清除配置）。
  String? _validateAddress() {
    final raw = _serverUrlController.text.trim();
    if (raw.isEmpty) return _enabled ? '启用前请填写服务器地址' : null;
    return AnyListenConfig.validateServerUrl(raw);
  }

  Future<void> _save() async {
    final error = _validateAddress();
    if (error != null) {
      setState(() => _serverUrlError = error);
      return;
    }
    setState(() {
      _serverUrlError = null;
      _saving = true;
    });

    final saved = await _provider.saveAnyListenConfig(_formConfig());

    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved) {
      M3ESnackbar.show(context, message: '保存失败：无法写入本地存储');
    }
  }

  Future<void> _test() async {
    final raw = _serverUrlController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _serverUrlError = '请先填写服务器地址';
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
    return Scaffold(
      appBar: M3EAppBar.top(
        title: const Text('any-listen 接入'),
        automaticallyImplyLeading: true,
      ),
      body: _loading
          ? const Center(child: M3ELoadingIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildIntroCard(context),
                const SizedBox(height: 16),
                _buildFormCard(context),
              ],
            ),
    );
  }

  Widget _buildIntroCard(BuildContext context) {
    final theme = Theme.of(context);
    return M3ECard(
      variant: M3ECardVariant.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('any-listen', style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'any-listen 是自托管的私有音乐播放服务。填写服务器地址并启用后，'
            '服务器提供的在线音源会出现在搜索页的音源列表中。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '当前为骨架实现：握手探测（/api/ipc/hello、/api/ipc/id）已对照官方源码，'
            '搜索/取链/歌词/封面接口尚未与真实服务器验证，可能暂不可用。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AppSemanticColors.of(context);
    return M3ECard(
      variant: M3ECardVariant.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('服务器配置', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          M3ETextField(
            controller: _serverUrlController,
            keyboardType: TextInputType.url,
            variant: M3ETextFieldVariant.outlined,
            label: '服务器地址',
            placeholder: 'http://192.168.1.10:9500',
            supportingText: 'Docker / 桌面端部署的 any-listen 服务地址',
            errorText: _serverUrlError,
            leading: const Icon(Icons.dns_rounded),
            onChanged: (_) {
              if (_serverUrlError != null) {
                setState(() => _serverUrlError = null);
              }
            },
          ),
          const SizedBox(height: 12),
          M3ETextField(
            controller: _tokenController,
            obscureText: !_tokenVisible,
            variant: M3ETextFieldVariant.outlined,
            label: '访问令牌（可选）',
            placeholder: '连接测试通过后可粘贴服务器下发的令牌',
            leading: const Icon(Icons.key_rounded),
            trailing: M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              tooltip: _tokenVisible ? '隐藏令牌' : '显示令牌',
              icon: Icon(
                _tokenVisible ? Icons.visibility_off_rounded : Icons.visibility_rounded,
              ),
              onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
            ),
          ),
          const SizedBox(height: 8),
          M3EListItem(
            headline: '启用 any-listen 音源',
            supportingText: '关闭后不会出现在搜索页，也不发起任何请求',
            trailing: M3ESwitch(
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            onTap: () => setState(() => _enabled = !_enabled),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              M3EButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: M3EProgressIndicator.circular(
                          size: 16,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.save_rounded),
                label: const Text('保存'),
              ),
              M3EButton.icon(
                style: M3EButtonStyle.outlined,
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: M3EProgressIndicator.circular(
                          size: 16,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.network_check_rounded),
                label: const Text('连接测试'),
              ),
            ],
          ),
          if (_testMessage != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _testOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                  size: 18,
                  color: _testOk ? semantic.success : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _testMessage!,
                    style: TextStyle(
                      color: _testOk ? semantic.success : theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
