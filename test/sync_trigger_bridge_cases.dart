import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:molia/services/sync_trigger_bridge.dart';
import 'package:molia/sources/source_manager.dart';

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

  test('设置写入钩子链式：绑前回调与桥都触发，dispose 后只剩绑前', () {
    const key = SettingsKey<bool>(
      'sync_trigger_bridge_chain_test',
      false,
      category: SyncCategory.settings,
    );
    final settings = SettingsRegistry(keys: const [key]);
    final previousWrites = <SettingsKey<Object?>>[];
    final bridgeWrites = <SettingsKey<Object?>>[];
    final sink = _Sink();
    settings.onWrite = previousWrites.add;
    final bridge = SyncTriggerBridge(localChange: sink.record)
      ..bindSettingsWrites(settings, onKeyWritten: bridgeWrites.add);

    settings.onWrite!(key);

    expect(previousWrites, [key]);
    expect(bridgeWrites, [key]);
    expect(sink.changes, hasLength(1));
    expect(sink.changes.single.categories, {SyncCategory.settings});

    bridge.dispose();
    settings.onWrite!(key);

    expect(previousWrites, [key, key], reason: '绑前钩子恢复并继续工作');
    expect(bridgeWrites, [key], reason: '桥的记账回调不再触发');
    expect(sink.changes, hasLength(1), reason: '桥不再入队');
  });

  test('脚本写入钩子链式：绑前回调与桥都触发，dispose 后只剩绑前', () {
    final settings = SettingsRegistry(keys: const []);
    final sourceManager = SourceManager(settings: settings);
    addTearDown(sourceManager.dispose);
    final previousWritten = <String>[];
    final bridgeWritten = <String>[];
    final previousRemoved = <String>[];
    final bridgeRemoved = <String>[];
    sourceManager.onScriptWritten = previousWritten.add;
    sourceManager.onScriptRemoved = previousRemoved.add;
    final sink = _Sink();
    final bridge = SyncTriggerBridge(localChange: sink.record)
      ..bindScriptWrites(
        sourceManager,
        onScriptWritten: bridgeWritten.add,
        onScriptRemoved: bridgeRemoved.add,
      );

    sourceManager.onScriptWritten!('a');
    sourceManager.onScriptRemoved!('b');

    expect(previousWritten, ['a']);
    expect(bridgeWritten, ['a']);
    expect(previousRemoved, ['b']);
    expect(bridgeRemoved, ['b']);

    bridge.dispose();
    sourceManager.onScriptWritten!('c');
    sourceManager.onScriptRemoved!('d');

    expect(previousWritten, ['a', 'c'], reason: '绑前写入回调恢复');
    expect(bridgeWritten, ['a'], reason: '桥的写入记账不再触发');
    expect(previousRemoved, ['b', 'd'], reason: '绑前删除回调恢复');
    expect(bridgeRemoved, ['b'], reason: '桥的删除记账不再触发');
  });

  test('会话落盘钩子链式：绑前回调与桥都触发，dispose 后只剩绑前', () {
    final store = PlaybackSessionStore();
    var previousSaved = 0;
    var bridgeSaved = 0;
    store.onSaved = () => previousSaved++;
    final sink = _Sink();
    final bridge = SyncTriggerBridge(localChange: sink.record)
      ..bindSessionSaves(store, onSaved: () => bridgeSaved++);

    store.onSaved!();

    expect(previousSaved, 1);
    expect(bridgeSaved, 1);
    expect(sink.changes, hasLength(1));
    expect(sink.changes.single.categories, {SyncCategory.session});
    expect(sink.changes.single.immediate, isFalse);

    bridge.dispose();
    store.onSaved!();

    expect(previousSaved, 2, reason: '绑前回调恢复');
    expect(bridgeSaved, 1, reason: '桥的记账回调不再触发');
    expect(sink.changes, hasLength(1), reason: '桥不再入队');
  });

  test('封面写入钩子链式：绑前回调与桥都触发，dispose 后只剩绑前', () {
    final covers = CustomCoverStore();
    var previousChanges = 0;
    covers.onLocalChange = (_) => previousChanges++;
    final sink = _Sink();
    final bridge = SyncTriggerBridge(localChange: sink.record)
      ..bindLocalCoverChanges(covers);
    const change = CustomCoverChange(kind: CustomCoverChangeKind.defaultCover);

    covers.onLocalChange!(change);

    expect(previousChanges, 1);
    expect(sink.changes, hasLength(1));
    expect(sink.changes.single.categories, {SyncCategory.covers});

    bridge.dispose();
    covers.onLocalChange!(change);

    expect(previousChanges, 2, reason: '绑前回调恢复');
    expect(sink.changes, hasLength(1), reason: '桥不再入队');
  });
}

class _Sink {
  final List<({Set<SyncCategory>? categories, bool immediate})> changes = [];

  void record({Set<SyncCategory>? categories, bool immediate = true}) {
    changes.add((categories: categories, immediate: immediate));
  }
}
