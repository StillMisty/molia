import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/download/download_records.dart';

DownloadedTrack record(
  String id, {
  String sourceKey = 'kw',
  int downloadedAt = 1,
  String? title,
}) => DownloadedTrack(
  originSourceKey: sourceKey,
  originSongId: id,
  title: title ?? '歌曲 $id',
  filePath: '/downloads/$id.mp3',
  downloadedAt: downloadedAt,
);

void main() {
  test('downloads：按下载时间倒序，时间相同按 key 倒序，返回不可变列表', () {
    final records = DownloadRecords(
      records: [
        record('old', downloadedAt: 1),
        record('a', downloadedAt: 2),
        record('b', downloadedAt: 2),
      ],
    );
    addTearDown(records.dispose);

    expect(records.downloads.map((item) => item.key), [
      'kw:b',
      'kw:a',
      'kw:old',
    ]);
    expect(() => records.downloads.add(record('x')), throwsUnsupportedError);
    expect(
      identical(records.downloads, records.downloads),
      isTrue,
      reason: '排序结果缓存到下次记录变化',
    );
  });

  test('recordFor / recordForTrack：在线按原音源键，本地按 local songId', () {
    final online = record('1');
    final local = record('kw:1', sourceKey: kLocalSourceKey);
    final records = DownloadRecords(records: [online, local]);
    addTearDown(records.dispose);

    expect(records.recordFor('kw', '1'), same(online));
    expect(records.recordFor('kw', '2'), isNull);
    expect(
      records.recordForTrack(
        const Track(
          id: TrackId('kw', '1'),
          title: '在线',
          origin: TrackOrigin.builtin,
        ),
      ),
      same(online),
    );
    expect(
      records.recordForTrack(
        const Track(
          id: TrackId(kLocalSourceKey, 'local:kw:1'),
          title: '本地',
          origin: TrackOrigin.localFile,
        ),
      ),
      same(local),
    );
  });

  test('put / remove：真实变化递增 revision 并通知，重复写入 no-op', () {
    final records = DownloadRecords();
    addTearDown(records.dispose);
    var notifications = 0;
    records.addListener(() => notifications++);

    final first = record('1');
    records.put(first);
    expect(records.revision, 1);
    expect(notifications, 1);
    expect(records.recordFor('kw', '1'), same(first));

    // 同一实例重复写入不算变化。
    records.put(first);
    expect(records.revision, 1);
    expect(notifications, 1);

    // 同一键的新快照（标题 / 路径变化）算一次记录变化。
    final updated = record('1', title: '改名');
    records.put(updated);
    expect(records.revision, 2);
    expect(notifications, 2);
    expect(records.recordFor('kw', '1'), same(updated));

    records.remove('kw:1');
    expect(records.recordFor('kw', '1'), isNull);
    expect(records.revision, 3);
    expect(notifications, 3);

    // 不存在的键移除是 no-op。
    records.remove('kw:missing');
    expect(records.revision, 3);
    expect(notifications, 3);
  });

  test('replaceAll：整表替换；同一批实例重复替换不通知', () {
    final records = DownloadRecords(records: [record('1'), record('2')]);
    addTearDown(records.dispose);
    var notifications = 0;
    records.addListener(() => notifications++);

    final replaced = [record('2', title: '新标题'), record('3')];
    records.replaceAll(replaced);
    expect(
      records.downloads.map((item) => item.key),
      unorderedEquals(['kw:2', 'kw:3']),
    );
    expect(records.revision, 1);
    expect(notifications, 1);

    records.replaceAll(replaced);
    expect(records.revision, 1);
    expect(notifications, 1);
  });

  test('initialized / supported：只在值变化时递增 revision 并通知', () {
    final records = DownloadRecords();
    addTearDown(records.dispose);
    var notifications = 0;
    records.addListener(() => notifications++);

    expect(records.initialized, isFalse);
    expect(records.supported, isFalse);

    records.markInitialized();
    expect(records.initialized, isTrue);
    expect(records.revision, 1);
    expect(notifications, 1);

    records.markInitialized();
    expect(records.revision, 1);
    expect(notifications, 1);

    records.setSupported(true);
    expect(records.supported, isTrue);
    expect(records.revision, 2);
    expect(notifications, 2);

    records.setSupported(true);
    expect(records.revision, 2);
    expect(notifications, 2);

    records.setSupported(false);
    expect(records.supported, isFalse);
    expect(records.revision, 3);
    expect(notifications, 3);
  });

  test('初始化种子不产生通知：构造时就有记录与能力位', () {
    var notifications = 0;
    final records = DownloadRecords(
      records: [record('1')],
      initialized: true,
      supported: true,
    );
    addTearDown(records.dispose);
    records.addListener(() => notifications++);

    expect(records.revision, 0);
    expect(records.initialized, isTrue);
    expect(records.supported, isTrue);
    expect(records.downloads, hasLength(1));
    expect(notifications, 0);
  });
}
