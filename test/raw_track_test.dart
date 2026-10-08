import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/raw_track.dart';
import 'package:molia/sources/source_track.dart';

/// 平台 raw 约定（[rawIdOf] / [platformRawIdOf] / [withCanonicalId] /
/// [qualitiesFromRaw]）的单一测试面。
void main() {
  group('rawIdOf', () {
    test('按 songmid > hash > songId > id > mid 取第一个非空值', () {
      expect(rawIdOf({'songmid': 'm', 'hash': 'h'}), 'm');
      expect(rawIdOf({'hash': 'h', 'songId': 's'}), 'h');
      expect(rawIdOf({'songId': 's', 'id': 'i'}), 's');
      expect(rawIdOf({'id': 'i', 'mid': 'm'}), 'i');
      expect(rawIdOf({'mid': 'm'}), 'm');
    });

    test('跳过 null / 空串 / 纯空白；非字符串值 toString', () {
      expect(rawIdOf({'songmid': '', 'hash': '  ', 'songId': 's'}), 's');
      expect(rawIdOf({'songmid': null, 'id': 42}), '42');
    });

    test('无任何 id 字段返回空串', () {
      expect(rawIdOf(const {}), '');
      expect(rawIdOf({'name': 'x'}), '');
    });
  });

  group('platformRawIdOf', () {
    test('wy 按 songId > id > songmid（.lxmc 导出顺序）', () {
      expect(platformRawIdOf('wy', {'songId': 's', 'songmid': 'm'}), 's');
      expect(platformRawIdOf('wy', {'id': 'i', 'songmid': 'm'}), 'i');
      expect(platformRawIdOf('wy', {'songmid': 'm'}), 'm');
    });

    test('tx 优先 songmid；kg 优先 hash；mg 优先 copyrightId', () {
      expect(platformRawIdOf('tx', {'songmid': 'm', 'songId': 's'}), 'm');
      expect(platformRawIdOf('kg', {'hash': 'h', 'songmid': 'm'}), 'h');
      expect(platformRawIdOf('mg', {'copyrightId': 'c', 'songId': 's'}), 'c');
    });

    test('未登记平台按默认顺序（songId 优先）', () {
      expect(platformRawIdOf('custom', {'songId': 's', 'songmid': 'm'}), 's');
    });

    test('找不到返回空串', () {
      expect(platformRawIdOf('wy', const {}), '');
    });
  });

  group('withCanonicalId', () {
    test('补齐规范字段：wy songId → songmid、kg songId → hash', () {
      expect(withCanonicalId(sourceKey: 'wy', raw: {'songId': 1})['songmid'], '1');
      expect(withCanonicalId(sourceKey: 'kg', raw: {'songId': 's'})['hash'], 's');
      expect(
        withCanonicalId(sourceKey: 'mg', raw: {'songId': 's'})['copyrightId'],
        's',
      );
    });

    test('已有规范字段时返回原引用', () {
      final raw = {'songId': 's', 'songmid': 'orig'};
      expect(identical(withCanonicalId(sourceKey: 'wy', raw: raw), raw), isTrue);
    });

    test('只增不删：原有字段全部保留', () {
      final raw = <String, dynamic>{
        'songId': 's',
        'albumName': 'A',
        'qualitys': const [],
      };
      final out = withCanonicalId(sourceKey: 'wy', raw: raw);
      expect(out['songId'], 's');
      expect(out['albumName'], 'A');
      expect(out['qualitys'], isEmpty);
      expect(out['songmid'], 's');
      expect(out.length, raw.length + 1);
    });

    test('无 id 可补 / 未登记平台：原样返回', () {
      final noId = <String, dynamic>{'name': 'x'};
      expect(identical(withCanonicalId(sourceKey: 'wy', raw: noId), noId), isTrue);
      final custom = <String, dynamic>{'songId': 's'};
      expect(
        identical(withCanonicalId(sourceKey: 'custom', raw: custom), custom),
        isTrue,
      );
    });
  });

  group('qualitiesFromRaw', () {
    test('qualitys 数组 + _qualitys 映射合并，hash 来自映射', () {
      final qualities = qualitiesFromRaw({
        'qualitys': [
          {'type': '320k', 'size': '2 MiB'},
        ],
        '_qualitys': {
          'flac': {'size': '10 MiB', 'hash': 'h1'},
          '128k': {'size': '1 MiB'},
        },
      });
      expect(qualities.map((q) => q.type).toList(), ['320k', 'flac', '128k']);
      expect(qualities.firstWhere((q) => q.type == 'flac').hash, 'h1');
      expect(qualities.firstWhere((q) => q.type == '128k').size, '1 MiB');
    });

    test('内置平台 _types 映射兼容（带 hash）', () {
      final qualities = qualitiesFromRaw({
        '_types': {
          '128k': {'size': '1 MiB'},
          '320k': {'size': '3 MiB'},
          'flac': {'size': '9 MiB', 'hash': 'hh'},
        },
      });
      expect(qualities.map((q) => q.type).toList(), ['128k', '320k', 'flac']);
      expect(qualities.firstWhere((q) => q.type == 'flac').hash, 'hh');
    });

    test('按 type 去重（首次出现优先）；空 raw 返回空列表', () {
      final qualities = qualitiesFromRaw({
        'qualitys': [
          {'type': '320k', 'size': '1 MiB'},
          {'type': '320k', 'size': '2 MiB'},
        ],
      });
      expect(qualities, hasLength(1));
      expect(qualities.single.size, '1 MiB');
      expect(qualitiesFromRaw(const {}), isEmpty);
    });
  });

  group('SourceTrack.id', () {
    test('与 rawIdOf 一致（含平台前缀）', () {
      final track = SourceTrack(
        sourceKey: 'kw',
        origin: 'builtin',
        title: 'T',
        artist: 'A',
        album: '',
        raw: const {'songmid': 'm1'},
      );
      expect(track.id, 'kw:m1');
    });

    test('无 id 字段时兜底 title-artist', () {
      final track = SourceTrack(
        sourceKey: 'wy',
        origin: 'builtin',
        title: 'T',
        artist: 'A',
        album: '',
        raw: const {},
      );
      expect(track.id, 'wy:T-A');
    });
  });
}
