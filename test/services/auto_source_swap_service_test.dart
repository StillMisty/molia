import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/source_swap/auto_source_swap_service.dart';

import '../support/fake_music_source.dart';

/// 自动换源严格匹配：跨源找回 / 排除来源 / 宁可不换。
void main() {
  Track track(
    String sourceKey,
    String id, {
    String title = '晴天',
    String artist = '周杰伦',
    int? seconds = 269,
  }) =>
      Track(
        id: TrackId(sourceKey, id),
        title: title,
        artists: [Artist(name: artist)],
        duration: seconds == null ? null : Duration(seconds: seconds),
        origin: TrackOrigin.builtin,
        payload: {'songmid': id, 'source': sourceKey},
      );

  late FakeMusicSource wy;
  late FakeMusicSource kg;
  late FakeMusicSource tx;
  late Map<String, FakeMusicSource> sources;
  late AutoSourceSwapService service;

  setUp(() {
    wy = FakeMusicSource('wy');
    kg = FakeMusicSource('kg');
    tx = FakeMusicSource('tx');
    sources = {'wy': wy, 'kg': kg, 'tx': tx};
    service = AutoSourceSwapService(
      catalog: CatalogService(registry: FakeSourceRegistry(sources)),
      registry: FakeSourceRegistry(sources),
    );
  });

  test('跨源严格找回：跳过原源与不同版本，选中最优匹配', () async {
    kg.items = [
      track('kg', 'live', title: '晴天 (Live)'),
      track('kg', '100'),
      track('kg', 'short', seconds: 100),
    ];
    tx.items = [track('tx', '200')];

    final match = await service.findMatch(track('wy', '1'));

    expect(match?.id.uri, 'kg:100');
    expect(wy.searchCalls, 0, reason: '原源不参与自动换源');
    expect(kg.lastQuery?.keyword, '晴天 周杰伦');
  });

  test('排除已尝试来源：只查未尝试的源', () async {
    kg.items = [track('kg', '100')];
    tx.items = [track('tx', '200')];

    final match = await service.findMatch(
      track('wy', '1'),
      excludeSourceKeys: {'kg'},
    );

    expect(match?.id.uri, 'tx:200');
    expect(kg.searchCalls, 0);
  });

  test('全部无命中 / 全部排除：返回 null（宁可不换）', () async {
    kg.items = [track('kg', 'short', seconds: 100)];
    tx.items = [track('tx', 'live', title: '晴天 (Live)')];

    expect(await service.findMatch(track('wy', '1')), isNull);
    expect(
      await service.findMatch(
        track('wy', '1'),
        excludeSourceKeys: {'kg', 'tx'},
      ),
      isNull,
    );
  });

  test('单源失败静默：其它源仍命中', () async {
    kg.fail = true;
    tx.items = [track('tx', '200')];

    final match = await service.findMatch(track('wy', '1'));
    expect(match?.id.uri, 'tx:200');

    // 两个源都失败（新服务避免命中 5min 搜索缓存）：返回 null，不抛异常。
    tx.fail = true;
    final fresh = AutoSourceSwapService(
      catalog: CatalogService(registry: FakeSourceRegistry(sources)),
      registry: FakeSourceRegistry(sources),
    );
    expect(await fresh.findMatch(track('wy', '1')), isNull);
  });

  test('结果复用 CatalogService 缓存：重复调用不重打网络', () async {
    kg.items = [track('kg', '100')];
    await service.findMatch(track('wy', '1'));
    await service.findMatch(track('wy', '1'));
    expect(kg.searchCalls, 1);
  });

  test('种子时长未知：不按时长过滤', () async {
    kg.items = [track('kg', '100', seconds: 100)];
    final match = await service.findMatch(track('wy', '1', seconds: null));
    expect(match?.id.uri, 'kg:100');
  });
}
