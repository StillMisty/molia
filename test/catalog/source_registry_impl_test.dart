import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/source_registry_impl.dart';
import 'package:molia/domain/models/source.dart' as domain;
import 'package:molia/domain/models/track.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('无可用源：descriptors 为空；byKey 懒创建（空 key 为 null）', () async {
    final manager = SourceManager();
    await manager.init();
    final registry = SourceRegistryImpl(manager);
    addTearDown(() {
      registry.dispose();
      manager.dispose();
    });

    expect(registry.descriptors, isEmpty);
    expect(registry.byKey(''), isNull);

    final source = registry.byKey('kw');
    expect(source, isNotNull);
    expect(source!.key, 'kw');
    // 懒创建 + 缓存：同 key 恒为同一实例。
    expect(registry.byKey('kw'), same(source));
  });

  test('descriptors：由 searchableSources 映射（key/名称/kind/order/能力）', () async {
    final manager = SourceManager();
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
    expect(descriptors, hasLength(1));
    final descriptor = descriptors.single;
    expect(descriptor.key, AnyListenSource.sourceKey);
    expect(descriptor.displayName, AnyListenSource.displayName);
    expect(descriptor.kind, domain.SourceKind.anyListen);
    expect(descriptor.enabled, isTrue);
    expect(descriptor.order, 0);
    expect(descriptor.capabilities.search, isTrue);
    expect(descriptor.capabilities.resolveUrl, isTrue);
    expect(descriptor.capabilities.collection, isFalse);

    // byKey 与 descriptor 一致，且返回同一个懒创建实例。
    expect(registry.byKey(AnyListenSource.sourceKey)!.key, descriptor.key);
  });

  test('forTrack 按 track.id.sourceKey 查找', () async {
    final manager = SourceManager();
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

  test('changes 转发 manager 通知；refresh 也广播一次', () async {
    final manager = SourceManager();
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
    final manager = SourceManager();
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

  test('dispose 后不再转发 manager 通知（不抛错）', () async {
    final manager = SourceManager();
    await manager.init();
    final registry = SourceRegistryImpl(manager);
    addTearDown(manager.dispose);

    registry.dispose();
    await manager.updateAnyListenConfig(AnyListenConfig(
      serverUrl: 'http://127.0.0.1:9500',
      enabled: true,
    ));
  });
}
