import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/local_identity.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/download/download_records.dart';

/// 本地稳定身份规则与记录反查（纯 Dart，无数据库）。
void main() {
  group('stable local identity', () {
    test('newLocalKey 是 UUID v4 并带 file: 前缀', () {
      final random = Random(7);
      final a = newLocalKey(random);
      final b = newLocalKey(random);
      expect(a, startsWith('file:'));
      expect(b, startsWith('file:'));
      expect(a, isNot(b));
      expect(
        a,
        matches(
          RegExp(
            r'^file:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      // 注入固定随机源可复现（迁移测试 / 诊断用）。
      expect(newLocalKey(Random(7)), a);
    });

    test('旧导入身份只认带路径分隔符的 local: 值', () {
      expect(isLegacyLocalIdentity('local:/home/a.mp3'), isTrue);
      expect(isLegacyLocalIdentity(r'local:C:\Music\a.mp3'), isTrue);
      expect(
        isLegacyLocalIdentity(
          'local:file:11111111-1111-4111-8111-111111111111',
        ),
        isFalse,
      );
      expect(isLegacyLocalIdentity('local:wy:123'), isFalse, reason: '下载副本');
      expect(isLegacyLocalIdentity('wy:123'), isFalse);
      expect(isLegacyLocalIdentity('file:/music/a.mp3'), isFalse);
      expect(legacyLocalPathOf('local:/home/a.mp3'), '/home/a.mp3');
      expect(legacyLocalIdentityOf('/home/a.mp3'), 'local:/home/a.mp3');
    });

    test('封面键只排除导入身份，下载副本仍按在线封面同步', () {
      expect(isDeviceLocalCoverKey('file:abc'), isTrue);
      expect(isDeviceLocalCoverKey('local:/home/a.mp3'), isTrue);
      expect(isDeviceLocalCoverKey('local:wy:123'), isFalse);
      expect(isDeviceLocalCoverKey('wy:123'), isFalse);
    });
  });

  group('DownloadedTrack identity', () {
    DownloadedTrack import({
      String key = 'file:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    }) => DownloadedTrack(
      originSourceKey: kLocalSourceKey,
      originSongId: key,
      title: 'Imported',
      filePath: '/music/imported.mp3',
      sizeBytes: 10,
      imported: true,
      localKey: key,
      downloadedAt: 1,
    );

    DownloadedTrack copy() => const DownloadedTrack(
      originSourceKey: 'wy',
      originSongId: '123',
      title: 'Online copy',
      filePath: '/downloads/123.mp3',
      sizeBytes: 10,
      downloadedAt: 1,
    );

    test('导入记录：记录键是 local:<localKey>，领域 id 是 localKey', () {
      final record = import();
      expect(record.key, 'local:file:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(record.localSongId, record.localKey);
      expect(record.localTrack!.id, TrackId(kLocalSourceKey, record.localKey!));
      expect(record.localPayload['songId'], record.localKey);
      expect(record.toPlaylistTrack(addedAt: 1).songId, record.localKey);
      expect(record.toPlaylistTrack(addedAt: 1).sourceKey, kLocalSourceKey);
    });

    test('下载副本：不使用路径身份，保持原记录键', () {
      final record = copy();
      expect(record.localKey, isNull);
      expect(record.localSongId, 'wy:123');
      expect(record.localTrack!.id, const TrackId(kLocalSourceKey, 'wy:123'));
    });

    test('缺文件状态来自 missingAt；copyWith 可清除', () {
      final missing = import().copyWith(missingAt: 99);
      expect(missing.isMissing, isTrue);
      expect(missing.copyWith(clearMissingAt: true).isMissing, isFalse);
    });
  });

  group('DownloadRecords.recordForTrack', () {
    final importKey = 'file:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final importRecord = DownloadedTrack(
      originSourceKey: kLocalSourceKey,
      originSongId: importKey,
      title: 'Imported',
      filePath: '/music/imported.mp3',
      sizeBytes: 10,
      imported: true,
      localKey: importKey,
      downloadedAt: 1,
    );
    const copyRecord = DownloadedTrack(
      originSourceKey: 'wy',
      originSongId: '123',
      title: 'Copy',
      filePath: '/downloads/123.mp3',
      sizeBytes: 10,
      downloadedAt: 2,
    );
    final records = DownloadRecords(
      records: [importRecord, copyRecord],
      initialized: true,
      supported: true,
    );

    test('导入按 localKey 命中记录键 local:<localKey>', () {
      final track = importRecord.localTrack!;
      expect(records.recordForTrack(track), same(importRecord));
    });

    test('下载副本按自身 id 命中，不与导入交叉', () {
      final track = copyRecord.localTrack!;
      expect(track.id.id, 'wy:123');
      expect(records.recordForTrack(track), same(copyRecord));
      expect(
        records.recordForTrack(
          Track(
            id: TrackId(kLocalSourceKey, importKey),
            title: 'Imported',
            origin: TrackOrigin.localFile,
          ),
        ),
        same(importRecord),
      );
    });

    test('按路径反查导入记录（重复导入复用身份的入口）', () {
      expect(
        records.importedRecordForPath('/music/imported.mp3'),
        same(importRecord),
      );
      expect(records.importedRecordForPath('/downloads/123.mp3'), isNull);
    });
  });
}
