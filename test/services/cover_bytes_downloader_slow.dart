import 'package:flutter_test/flutter_test.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/covers/cover_bytes_downloader.dart';

import '../support/mock_dio.dart';

/// 封面原图直连：统一请求头、8MB 上限与失败语义。
void main() {
  test('下载成功：带浏览器 UA / 平台 Referer，返回原图字节', () async {
    final dio = mockDio((options) => bytesResponse([1, 2, 3, 4]));
    const url = 'https://p1.music.126.net/cover.jpg';

    final bytes = await downloadCoverBytes(dio, url);

    expect(bytes, [1, 2, 3, 4]);
    expect(dio.httpClientAdapter, isA<MockDioAdapter>());
    final request = (dio.httpClientAdapter as MockDioAdapter).lastRequest;
    expect(request.uri.toString(), url);
    expect(request.headers['User-Agent'], ArtworkCache.browserUserAgent);
    expect(request.headers['Referer'], 'https://music.163.com/');
  });

  test('非 2xx / 空响应：返回 null', () async {
    final notFound = mockDio((options) => textResponse('no', statusCode: 404));
    expect(
      await downloadCoverBytes(notFound, 'https://example.com/a.jpg'),
      isNull,
    );

    final empty = mockDio((options) => bytesResponse(const []));
    expect(
      await downloadCoverBytes(empty, 'https://example.com/b.jpg'),
      isNull,
    );
  });

  test('超过大小上限：返回 null（不把异常大图落盘）', () async {
    final dio = mockDio((options) => bytesResponse([1, 2, 3]));
    expect(
      await downloadCoverBytes(dio, 'https://example.com/a.jpg', maxBytes: 2),
      isNull,
    );
  });
}
