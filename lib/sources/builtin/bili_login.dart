/// B 站扫码登录：生成二维码、轮询状态、从 Set-Cookie / crossDomain ticket
/// 提取账号 Cookie，以及登录后的账号资料读取。
///
/// 登录成功格式有两代：
/// - 旧：`data.url` 的 query 里直接带 `SESSDATA` 等 Cookie；
/// - 新（2026-08 起）：`data.url` 是 crossDomain ticket，真实 Cookie 在
///   `Set-Cookie` 响应头（poll 本身或跟跳后的 302）。两种都要兼容。
///
/// **安全**：二维码 URL、qrcode_key、Cookie 都不写日志。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../data/http/app_dio.dart';
import '../../domain/models/bili_account.dart';
import '../../domain/models/failure.dart';
import 'bili_api.dart';
import 'bili_client.dart';

/// 一次二维码生成结果（key 只留在账号服务内）。
class BiliQrCode {
  const BiliQrCode({required this.url, required this.key});

  final String url;
  final String key;
}

/// 扫码成功后从响应里还原出的账号凭据。
class BiliLoginCredentials {
  const BiliLoginCredentials({
    required this.cookieHeader,
    required this.userId,
  });

  final String cookieHeader;
  final String userId;
}

/// 单次 poll 的原始结果；由账号服务转换成领域层 `BiliQrPollResult`。
class BiliQrPollOutcome {
  const BiliQrPollOutcome({
    required this.status,
    this.credentials,
    this.retryable = false,
  });

  final BiliQrPollStatus status;
  final BiliLoginCredentials? credentials;
  final bool retryable;
}

class BiliQrLogin {
  BiliQrLogin({BiliClient? client}) : _client = client ?? BiliClient.shared;

  final BiliClient _client;
  final Logger _logger = Logger('molia.bili_login');

  /// 需要从登录响应中保留的 Cookie（其余属性全部丢弃）。
  static const List<String> _cookieNames = [
    'SESSDATA',
    'bili_jct',
    'DedeUserID',
    'DedeUserID__ckMd5',
    'sid',
  ];

  Future<BiliQrCode> generate() async {
    final response = await _client.get(
      '${BiliApi.passportBaseUrl}/x/passport-login/web/qrcode/generate',
      codePolicy: BiliCodePolicy.standard,
    );
    final data = response is Map ? response['data'] : null;
    final url = data is Map ? data['url']?.toString().trim() ?? '' : '';
    final key = data is Map ? data['qrcode_key']?.toString().trim() ?? '' : '';
    if (url.isEmpty || key.isEmpty) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: 'bili: 扫码登录二维码生成失败',
        retryable: true,
      );
    }
    return BiliQrCode(url: url, key: key);
  }

  Future<BiliQrPollOutcome> poll(String key) async {
    final uri = Uri.parse(
      '${BiliApi.passportBaseUrl}/x/passport-login/web/qrcode/poll',
    ).replace(queryParameters: {'qrcode_key': key});
    final response = await _client.transport.getResponse(
      uri.toString(),
      headers: BiliApi.anonymousHeaders,
      retries: 1,
    );
    final decoded = _decode(response);
    final code = _codeOf(decoded);
    if (code != 0) {
      throw SourceFailure(
        kind: FailureKind.unknown,
        message: 'bili: 扫码登录请求失败（code=$code）',
        retryable: true,
      );
    }
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! Map) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: 'bili: 扫码登录响应缺少数据',
        retryable: true,
      );
    }
    final state = _intOf(data['code']);
    switch (state) {
      case 0:
        final cookies = await _cookiesOf(response, data);
        final cookieHeader = _cookieHeaderOf(cookies);
        if (cookieHeader == null) {
          return const BiliQrPollOutcome(status: BiliQrPollStatus.failed);
        }
        return BiliQrPollOutcome(
          status: BiliQrPollStatus.confirmed,
          credentials: BiliLoginCredentials(
            cookieHeader: cookieHeader,
            userId: cookies['DedeUserID'] ?? '',
          ),
        );
      case 86101:
        return const BiliQrPollOutcome(status: BiliQrPollStatus.waiting);
      case 86090:
        return const BiliQrPollOutcome(status: BiliQrPollStatus.scanned);
      case 86038:
        return const BiliQrPollOutcome(status: BiliQrPollStatus.expired);
      default:
        return const BiliQrPollOutcome(status: BiliQrPollStatus.failed);
    }
  }

  /// 用当前账号 Cookie 读 nav 资料；null = 登录已失效。
  Future<BiliAccount?> fetchProfile() async {
    final response = await _client.get(
      '/x/web-interface/nav',
      auth: BiliAuth.account,
      codePolicy: BiliCodePolicy.none,
    );
    if (response is! Map) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: 'bili: 账号资料响应无效',
        retryable: true,
      );
    }
    final code = _codeOf(response);
    if (code == -101) return null;
    if (code != 0) {
      throw SourceFailure(
        kind: FailureKind.unknown,
        message: 'bili: 账号资料请求失败（code=$code）',
        retryable: true,
      );
    }
    final data = response['data'];
    if (data is! Map || data['isLogin'] != true) return null;
    final userId = data['mid']?.toString().trim() ?? '';
    final userName = data['uname']?.toString().trim() ?? '';
    return BiliAccount(
      userId: userId,
      userName: userName.isEmpty ? null : userName,
    );
  }

  dynamic _decode(Response<dynamic> response) {
    try {
      final text = bodyText(response);
      if (text.trim().isEmpty) throw const FormatException('empty body');
      return jsonDecode(text);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: 'bili: 扫码登录响应不是 JSON',
        retryable: true,
      );
    }
  }

  /// 合并 poll 响应头、data.url（旧格式）与 crossDomain ticket（新格式）的
  /// Cookie；Set-Cookie 优先，URL 只补缺。
  Future<Map<String, String>> _cookiesOf(
    Response<dynamic> response,
    Map data,
  ) async {
    final headers = response.headers.map['set-cookie'] ?? const <String>[];
    final cookies = <String, String>{};
    for (final name in _cookieNames) {
      final value = _cookieValueFromSetCookie(headers, name);
      if (value != null) cookies[name] = value;
    }
    final url = data['url']?.toString().trim() ?? '';
    if (cookies['SESSDATA'] == null && url.isNotEmpty) {
      cookies.addAll(_cookiesFromUrl(url));
    }
    if (cookies['SESSDATA'] == null && url.isNotEmpty) {
      try {
        cookies.addAll(await _cookiesFromTicket(url));
      } catch (e) {
        _logger.warning('B 站登录 ticket 跟跳失败: ${e.runtimeType}');
      }
    }
    return cookies;
  }

  /// 手动跟跳 crossDomain ticket，逐跳采集 Set-Cookie（最多 5 跳）。
  Future<Map<String, String>> _cookiesFromTicket(String url) async {
    final cookies = <String, String>{};
    final parsed = Uri.tryParse(url);
    if (parsed == null) return cookies;
    var current = parsed;
    for (var hop = 0; hop < 5; hop++) {
      final response = await _client.transport.getResponse(
        current.toString(),
        headers: BiliApi.anonymousHeaders,
        retries: 1,
        followRedirects: false,
      );
      final headers = response.headers.map['set-cookie'] ?? const <String>[];
      for (final name in _cookieNames) {
        final value = _cookieValueFromSetCookie(headers, name);
        if (value != null) cookies[name] = value;
      }
      if ((cookies['SESSDATA'] ?? '').isNotEmpty) break;
      final status = response.statusCode ?? 0;
      final location = response.headers.value('location');
      if (status < 300 ||
          status >= 400 ||
          location == null ||
          location.isEmpty) {
        break;
      }
      current = current.resolve(location);
    }
    return cookies;
  }

  static String? _cookieHeaderOf(Map<String, String> cookies) {
    if ((cookies['SESSDATA'] ?? '').isEmpty) return null;
    final parts = <String>[
      for (final name in _cookieNames)
        if ((cookies[name] ?? '').isNotEmpty) '$name=${cookies[name]}',
    ];
    return parts.isEmpty ? null : parts.join('; ');
  }

  static String? _cookieValueFromSetCookie(List<String> headers, String name) {
    final pattern = RegExp('(?:^|[;,]\\s*)${RegExp.escape(name)}=([^;]+)');
    for (final header in headers) {
      final match = pattern.firstMatch(header);
      if (match == null) continue;
      var value = match.group(1)!.trim();
      // 少数平台把多个 Set-Cookie 合并进一条头，截掉下一个 cookie 的起始。
      final merged = value.indexOf(RegExp(r',\s*[^;,]+='));
      if (merged >= 0) value = value.substring(0, merged).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  /// 旧格式：直接解析 data.url 的原始 query，保留 `%2C` 等编码。
  static Map<String, String> _cookiesFromUrl(String url) {
    final result = <String, String>{};
    final uri = Uri.tryParse(url);
    final query = uri?.query ?? '';
    if (query.isEmpty) return result;
    for (final part in query.split('&')) {
      final equals = part.indexOf('=');
      if (equals <= 0) continue;
      final name = Uri.decodeComponent(part.substring(0, equals));
      if (!_cookieNames.contains(name)) continue;
      final value = part.substring(equals + 1).trim();
      if (value.isNotEmpty) result[name] = value;
    }
    return result;
  }

  static int? _codeOf(dynamic response) {
    if (response is! Map) return null;
    return _intOf(response['code']);
  }

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }
}
