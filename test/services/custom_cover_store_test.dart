import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/track.dart';
import 'package:molia/services/covers/custom_cover_store.dart';

Uint8List _bytes(int seed) => Uint8List.fromList([seed, seed, seed]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late CustomCoverStore store;

  CustomCoverStore buildStore() => CustomCoverStore(
        supportDirectory: () async => tempDir,
        // 固定时间会让替换文件名只在序号上不同，仍能验证「每次替换新文件」。
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('molia_custom_covers_');
    store = buildStore();
    CustomCoverStore.overrideInstance(store);
    await store.load();
  });

  tearDown(() async {
    CustomCoverStore.overrideInstance(null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('保存 / 查询 / 替换：新文件名、旧文件删除、revision 自增', () async {
    const id = TrackId('wy', '123');
    expect(store.trackCoverPath(id), isNull);

    final changes = <CustomCoverChange>[];
    final remove = store.addChangeListener(changes.add);
    addTearDown(remove);
    final revisionBefore = store.revision.value;

    await store.setTrackCover(id, _bytes(1));
    final firstPath = store.trackCoverPath(id);
    expect(firstPath, isNotNull);
    expect(File(firstPath!).existsSync(), isTrue);
    expect(firstPath, endsWith('.jpg'));
    expect(firstPath, contains('custom_covers'));
    expect(store.trackCoverUrl(id), Uri.file(firstPath).toString());
    expect(
      store.resolution
          .realOf(const Track(id: id, title: 'T', origin: TrackOrigin.builtin))
          .url,
      Uri.file(firstPath).toString(),
    );
    expect(store.revision.value, revisionBefore + 1);
    expect(changes.single.kind, CustomCoverChangeKind.track);
    expect(changes.single.trackId, id);

    await store.setTrackCover(id, _bytes(2));
    final secondPath = store.trackCoverPath(id);
    expect(secondPath, isNot(firstPath));
    expect(File(firstPath).existsSync(), isFalse, reason: '替换后旧文件应删除');
    expect(await File(secondPath!).readAsBytes(), _bytes(2));
  });

  test('键规范化：local 下载副本剥一层前缀，导入记录键保持', () async {
    const original = TrackId('wy', '42');
    const downloaded = TrackId('local', 'wy:42');
    final imported = TrackId('local', 'local:${tempDir.path}/song.mp3');

    await store.setTrackCover(original, _bytes(3));
    expect(store.trackCoverPath(downloaded), store.trackCoverPath(original));
    // 字符串入口同样按 raw TrackId.uri 规范化。
    expect(
      store.resolution.realForKey(downloaded.uri).url,
      store.trackCoverUrl(original),
    );

    await store.setTrackCover(imported, _bytes(4));
    expect(store.trackCoverUrl(imported), isNotNull);
    expect(
      store.trackCoverPath(TrackId('local', imported.id)),
      store.trackCoverPath(imported),
      reason: '导入记录键不再二次剥离',
    );
    expect(
      store.trackCoverPath(original),
      isNot(store.trackCoverPath(imported)),
    );
  });

  test('原始封面 / 默认封面：resolve 优先级与重置', () async {
    const id = TrackId('kw', '1');
    await store.setDefaultCover(_bytes(5));
    final defaultUrl = store.defaultCoverUrl;
    expect(defaultUrl, isNotNull);

    expect(
      store.resolution.realForId(id, originalUrl: 'https://img/a.jpg').url,
      'https://img/a.jpg',
    );
    expect(
      store.resolution.displayForId(id).url,
      defaultUrl,
      reason: '没有自定义 / 原始封面时展示默认封面',
    );

    await store.setTrackCover(id, _bytes(6));
    final customUrl = store.trackCoverUrl(id);
    expect(store.resolution.realForId(id).url, customUrl);
    expect(
      store.resolution.displayForId(id, originalUrl: 'https://img/a.jpg').url,
      customUrl,
      reason: '自定义封面优先于原始封面与默认封面',
    );

    await store.resetTrackCover(id);
    expect(store.trackCoverUrl(id), isNull);
    expect(
      store.resolution.realForId(id, originalUrl: 'https://img/a.jpg').url,
      'https://img/a.jpg',
    );

    final defaultPath = Uri.parse(store.defaultCoverUrl!).toFilePath();
    await store.resetDefaultCover();
    expect(store.defaultCoverUrl, isNull);
    expect(File(defaultPath).existsSync(), isFalse);
    expect(store.resolution.displayForId(id).url, isNull);
  });

  test('索引持久化：新实例 load 后仍可查询；丢失文件在 load 时剔除', () async {
    const id = TrackId('kw', '7');
    await store.setTrackCover(id, _bytes(7));
    await store.setDefaultCover(_bytes(8));
    final path = store.trackCoverPath(id)!;
    final defaultPath = Uri.parse(store.defaultCoverUrl!).toFilePath();

    final reloaded = buildStore();
    await reloaded.load();
    expect(reloaded.trackCoverPath(id), path);
    expect(reloaded.defaultCoverUrl, isNotNull);

    File(path).deleteSync();
    File(defaultPath).deleteSync();
    final pruned = buildStore();
    await pruned.load();
    expect(pruned.trackCoverPath(id), isNull);
    expect(pruned.defaultCoverUrl, isNull);

    // 索引被同步清理：再次读取不会复活指向丢失文件的条目。
    final again = buildStore();
    await again.load();
    expect(again.trackCoverPath(id), isNull);
  });

  test('换源跟随：复制到新曲目键，旧封面保留', () async {
    const oldTrack = Track(
      id: TrackId('wy', '1'),
      title: 'T',
      origin: TrackOrigin.builtin,
    );
    const newTrack = Track(
      id: TrackId('kg', '100'),
      title: 'T',
      origin: TrackOrigin.builtin,
    );
    await store.setTrackCover(oldTrack.id, _bytes(9));
    final oldPath = store.trackCoverPath(oldTrack.id)!;

    expect(await store.carryOver(oldTrack, newTrack), isTrue);
    final newPath = store.trackCoverPath(newTrack.id);
    expect(newPath, isNotNull);
    expect(newPath, isNot(oldPath));
    expect(File(oldPath).existsSync(), isTrue, reason: '复制不是移动');
    expect(await File(newPath!).readAsBytes(), _bytes(9));

    final before = store.revision.value;
    expect(await store.carryOver(newTrack, newTrack), isFalse);
    expect(store.revision.value, before);
    expect(
      await store.carryOver(
        const Track(
          id: TrackId('kw', 'empty'),
          title: 'E',
          origin: TrackOrigin.builtin,
        ),
        const Track(
          id: TrackId('tx', 'empty'),
          title: 'E',
          origin: TrackOrigin.builtin,
        ),
      ),
      isFalse,
    );
  });

  test('换源跟随：目标曲目已有封面时不覆盖', () async {
    const oldTrack = Track(
      id: TrackId('wy', '1'),
      title: 'T',
      origin: TrackOrigin.builtin,
    );
    const newTrack = Track(
      id: TrackId('kg', '100'),
      title: 'T',
      origin: TrackOrigin.builtin,
    );
    await store.setTrackCover(oldTrack.id, _bytes(14));
    await store.setTrackCover(newTrack.id, _bytes(15));
    final targetPath = store.trackCoverPath(newTrack.id)!;
    final before = store.revision.value;

    expect(await store.carryOver(oldTrack, newTrack), isFalse);
    expect(store.trackCoverPath(newTrack.id), targetPath);
    expect(
      await File(targetPath).readAsBytes(),
      _bytes(15),
      reason: '用户给新曲目选的封面不能被旧曲目的封面覆盖',
    );
    expect(store.revision.value, before);
  });

  test('读字节：存在 / 丢失都返回可判定的结果', () async {
    const id = TrackId('kw', 'bytes');
    await store.setTrackCover(id, _bytes(10));
    expect(await store.readTrackCover(id), _bytes(10));
    File(store.trackCoverPath(id)!).deleteSync();
    expect(await store.readTrackCover(id), isNull);
    expect(await store.readTrackCover(const TrackId('kw', 'none')), isNull);
  });

  test('同步接缝：远端应用刷新 revision，但不触发本地变更回调', () async {
    const id = TrackId('wy', 'sync');
    final localChanges = <CustomCoverChange>[];
    final observed = <CustomCoverChange>[];
    store.onLocalChange = localChanges.add;
    final remove = store.addChangeListener(observed.add);
    addTearDown(remove);

    await store.setTrackCover(id, _bytes(11));
    expect(localChanges, hasLength(1), reason: '本地写入触发同步标脏');
    expect(observed.single.trackId, id, reason: '本地写入带真实 TrackId');

    final revision = store.revision.value;
    await store.applySyncedTrackCover('wy:sync', _bytes(12));
    expect(await store.readTrackCover(id), _bytes(12));
    expect(localChanges, hasLength(1), reason: '远端应用不得形成同步回环');
    expect(observed, hasLength(2), reason: '展示面仍收到刷新');
    expect(observed.last.trackId, isNull, reason: '远端键不可靠，不猜测 TrackId');
    expect(store.revision.value, revision + 1);

    await store.applySyncedTrackDelete('wy:sync');
    expect(store.trackCoverPath(id), isNull);
    expect(observed.last.trackId, isNull);
    expect(localChanges, hasLength(1));

    await store.setDefaultCover(_bytes(13));
    await store.applySyncedDefaultCover(_bytes(14));
    expect(localChanges, hasLength(2));
    await store.applySyncedDefaultDelete();
    expect(store.defaultCoverUrl, isNull);
    expect(localChanges, hasLength(2));
  });

  test('损坏索引：按空索引启动，不抛异常', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(CustomCoverStore.prefsKey, '{not json');
    final fresh = buildStore();
    await fresh.load();
    expect(fresh.trackCoverPath(const TrackId('kw', '1')), isNull);
    expect(fresh.defaultCoverUrl, isNull);
  });
}
