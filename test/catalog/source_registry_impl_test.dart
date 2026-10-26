import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/local_music_source.dart';
import 'package:molia/data/catalog/source_registry_impl.dart';
import 'package:molia/domain/models/source.dart' as domain;
import 'package:molia/domain/models/track.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('无脚本：只有原生的 bili 可搜索；byKey 懒创建（空 key 为 null）', () async {
    final manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    final registry = SourceRegistryImpl(manager);
    addTearDown(() {
      registry.dispose();
      manager.dispose();
    });

    // bili 的搜索/取链不依赖 LX 脚本，是唯一无脚本可用源。
    expect(registry.descriptors.map((d) => d.key), ['bili']);
    expect(registry.byKey(''), isNull);

    final source = registry.byKey('kw');
    expect(source, isNotNull);
    expect(source!.key, 'kw');
    // 懒创建 + 缓存：同 key 恒为同一实例。
    expect(registry.byKey('kw'), same(source));
  });

  test('descriptors：由 sourceProfiles 快照映射（key/名称/kind/order/能力）', () async {
    final manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    final registry = SourceRegistryImpl(manager);
    addTearDown(() {
      registry.dispose();
      manager.dispose();
    });

    await manager.updateAnyListenConfig(AnyListenConfig(
      serverUrl: 'http://127.0.0.1:9500',
      enabled: true,
    ));

    final descriptors = registry.descriptors;
    final profiles = manager.sourceProfiles.searchable;
    expect(descriptors.map((d) => d.key), [
      'bili',
      AnyListenSource.sourceKey,
    ]);
    // 列表与能力位来自同一次画像快照，不能再各算一份。
    expect(descriptors.map((d) => d.key), profiles.map((p) => p.key));
    for (var index = 0; index < descriptors.length; index++) {
      expect(descriptors[index].displayName, profiles[index].displayName);
      expect(descriptors[index].capabilities, profiles[index].capabilities);
    }

    final bili = descriptors.first;
    expect(bili.displayName, '哔哩哔哩');
    expect(bili.capabilities.search, isTrue);
    expect(bili.capabilities.resolveUrl, isTrue);
    expect(bili.capabilities.lyrics, isTrue);
    expect(bili.capabilities.artist, isTrue);
    expect(bili.discoverable, isTrue);
    expect(bili.enabled, isTrue);
    expect(bili.order, 0);

    final descriptor = descriptors.last;
    expect(descriptor.key, AnyListenSource.sourceKey);
    expect(descriptor.displayName, AnyListenSource.displayName);
    expect(descriptor.kind, domain.SourceKind.anyListen);
    expect(descriptor.enabled, isTrue);
    expect(descriptor.order, 1);
    expect(descriptor.capabilities.search, isTrue);
    expect(descriptor.capabilities.resolveUrl, isTrue);
    expect(descriptor.capabilities.collection, isFalse);

    // byKey 与 descriptor 一致，且返回同一个懒创建实例。
    expect(registry.byKey(AnyListenSource.sourceKey)!.key, descriptor.key);
  });

  test('forTrack 按 track.id.sourceKey 查找', () async {
    final manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    final registry = SourceRegistryImpl(manager);
    addTearDown(() {
      registry.dispose();
      manager.dispose();
    });

    final track = Track(
      id: const TrackId('kw', 'x'),
      title: 't',
      origin: TrackOrigin.builtin,
    );
    expect(registry.forTrack(track)!.key, 'kw');
    expect(registry.forTrack(track), same(registry.byKey('kw')));
  });

  test('local key 路由到 LocalMusicSource（不撞 manager、不进 descriptors）', () async {
    final manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    final registry = SourceRegistryImpl(manager);
    addTearDown(() {
      registry.dispose();
      manager.dispose();
    });

    final source = registry.byKey('local');
    expect(source, isA<LocalMusicSource>());
    expect(source!.capabilities.resolveUrl, isTrue);
    expect(source.capabilities.search, isFalse);
    // 懒创建 + 缓存：同 key 恒为同一实例。
    expect(registry.byKey('local'), same(source));
    // 本地下载源不参与搜索/渠道排序。
    expect(registry.descriptors.any((d) => d.key == 'local'), isFalse);

    final localTrack = Track(
      id: const TrackId('local', 'kw:1'),
      title: '本地',
      origin: TrackOrigin.localFile,
      payload: const {'path': '/data/a.mp3'},
    );
    expect(registry.forTrack(localTrack), same(source));
  });

  test('changes 转发 manager 通知；refresh 也广播一次', () async {
    final manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    final registry = SourceRegistryImpl(manager);
    addTearDown(() {
      registry.dispose();
      manager.dispose();
    });

    final events = <void>[];
    final subscription = registry.changes.listen(events.add);
    addTearDown(subscription.cancel);

    await manager.updateAnyListenConfig(AnyListenConfig(
      serverUrl: 'http://127.0.0.1:9500',
      enabled: true,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1), reason: 'manager 通知应转发一次');

    await registry.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2));
  });

  test('setOrder 转发 manager.setSourceOrder（lx_source_order 语义不变）', () async {
    final manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    final registry = SourceRegistryImpl(manager);
    addTearDown(() {
      registry.dispose();
      manager.dispose();
    });

    await registry.setOrder(['tx', 'kw', 'tx', '']);
    expect(manager.sourceOrder, ['tx', 'kw']);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('lx_source_order'), ['tx', 'kw']);
  });
}
