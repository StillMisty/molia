/// ListenBrainz 适配器：一个 POST 形状 + 一个口令校验接口。
///
/// 令牌只放在 Authorization 头里；异常与日志只带状态码，不带请求体。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/http/app_dio.dart';
import '../../domain/models/scrobble.dart';
import '../../domain/ports/scrobble_sink.dart';
import 'scrobble_http.dart';

class ListenBrainzSink implements ScrobbleSink, ScrobbleCredentialSink {
  ListenBrainzSink({
    required this.token,
    Dio? dio,
    Uri? baseUri,
    this.timeout = kScrobbleTimeout,
  }) : _dio = dio ?? createAppDio(),
       _baseUri = baseUri ?? Uri.parse('https://api.listenbrainz.org');

  /// 读取当前口令（每次请求现读：设置页写入后立即生效）。
  final String Function() token;

  final Dio _dio;
  final Uri _baseUri;
  final Duration timeout;

  static const String playerName = 'Molia';

  @override
  ScrobbleTarget get target => ScrobbleTarget.listenBrainz;

  @override
  Future<ScrobbleDelivery> sendNowPlaying(ScrobbleListen listen) =>
      _submit(listen, playingNow: true);

  @override
  Future<ScrobbleDelivery> sendScrobble(ScrobbleListen listen) =>
      _submit(listen, playingNow: false);

  @override
  Future<ScrobbleCredentialCheck> validateCredential(String credential) async {
    if (credential.trim().isEmpty) {
      return const ScrobbleCredentialCheck.invalid();
    }
    try {
      final response = await _dio
          .get<dynamic>(
            _baseUri.resolve('/1/validate-token').toString(),
            options: Options(
              headers: {'Authorization': 'Token ${credential.trim()}'},
              responseType: ResponseType.bytes,
            ),
          )
          .timeout(timeout);
      final status = response.statusCode ?? 0;
      if (status == 401 || status == 403) {
        return const ScrobbleCredentialCheck.invalid();
      }
      if (status < 200 || status >= 300) {
        return const ScrobbleCredentialCheck.invalid();
      }
      final decoded = jsonDecode(bodyText(response));
      if (decoded is! Map) return const ScrobbleCredentialCheck.invalid();
      final valid = decoded['valid'] == true;
      if (!valid) return const ScrobbleCredentialCheck.invalid();
      final userName = decoded['user_name'];
      return ScrobbleCredentialCheck.valid(
        userName is String && userName.trim().isNotEmpty ? userName.trim() : '',
      );
    } catch (_) {
      // 网络失败与「口令错误」必须区分：否则界面会误报需要换口令。
      return const ScrobbleCredentialCheck.unreachable();
    }
  }

  Future<ScrobbleDelivery> _submit(
    ScrobbleListen listen, {
    required bool playingNow,
  }) async {
    final credential = token().trim();
    if (credential.isEmpty) {
      return const ScrobbleDelivery.permanent(reason: 'missing credential');
    }
    final payload = {
      'listen_type': playingNow ? 'playing_now' : 'single',
      'payload': [
        {
          if (!playingNow)
            'listened_at':
                listen.startedAt.toUtc().millisecondsSinceEpoch ~/
                Duration.millisecondsPerSecond,
          'track_metadata': {
            'artist_name': listen.track.artist,
            'track_name': listen.track.title,
            if (listen.track.album != null && listen.track.album!.isNotEmpty)
              'release_name': listen.track.album,
            'additional_info': {
              'duration_ms': listen.track.duration.inMilliseconds,
              'submission_client': playerName,
              'media_player': playerName,
            },
          },
        },
      ],
    };
    try {
      final response = await _dio
          .post<dynamic>(
            _baseUri.resolve('/1/submit-listens').toString(),
            data: jsonEncode(payload),
            options: Options(
              headers: {
                'Authorization': 'Token $credential',
                'Content-Type': 'application/json',
              },
              responseType: ResponseType.bytes,
            ),
          )
          .timeout(timeout);
      return deliveryForStatus(
        response.statusCode ?? 0,
        headers: response.headers.map,
      );
    } catch (error) {
      return deliveryForError(error);
    }
  }
}
