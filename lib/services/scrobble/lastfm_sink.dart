/// Last.fm 协议适配器：签名 API + 浏览器授权后的会话密钥。
///
/// 密钥只出现在请求参数与签名里，不写日志；签名函数是纯函数，测试直接
/// 断言排序与摘要结果。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../data/http/app_dio.dart';
import '../../domain/models/scrobble.dart';
import '../../domain/ports/scrobble_sink.dart';
import 'scrobble_http.dart';

/// Last.fm 应用凭证（桌面 scrobbler 的常规做法：内置于构建）。
///
/// 无法把共享密钥做成真正秘密；保护模型是「每用户会话密钥 + TLS」。
/// 未配置时连接入口会明确说明，而不是发一半请求。
class LastFmApiConfig {
  const LastFmApiConfig({required this.apiKey, required this.apiSecret});

  /// 构建期注入：`--dart-define=MOLIA_LASTFM_API_KEY=...`。
  static const String fromEnvironment = String.fromEnvironment(
    'MOLIA_LASTFM_API_KEY',
  );
  static const String secretFromEnvironment = String.fromEnvironment(
    'MOLIA_LASTFM_API_SECRET',
  );

  /// 未注入时的默认值（连接入口禁用，不假装可用）。
  static const LastFmApiConfig none = LastFmApiConfig(
    apiKey: '',
    apiSecret: '',
  );

  static const LastFmApiConfig embedded = LastFmApiConfig(
    apiKey: fromEnvironment,
    apiSecret: secretFromEnvironment,
  );

  final String apiKey;
  final String apiSecret;

  bool get isConfigured => apiKey.isNotEmpty && apiSecret.isNotEmpty;
}

/// Last.fm API 签名：参数按键排序，拼成 `k+v`，末尾追加共享密钥，取 MD5。
///
/// [params] 不需要预排序，也不应包含 `api_sig` / `format` / `callback`。
String lastFmSignature(
  Map<String, String> params, {
  required String apiSecret,
}) {
  final keys = params.keys.where((key) => key != 'api_sig').toList()..sort();
  final buffer = StringBuffer();
  for (final key in keys) {
    buffer
      ..write(key)
      ..write(params[key]);
  }
  buffer.write(apiSecret);
  return md5.convert(utf8.encode(buffer.toString())).toString();
}

/// 带签名的请求参数：补 api_key / api_sig（format 固定 json，不参与签名）。
Map<String, String> lastFmSignedParams(
  Map<String, String> params, {
  required LastFmApiConfig config,
}) {
  final unsigned = <String, String>{...params, 'api_key': config.apiKey}
    ..remove('api_sig');
  return {
    ...unsigned,
    'api_sig': lastFmSignature(unsigned, apiSecret: config.apiSecret),
    'format': 'json',
  };
}

class LastFmSink implements ScrobbleSink {
  LastFmSink({
    required this.sessionKey,
    required this.config,
    Dio? dio,
    Uri? baseUri,
    this.timeout = kScrobbleTimeout,
  }) : _dio = dio ?? createAppDio(),
       _baseUri = baseUri ?? Uri.parse('https://ws.audioscrobbler.com/2.0/');

  final String Function() sessionKey;
  final LastFmApiConfig config;
  final Dio _dio;
  final Uri _baseUri;
  final Duration timeout;

  @override
  ScrobbleTarget get target => ScrobbleTarget.lastFm;

  @override
  Future<ScrobbleDelivery> sendNowPlaying(ScrobbleListen listen) =>
      _send(_nowPlayingParams(listen));

  @override
  Future<ScrobbleDelivery> sendScrobble(ScrobbleListen listen) =>
      _send(_scrobbleParams(listen));

  Map<String, String> _baseParams(String method, ScrobbleListen listen) {
    final track = listen.track;
    return {
      'method': method,
      'artist': track.artist,
      'track': track.title,
      if (track.album != null && track.album!.isNotEmpty) 'album': track.album!,
      if (track.trackNumber != null)
        'trackNumber': track.trackNumber!.toString(),
      'sk': sessionKey().trim(),
    };
  }

  Map<String, String> _nowPlayingParams(ScrobbleListen listen) =>
      _baseParams('track.updateNowPlaying', listen);

  Map<String, String> _scrobbleParams(ScrobbleListen listen) {
    final params = _baseParams('track.scrobble', listen);
    params['timestamp'] =
        (listen.startedAt.toUtc().millisecondsSinceEpoch ~/
                Duration.millisecondsPerSecond)
            .toString();
    return params;
  }

  Future<ScrobbleDelivery> _send(Map<String, String> params) async {
    if (!config.isConfigured) {
      return const ScrobbleDelivery.permanent(reason: 'not configured');
    }
    final key = sessionKey().trim();
    if (key.isEmpty) {
      return const ScrobbleDelivery.unauthorized(reason: 'missing session');
    }
    final signed = lastFmSignedParams(params, config: config);
    try {
      final response = await _dio
          .post<dynamic>(
            _baseUri.toString(),
            data: signed,
            options: Options(
              contentType: Headers.formUrlEncodedContentType,
              responseType: ResponseType.bytes,
            ),
          )
          .timeout(timeout);
      final status = response.statusCode ?? 0;
      if (status == 401 || status == 403) {
        return const ScrobbleDelivery.unauthorized();
      }
      if (status < 200 || status >= 300) {
        return deliveryForStatus(status, headers: response.headers.map);
      }
      final decoded = _decode(bodyText(response));
      final errorCode = decoded?['error'];
      if (errorCode is int) return _deliveryForErrorCode(errorCode);
      // 没有 error 字段即成功（不同方法的成功形状不同）。
      return const ScrobbleDelivery.success();
    } catch (error) {
      return deliveryForError(error);
    }
  }

  static Map<String, Object?>? _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      // Last.fm 偶发返回 XML / HTML；按成功形状看不了，交给状态码判定。
      return null;
    }
  }

  static ScrobbleDelivery _deliveryForErrorCode(int code) => switch (code) {
    4 || 9 => const ScrobbleDelivery.unauthorized(),
    8 || 11 || 16 || 29 => const ScrobbleDelivery.retryable(),
    _ => const ScrobbleDelivery.permanent(),
  };
}

/// Last.fm 浏览器授权状态机（无自定义 URL scheme）。
///
/// 流程：auth.getToken → 打开授权页 → 用户回到应用点「我已完成授权」→
/// auth.getSession 换取会话密钥。取消 / 令牌过期都回到未连接。
class LastFmAuth {
  LastFmAuth({
    required this.config,
    required this.openBrowser,
    Dio? dio,
    Uri? baseUri,
    this.timeout = kScrobbleTimeout,
  }) : _dio = dio ?? createAppDio(),
       _baseUri = baseUri ?? Uri.parse('https://ws.audioscrobbler.com/2.0/');

  final LastFmApiConfig config;

  /// 打开外部浏览器；返回 false 表示未能打开（不影响手动复制地址）。
  final Future<bool> Function(Uri uri) openBrowser;

  final Dio _dio;
  final Uri _baseUri;
  final Duration timeout;

  LastFmAuthStage _stage = LastFmAuthStage.idle;
  String? _token;
  String? _accountName;
  String? _sessionKey;

  LastFmAuthStage get stage => _stage;
  String? get accountName => _accountName;

  Uri? get authorizationUri {
    final token = _token;
    if (token == null || !config.isConfigured) return null;
    return Uri.https('www.last.fm', '/api/auth/', {
      'api_key': config.apiKey,
      'token': token,
    });
  }

  /// 请求令牌并打开授权页。未配置 / 网络失败 → failed，不留下半个状态。
  Future<LastFmAuthStage> begin() async {
    if (!config.isConfigured) {
      _stage = LastFmAuthStage.failed;
      return _stage;
    }
    _stage = LastFmAuthStage.awaitingUser;
    try {
      final response = await _call({'method': 'auth.getToken'});
      final token = response?['token'];
      if (token is! String || token.isEmpty) {
        _stage = LastFmAuthStage.failed;
        return _stage;
      }
      _token = token;
      final uri = authorizationUri;
      if (uri != null) {
        // 浏览器打不开时保留 awaitingUser：用户可以手动复制地址。
        await openBrowser(uri);
      }
    } catch (_) {
      _token = null;
      _stage = LastFmAuthStage.failed;
    }
    return _stage;
  }

  /// 用户确认完成授权后换取会话密钥。
  Future<LastFmAuthStage> complete() async {
    final token = _token;
    if (token == null || !config.isConfigured) {
      _stage = LastFmAuthStage.failed;
      return _stage;
    }
    _stage = LastFmAuthStage.exchanging;
    try {
      final response = await _call({
        'method': 'auth.getSession',
        'token': token,
      });
      final session = response?['session'];
      if (session is! Map) {
        _stage = LastFmAuthStage.failed;
        return _stage;
      }
      final key = session['key'];
      if (key is! String || key.isEmpty) {
        _stage = LastFmAuthStage.failed;
        return _stage;
      }
      final name = session['name'];
      _sessionKey = key;
      _accountName = name is String ? name : '';
      _token = null;
      _stage = LastFmAuthStage.connected;
    } catch (_) {
      _stage = LastFmAuthStage.failed;
    }
    return _stage;
  }

  /// 取消 / 返回：丢弃临时令牌，保持未连接。
  void cancel() {
    _token = null;
    _stage = LastFmAuthStage.cancelled;
  }

  /// 会话密钥只交给调用方写入密钥盒，不留在本对象。
  String? takeSessionKey() {
    final key = _sessionKey;
    _sessionKey = null;
    return key;
  }

  /// 取回 auth.getSession；失败返回 null 并让调用方进入 failed。
  Future<Map<String, Object?>?> _call(Map<String, String> params) async {
    final signed = lastFmSignedParams(params, config: config);
    final response = await _dio
        .post<dynamic>(
          _baseUri.toString(),
          data: signed,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            responseType: ResponseType.bytes,
          ),
        )
        .timeout(timeout);
    if ((response.statusCode ?? 0) < 200 || (response.statusCode ?? 0) >= 300) {
      throw StateError('last.fm auth http ${response.statusCode}');
    }
    final decoded = LastFmSink._decode(bodyText(response));
    if (decoded == null || decoded['error'] is int) return null;
    return decoded;
  }
}
