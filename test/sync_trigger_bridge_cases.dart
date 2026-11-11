import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/services/sync_trigger_bridge.dart';

/// 同步触发桥：类型化变更流 / 直接变更 / 回调钩子都只经一个 owner，
/// dispose 后必须停止入队并把钩子恢复为绑前值。
void main() {
  test('attach：按事件携带的类别与 immediate 入队', () async {
    final sink = _Sink();
    final bridge = SyncTriggerBridge(localChange: sink.record);
    final changes = StreamController<SyncChange>.broadcast();
    addTearDown(changes.close);
    bridge.attach(changes.stream);

    changes.add(const SyncChange(categories: {SyncCategory.history}));
    changes.add(
      const SyncChange(categories: {SyncCategory.session}, immediate: false),
    );
    await pumpEventQueue();

    expect(sink.changes, hasLength(2));
    expect(sink.changes[0].categories, {SyncCategory.history});
    expect(sink.changes[0].immediate, isTrue);
    expect(sink.changes[1].categories, {SyncCategory.session});
    expect(sink.changes[1].immediate, isFalse);
    bridge.dispose();
  });

  test('dispose：取消流订阅并忽略之后的直接变更', () async {
    final sink = _Sink();
    final bridge = SyncTriggerBridge(localChange: sink.record);
    final changes = StreamController<SyncChange>.broadcast();
    addTearDown(changes.close);
    bridge.attach(changes.stream);
    bridge.localChange(categories: {SyncCategory.sources});

    bridge.dispose();
    changes.add(const SyncChange(categories: {SyncCategory.statistics}));
    bridge.localChange(categories: {SyncCategory.covers});
    await pumpEventQueue();

    expect(sink.changes, hasLength(1));
    expect(sink.changes.single.categories, {SyncCategory.sources});
  });

  test('设置写入钩子：标记键类别并在 dispose 后恢复 null', () {
    const key = SettingsKey<bool>(
      'sync_trigger_bridge_test',
      false,
      category: SyncCategory.settings,
    );
    final settings = SettingsRegistry(keys: const [key]);
    final sink = _Sink();
    final written = <SettingsKey<Object?>>[];
    final bridge = SyncTriggerBridge(localChange: sink.record)
      ..bindSettingsWrites(settings, onKeyWritten: written.add);

    settings.onWrite!(key);

    expect(sink.changes, hasLength(1));
    expect(sink.changes.single.categories, {SyncCategory.settings});
    expect(written, [key]);

    bridge.dispose();
    expect(settings.onWrite, isNull);
  });
}

class _Sink {
  final List<({Set<SyncCategory>? categories, bool immediate})> changes = [];

  void record({Set<SyncCategory>? categories, bool immediate = true}) {
    changes.add((categories: categories, immediate: immediate));
  }
}
