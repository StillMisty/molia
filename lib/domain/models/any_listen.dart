/// any-listen 接入的纯领域模型：配置数据 + 校验 + 连接测试结果 + 错误分类。
///
/// 从 `lib/sources/any_listen/**` 迁出（Wave 7 分层收口）：UI 与 provider
/// 只依赖本文件，`AnyListenConfigStore`（shared_preferences 持久化）仍留在
/// sources 层并 `export` 本文件，保证既有 import 兼容。
library;

/// any-listen 接入配置。
///
/// 持久化键统一使用 `any_listen_` 前缀（由 sources 层的
/// `AnyListenConfigStore` 读写），与 LX 音源的 `lx_*` 键互不影响。
class AnyListenConfig {
  /// 服务器地址（已归一化：无尾部斜杠；缺省协议时补 `http://`）。
  final String serverUrl;

  /// 访问令牌；any-listen 官方握手会下发 token，这里预留保存。
  final String token;

  /// 用户开关。未启用时即使已配置也不参与搜索/播放。
  final bool enabled;

  static const prefsServerUrlKey = 'any_listen_server_url';
  static const prefsTokenKey = 'any_listen_token';
  static const prefsEnabledKey = 'any_listen_enabled';

  const AnyListenConfig({
    this.serverUrl = '',
    this.token = '',
    this.enabled = false,
  });

  static const AnyListenConfig empty = AnyListenConfig();

  /// 是否填写了服务器地址。
  bool get isConfigured => serverUrl.isNotEmpty;

  /// 是否可用：已配置且已启用。只有此时才出现在可搜索音源列表，并发起网络请求。
  bool get isUsable => isConfigured && enabled;

  AnyListenConfig copyWith({
    String? serverUrl,
    String? token,
    bool? enabled,
  }) {
    return AnyListenConfig(
      serverUrl: serverUrl == null
          ? this.serverUrl
          : AnyListenConfig.normalizeServerUrl(serverUrl),
      token: token ?? this.token,
      enabled: enabled ?? this.enabled,
    );
  }

  /// 归一化服务器地址：去首尾空白、去尾部 `/`；缺少协议时补 `http://`。
  static String normalizeServerUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (!value.contains('://')) {
      // 残缺协议（如 `http:`）：不补前缀，交给 validateServerUrl 报错。
      if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:$').hasMatch(value)) return value;
      value = value.replaceAll(RegExp(r'/+$'), '');
      return 'http://$value';
    }
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  /// 归一化后的副本：地址去尾斜杠、缺协议补 `http://`。供持久化与适配器使用。
  AnyListenConfig normalizedCopy() => AnyListenConfig(
        serverUrl: normalizeServerUrl(serverUrl),
        token: token,
        enabled: enabled,
      );

  /// 校验服务器地址，合法返回 null，否则返回可读错误文案。
  static String? validateServerUrl(String raw) {
    final value = normalizeServerUrl(raw);
    if (value.isEmpty) return '请填写服务器地址';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return '服务器地址格式不正确';
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '服务器地址必须以 http:// 或 https:// 开头';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is AnyListenConfig &&
      other.serverUrl == serverUrl &&
      other.token == token &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(serverUrl, token, enabled);

  @override
  String toString() =>
      'AnyListenConfig(serverUrl: $serverUrl, token: ${token.isEmpty ? '' : '***'}, enabled: $enabled)';
}

/// any-listen 错误分类。
enum AnyListenErrorKind {
  /// 未配置服务器地址，或已配置但未启用接入。
  notConfigured,

  /// 网络不可达、请求超时、服务器 5xx 等连接层失败（通常可重试）。
  connectionFailed,

  /// HTTP 状态异常（非鉴权类 4xx）或响应不是预期 JSON / 缺少必要字段。
  badResponse,

  /// 鉴权失败（HTTP 401/403），令牌缺失或过期。
  unauthorized,

  /// 服务器明确表示不支持该能力。
  unsupported,

  /// 未归类的错误。
  unknown,
}

/// 连接测试结果（不抛异常，页面可直接展示）。
class AnyListenTestResult {
  final bool ok;

  /// 可读结果/错误描述。
  final String message;

  /// 失败时的错误分类。
  final AnyListenErrorKind? errorKind;

  /// 探测成功时的服务器标识（可能为空）。
  final String? serverId;

  const AnyListenTestResult({
    required this.ok,
    required this.message,
    this.errorKind,
    this.serverId,
  });
}
