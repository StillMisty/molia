import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/search_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设备本地搜索历史：渠道隔离、上限、去重与损坏降级。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<SearchHistoryStore> open() async {
    final store = SearchHistoryStore(preferences: prefs);
    await store.ready();
    addTearDown(store.dispose);
    return store;
  }

  test('按渠道隔离，切换渠道不丢另一渠道', () async {
    final store = await open();
    await store.record('kw', '晴天');
    await store.record('tx', '稻香');
    expect(store.entriesFor('kw'), ['晴天']);
    expect(store.entriesFor('tx'), ['稻香']);
  });

  test('trim、拒绝空值、大小写去重并移到最前，保留最新大小写', () async {
    final store = await open();
    await store.record('kw', '  Hello  ');
    await store.record('kw', 'world');
    await store.record('kw', 'HELLO');
    await store.record('kw', '   ');
    expect(store.entriesFor('kw'), ['HELLO', 'world']);
  });

  test('每渠道最多 20 条，超出淘汰最旧', () async {
    final store = await open();
    for (var index = 0; index < 25; index++) {
      await store.record('kw', 'q$index');
    }
    final entries = store.entriesFor('kw');
    expect(entries, hasLength(kSearchHistoryMaxEntries));
    expect(entries.first, 'q24');
    expect(entries.last, 'q5');
  });

  test('单条删除与清空只作用于当前渠道', () async {
    final store = await open();
    await store.record('kw', 'a');
    await store.record('kw', 'b');
    await store.record('tx', 'c');

    await store.remove('kw', 'A');
    expect(store.entriesFor('kw'), ['b']);
    expect(store.entriesFor('tx'), ['c']);

    await store.clear('kw');
    expect(store.entriesFor('kw'), isEmpty);
    expect(store.entriesFor('tx'), ['c']);
  });

  test('重新实例化后仍能读到历史', () async {
    final store = await open();
    await store.record('kw', '晴天');
    final reopened = await open();
    expect(reopened.entriesFor('kw'), ['晴天']);
  });

  test('损坏数据降级为空列表', () async {
    await prefs.setString('${SearchHistoryStore.storagePrefix}kw', '{bad json');
    final store = await open();
    expect(store.entriesFor('kw'), isEmpty);
  });

  test('变更会通知监听者', () async {
    final store = await open();
    var notifications = 0;
    store.addListener(() => notifications++);
    await store.record('kw', 'a');
    await store.remove('kw', 'a');
    expect(notifications, 2);
  });
}
