import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/data/update/update_manifest_client.dart';
import 'package:molia/domain/models/app_release.dart';

import '../support/mock_dio.dart';

/// 更新清单客户端：结构校验、渠道校验、镜像重写、地址覆盖。
void main() {
  Map<String, Object?> manifest({
    String channel = 'stable',
    String version = '1.2.3',
    int build = 42,
    List<Map<String, Object?>>? assets,
  }) =>
      {
        'schema': 1,
        'channel': channel,
        'version': version,
        'build': build,
        'releasedAt': '2026-10-14T00:00:00Z',
        'notes': '修复若干问题',
        'notesUrl': 'https://github.com/StillMisty/molia/releases/tag/v1.2.3',
        'assets': assets ??
            [
              {
                'platform': 'linux',
                'arch': 'x64',
                'kind': 'tar.gz',
                'file': 'molia-1.2.3-linux-x64.tar.gz',
                'url':
                    'https://github.com/StillMisty/molia/releases/download/v1.2.3/molia-1.2.3-linux-x64.tar.gz',
                'size': 123,
                'sha256': 'abc',
              },
            ],
      };

  String body(Map<String, Object?> value) => jsonEncode(value);

  test('合法清单解析：字段、时间与产物', () async {
    final adapter = MockDioAdapter((_) => textResponse(body(manifest())));
    final client = UpdateManifestClient(
      dio: createAppDio(adapter: adapter),
    );

    final release = await client.fetch(UpdateChannel.stable);
    expect(release.version, '1.2.3');
    expect(release.build, 42);
    expect(release.channel, UpdateChannel.stable);
    expect(release.notes, '修复若干问题');
    expect(release.releasedAt, DateTime.parse('2026-10-14T00:00:00Z'));
    expect(release.assets, hasLength(1));
    expect(release.assets.first.kind, 'tar.gz');
    expect(release.assets.first.sha256, 'abc');
    // 默认取稳定渠道清单。
    expect(
      adapter.lastRequest.uri.toString(),
      'https://github.com/StillMisty/molia/releases/latest/download/latest.json',
    );
  });

  test('beta 渠道取滚动 beta 清单', () async {
    final adapter = MockDioAdapter(
      (_) => textResponse(body(manifest(channel: 'beta'))),
    );
    final client = UpdateManifestClient(dio: createAppDio(adapter: adapter));

    await client.fetch(UpdateChannel.beta);
    expect(
      adapter.lastRequest.uri.toString(),
      'https://github.com/StillMisty/molia/releases/download/beta/latest.json',
    );
  });

  test('渠道不符被拒绝（防止镜像串渠道）', () async {
    final client = UpdateManifestClient(
      dio: createAppDio(
        adapter: MockDioAdapter(
          (_) => textResponse(body(manifest(channel: 'beta'))),
        ),
      ),
    );
    await expectLater(
      client.fetch(UpdateChannel.stable),
      throwsA(isA<UpdateFailureException>().having(
        (e) => e.kind,
        'kind',
        UpdateFailureKind.manifestInvalid,
      )),
    );
  });

  test('HTTP 非 200 归一为网络失败', () async {
    final client = UpdateManifestClient(
      dio: createAppDio(
        adapter: MockDioAdapter(
          (_) => textResponse('nope', statusCode: 503),
        ),
      ),
    );
    await expectLater(
      client.fetch(UpdateChannel.stable),
      throwsA(isA<UpdateFailureException>().having(
        (e) => e.kind,
        'kind',
        UpdateFailureKind.network,
      )),
    );
  });

  test('非法 JSON / schema 不符 / 无有效产物都归一为清单非法', () async {
    Future<void> expectInvalid(String raw) async {
      final client = UpdateManifestClient(
        dio: createAppDio(adapter: MockDioAdapter((_) => textResponse(raw))),
      );
      await expectLater(
        client.fetch(UpdateChannel.stable),
        throwsA(isA<UpdateFailureException>().having(
          (e) => e.kind,
          'kind',
          UpdateFailureKind.manifestInvalid,
        )),
      );
    }

    await expectInvalid('not json');
    await expectInvalid(body(manifest()..['schema'] = 99));
    await expectInvalid(body(manifest()..['version'] = 'x.y'));
    await expectInvalid(body(manifest()..['build'] = null));
    await expectInvalid(body(manifest(assets: [
      {'platform': 'linux', 'arch': 'x64', 'kind': 'tar.gz', 'url': 'ftp://x'},
    ])));
  });

  test('单个坏产物跳过，其余仍可用', () async {
    final client = UpdateManifestClient(
      dio: createAppDio(
        adapter: MockDioAdapter(
          (_) => textResponse(body(manifest(assets: [
            {
              'platform': 'linux',
              'arch': 'x64',
              'kind': 'tar.gz',
              'url': 'not a url',
            },
            {
              'platform': 'windows',
              'arch': 'x64',
              'kind': 'zip',
              'url': 'https://example.com/molia.zip',
            },
          ]))),
        ),
      ),
    );
    final release = await client.fetch(UpdateChannel.stable);
    expect(release.assets, hasLength(1));
    expect(release.assets.first.platform, 'windows');
  });

  test('镜像前缀重写清单与产物地址（已镜像不叠加）', () async {
    final adapter = MockDioAdapter((_) => textResponse(body(manifest())));
    final client = UpdateManifestClient(
      dio: createAppDio(adapter: adapter),
      downloadPrefix: () => 'https://gh-proxy.example/',
    );

    final release = await client.fetch(UpdateChannel.stable);
    expect(
      adapter.lastRequest.uri.toString(),
      'https://gh-proxy.example/https://github.com/StillMisty/molia/releases/latest/download/latest.json',
    );
    expect(
      client.resolveAssetUri(release.assets.first.url).toString(),
      startsWith('https://gh-proxy.example/https://github.com/'),
    );
    // 已带前缀的地址原样返回，避免二次叠加。
    final mirrored = Uri.parse('https://gh-proxy.example/https://github.com/x');
    expect(client.resolveAssetUri(mirrored), mirrored);
  });

  test('自定义清单地址覆盖默认地址；非法地址报清单非法', () async {
    final adapter = MockDioAdapter((_) => textResponse(body(manifest())));
    final client = UpdateManifestClient(
      dio: createAppDio(adapter: adapter),
      manifestUrlOverride: () => 'https://mirror.example/latest.json',
    );
    await client.fetch(UpdateChannel.stable);
    expect(adapter.lastRequest.uri.toString(),
        'https://mirror.example/latest.json');

    final bad = UpdateManifestClient(
      dio: createAppDio(adapter: adapter),
      manifestUrlOverride: () => 'not a url',
    );
    await expectLater(
      bad.fetch(UpdateChannel.stable),
      throwsA(isA<UpdateFailureException>().having(
        (e) => e.kind,
        'kind',
        UpdateFailureKind.manifestInvalid,
      )),
    );
  });
}
