import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../data/http/app_dio.dart';
import 'lyric_provider.dart';
import 'qq_encoding.dart';

/// Web 端 QQ 歌词提供者：所有请求都通过 Cloudflare Worker 代理。
class QQProvider extends LyricProvider {
  static const String _defaultWorkerBaseUrl = 'https://lyrics.gojyuplus.com';
  static const Duration _requestTimeout = Duration(seconds: 12);
  final Logger _logger = Logger('molia.qq_provider_web');
  final Dio _dio;
  final String _workerBaseUrl;
  final String? _authSecret;

  QQProvider({
    Dio? dio,
    String? workerBaseUrl,
    String? authSecret,
  })  : _dio = dio ?? createAppDio(),
        _workerBaseUrl = workerBaseUrl ?? _defaultWorkerBaseUrl,
        _authSecret = authSecret;

  Map<String, String> get _jsonHeaders {
    final headers = <String, String>{
      'content-type': 'application/json',
    };

    final secret = _authSecret;
    if (secret != null && secret.isNotEmpty) {
      headers['authorization'] = 'Bearer $secret';
    }

    return headers;
  }

  Uri _endpoint(String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_workerBaseUrl$normalizedPath');
  }

  Future<Map<String, dynamic>?> _postJson(
    String path,
    Map<String, dynamic> payload, {
    bool treatNotFoundAsNull = true,
  }) async {
    try {
      final response = await _dio
          .postUri(
            _endpoint(path),
            data: jsonEncode(payload),
            options: Options(headers: _jsonHeaders),
          )
          .timeout(_requestTimeout);

      if (response.httpStatus >= 200 && response.httpStatus < 300) {
        return json.decode(bodyText(response)) as Map<String, dynamic>;
      }

      if (response.httpStatus == 404 && treatNotFoundAsNull) {
        _logger.info('Worker未找到资源: $path');
        return null;
      }

      _logger.warning(
        'Worker接口调用失败($path)，状态码: ${response.httpStatus}, 响应: ${bodyText(response)}',
      );
    } on TimeoutException catch (e) {
      _logger.warning('Worker请求超时: $e');
    } catch (e) {
      _logger.severe('调用Worker失败: $e');
    }
    return null;
  }

  @override
  String get name => 'qq';

  @override
  Future<SongMatch?> search(String title, String artist) async {
    final results = await searchMultiple(title, artist, limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  @override
  Future<List<SongMatch>> searchMultiple(String title, String artist, {int limit = 3}) async {
    final result = await _postJson('/qq/search', {
      'title': title,
      'artist': artist,
      'limit': limit,
    });

    if (result == null) {
      return [];
    }

    final matches = result['matches'];
    if (matches is! List || matches.isEmpty) {
      return [];
    }

    final results = <SongMatch>[];
    for (final item in matches) {
      final Map<String, dynamic>? match =
          item is Map ? Map<String, dynamic>.from(item) : null;
      if (match == null) continue;

      final songId = match['songId'] as String?;
      if (songId == null || songId.isEmpty) continue;

      results.add(SongMatch(
        songId: songId,
        title: _normalizeTextField(match['title'] as String?, title),
        artist: _normalizeTextField(match['artist'] as String?, artist),
      ));
    }
    return results;
  }

  @override
  Future<String?> fetchLyric(String songId) async {
    final result = await _postJson(
      '/qq/lyrics',
      {
        'songId': songId,
        'includeRomanized': true,
      },
    );

    return _extractLyric(result);
  }

  /// Web 端的 QQ 组合接口（/qq/resolveLyric）优先，失败回退到搜索 + 单独取词。
  @override
  Future<LyricsPayload?> getLyrics(String title, String artist) async {
    final payload = await _postJson(
      '/qq/resolveLyric',
      {
        'title': title,
        'artist': artist,
        'includeRomanized': true,
      },
      treatNotFoundAsNull: false,
    );

    final lyric = _extractLyric(payload);
    if (lyric != null && lyric.trim().isNotEmpty) {
      return LyricsPayload(lyric: normalizeLyric(lyric));
    }

    return super.getLyrics(title, artist);
  }

  String? _extractLyric(Map<String, dynamic>? payload) {
    if (payload == null) {
      return null;
    }

    final direct = payload['lyric'];
    if (direct is String && direct.trim().isNotEmpty) {
      return QQEncoding.normalize(direct);
    }

    final raw = payload['raw'];
    if (raw is Map<String, dynamic>) {
      final decoded = _decodeBase64Lyric(raw['lyric']);
      if (decoded != null && decoded.trim().isNotEmpty) {
        return decoded;
      }
    }

    return null;
  }

  String? _decodeBase64Lyric(dynamic value) {
    if (value is! String || value.isEmpty) {
      return null;
    }

    try {
      final sanitized = value.replaceAll(RegExp(r'\s'), '');
      final bytes = base64.decode(sanitized);
      final decoded = utf8.decode(bytes);
      return QQEncoding.normalize(decoded);
    } catch (_) {
      return null;
    }
  }

  String _normalizeTextField(String? value, String fallback) {
    final trimmed = (value ?? fallback).trim();
    if (trimmed.isEmpty) {
      return fallback;
    }
    return QQEncoding.normalize(trimmed);
  }
}
