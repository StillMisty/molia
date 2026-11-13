/// 诊断导出 / 日志落盘的脱敏规则（纯 Dart，无 I/O、无 Flutter）。
///
/// 只替换值、不删除上下文：URL 的协议 / 主机 / 路径 / 参数名、日志行的
/// 前缀都保留，支持人员仍能判断“哪个字段出现过、请求的是哪个地址”。标记
/// 固定为 [redactionMarker]，不泄露原值的长度或前后缀；同一输入重复调用
/// 结果不变（幂等），因此落盘与导出各跑一次不会产生叠加替换。
///
/// 不用嵌套量词或回溯型表达式：所有规则都是线性扫描的简单分组，超长行与
/// 畸形 JSON / URL 最多是不匹配，不会抛异常或卡住。调用方仍需限制单次输入
/// 长度（日志 sink 与诊断包各自有行 / 段上限）。
library;

/// 固定替换标记（不保留原值长度、前缀或后缀）。
const String redactionMarker = '[redacted]';

const Set<String> _sensitiveHeaderNames = {
  'cookie',
  'set-cookie',
  'authorization',
  'proxy-authorization',
  'x-api-key',
  'api-key',
  'x-auth-token',
  'x-access-token',
  'x-csrf-token',
};

const Set<String> _sensitiveExactQueryNames = {
  'key',
  'sig',
  'sign',
  'code',
  'auth',
  'token',
  'ticket',
  'password',
  'passphrase',
  'secret',
  'wrid',
};

const List<String> _sensitiveQuerySuffixes = [
  'token',
  'apikey',
  'secret',
  'signature',
  'ticket',
  'passphrase',
  'password',
  'credential',
  'authcode',
  'authorizationcode',
];

/// 请求 / 响应头脱敏：敏感头的值整体替换，其余值仍走 [redactSecrets]
/// （头里可能嵌 URL）。返回新 Map，不修改调用方的对象。
Map<String, String> redactHeaders(Map<String, String> headers) {
  return {
    for (final entry in headers.entries)
      entry.key: _sensitiveHeaderNames.contains(entry.key.toLowerCase())
          ? redactionMarker
          : redactSecrets(entry.value),
  };
}

/// 对任意文本执行全部脱敏规则。
String redactSecrets(String input) {
  if (input.isEmpty) return input;
  var text = input;
  text = _redactHeaderLines(text);
  text = _redactAuthorizationSchemes(text);
  text = _redactUrlUserInfo(text);
  text = _redactSensitiveQueryParameters(text);
  text = _redactStructuredFields(text);
  text = _redactKnownCookieNames(text);
  text = _redactKnownApiKeys(text);
  return text;
}

/// 把日志 / 导出文本里的本机用户目录替换为 `~`，去掉用户名。
///
/// 这是导出层的隐私措施，不替代密钥脱敏；日志文件本身保留路径以便排障。
String normalizePersonalPaths(
  String input, {
  Iterable<String> homeDirectories = const [],
}) {
  if (input.isEmpty) return input;
  final paths =
      homeDirectories
          .map((path) => path.trim())
          .where((path) => path.isNotEmpty)
          .toSet()
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  var text = input;
  for (final path in paths) {
    text = text.replaceAll(path, '~');
  }
  return text;
}

/// 宽松匹配头行：`Cookie:` / `Authorization :` / JSON 里的 `"cookie":`。
final RegExp _headerLinePattern = RegExp(
  r'\b(cookie|set-cookie|authorization|proxy-authorization|x-api-key|api-key|x-auth-token|x-access-token|x-csrf-token)\b'
  r'(\s*:\s*)([^\r\n]*)',
  caseSensitive: false,
);

String _redactHeaderLines(String text) => text.replaceAllMapped(
  _headerLinePattern,
  (match) => '${match.group(1)}${match.group(2)}$redactionMarker',
);

/// `Authorization: Bearer …` / `Basic …`，以及正文里单独出现的方案值。
final RegExp _authorizationSchemePattern = RegExp(
  r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}',
  caseSensitive: false,
);

String _redactAuthorizationSchemes(String text) => text.replaceAllMapped(
  _authorizationSchemePattern,
  (match) => '${match.group(1)} $redactionMarker',
);

/// `scheme://user:password@host`（用户名 + 密码或仅用户名）整体替换。
final RegExp _urlUserInfoPattern = RegExp(
  r'([a-zA-Z][a-zA-Z0-9+.-]{0,15}://)([^/\s@?#]+)@',
);

String _redactUrlUserInfo(String text) => text.replaceAllMapped(
  _urlUserInfoPattern,
  (match) => '${match.group(1)}$redactionMarker@',
);

/// URL 查询参数：`?token=…` / `&w_rid=…`；参数名和其余参数保持可读。
final RegExp _queryPairPattern = RegExp(r'([?&])([^=&\s#]+)=([^&#\s]*)');

String _redactSensitiveQueryParameters(String text) =>
    text.replaceAllMapped(_queryPairPattern, (match) {
      final rawName = match.group(2)!;
      final name = _queryName(rawName);
      if (!_looksSensitiveQueryName(name)) return match.group(0)!;
      return '${match.group(1)}$rawName=$redactionMarker';
    });

String _queryName(String raw) {
  var value = raw;
  try {
    value = Uri.decodeQueryComponent(raw);
  } catch (_) {
    // 畸形百分号编码：按原文判断仍然安全。
  }
  return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

bool _looksSensitiveQueryName(String normalized) {
  if (normalized.isEmpty) return false;
  if (_sensitiveExactQueryNames.contains(normalized)) return true;
  for (final suffix in _sensitiveQuerySuffixes) {
    if (normalized.endsWith(suffix)) return true;
  }
  return false;
}

/// 结构化字段：`password=…` / `"access_token": "…"` / `api key: …`。
///
/// 刻意不匹配裸 `key`：正文里的“这首歌的 key”不是密钥；只匹配
/// `api_key` / `apiKey` / `x-api-key` 等明确形状。
final RegExp _structuredFieldPattern = RegExp(
  r'''(["']?\b(?:password|passphrase|access[_\s-]?token|refresh[_\s-]?token|id[_\s-]?token|token|api[_\s-]?key|apikey|x[_\s-]?api[_\s-]?key|client[_\s-]?secret|authorization|cookie|session[_\s-]?cookie|ticket|signature|sign)\b["']?\s*[:=]\s*)'''
  r'''(?!\[redacted\])(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&}\]\r\n]+)''',
  caseSensitive: false,
);

String _redactStructuredFields(String text) => text.replaceAllMapped(
  _structuredFieldPattern,
  (match) => '${match.group(1)}$redactionMarker',
);

/// 无 `Cookie:` 头时仍可能出现在正文 / 参数里的平台登录 Cookie 名。
final RegExp _knownCookiePattern = RegExp(
  r'\b(DedeUserID__ckMd5|DedeUserID|SESSDATA|bili_jct|MUSIC_U|__csrf|NMTID|qm_keyst|qqmusic_key|psrf_qqopenid|psrf_qqunionid|kw_token)\b'
  r'(\s*[=:]\s*)(?!\[redacted\])([^\s,;&}\]]+)',
  caseSensitive: false,
);

String _redactKnownCookieNames(String text) => text.replaceAllMapped(
  _knownCookiePattern,
  (match) => '${match.group(1)}${match.group(2)}$redactionMarker',
);

/// OpenAI 风格的 `sk-…` 密钥（保守长度阈值，避免误伤普通短词）。
final RegExp _apiKeyPrefixPattern = RegExp(r'\bsk-[A-Za-z0-9_-]{20,}\b');

String _redactKnownApiKeys(String text) =>
    text.replaceAll(_apiKeyPrefixPattern, redactionMarker);
