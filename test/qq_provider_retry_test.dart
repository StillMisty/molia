import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/lyrics/qq_provider_mobile.dart';
import 'support/mock_dio.dart';

/// QQ 歌词 403/429 的备用域名切换最多一次，失败即放弃。
void main() {
  test('403 切换备用域名仅一次，第二次失败即放弃', () async {
    var calls = 0;
    final provider = QQProvider(
      dio: mockDio((request) async {
        calls++;
        return textResponse('forbidden', statusCode: 403);
      }),
    );

    expect(await provider.fetchLyricPayload('song-1'), isNull);
    expect(calls, 2);
  });

  test('429 同样受限；200 正常返回内容', () async {
    var calls = 0;
    final limited = QQProvider(
      dio: mockDio((request) async {
        calls++;
        return textResponse('too many requests', statusCode: 429);
      }),
    );
    expect(await limited.fetchLyricPayload('song-1'), isNull);
    expect(calls, 2);

    final ok = QQProvider(
      dio: mockDio((request) async => textResponse(
            '{"lyric":"[00:00.00]hi"}',
            statusCode: 200,
            headers: {
              'content-type': ['application/json; charset=utf-8']
            },
          )),
    );
    final payload = await ok.fetchLyricPayload('song-1');
    expect(payload, isNotNull);
    expect(payload!.hasAnyContent, isTrue);
  });
}
