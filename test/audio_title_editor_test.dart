import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/audio_title_editor.dart';

import 'support/fake_download_storage.dart';

/// 只改标题的标签编辑器：帧 / 元数据块按字节保留，音频字节不变。
void main() {
  late FakeDownloadStorage storage;
  const path = '/music/song.mp3';

  setUp(() {
    storage = FakeDownloadStorage();
  });

  Uint8List frame(String id, List<int> body, {int version = 3}) {
    final size = body.length;
    final header = <int>[...ascii.encode(id)];
    if (version == 4) {
      header.addAll([
        (size >> 21) & 0x7F,
        (size >> 14) & 0x7F,
        (size >> 7) & 0x7F,
        size & 0x7F,
      ]);
    } else {
      header.addAll([
        (size >> 24) & 0xFF,
        (size >> 16) & 0xFF,
        (size >> 8) & 0xFF,
        size & 0xFF,
      ]);
    }
    header.addAll([0, 0]);
    return Uint8List.fromList([...header, ...body]);
  }

  Uint8List textFrame(String id, String text, {int version = 3}) {
    final List<int> body;
    if (version == 4) {
      body = [3, ...utf8.encode(text)];
    } else {
      body = [1, 0xFF, 0xFE];
      for (final unit in text.codeUnits) {
        body.add(unit & 0xFF);
        body.add((unit >> 8) & 0xFF);
      }
    }
    return frame(id, body, version: version);
  }

  Uint8List id3File({
    required List<Uint8List> frames,
    required List<int> audio,
    int version = 3,
    int flags = 0,
  }) {
    final body = <int>[for (final frame in frames) ...frame];
    final header = <int>[
      0x49,
      0x44,
      0x33,
      version,
      0,
      flags,
      (body.length >> 21) & 0x7F,
      (body.length >> 14) & 0x7F,
      (body.length >> 7) & 0x7F,
      body.length & 0x7F,
    ];
    return Uint8List.fromList([...header, ...body, ...audio]);
  }

  List<({String id, Uint8List bytes})> mp3Frames(Uint8List file) {
    final version = file[3];
    final size =
        ((file[6] & 0x7F) << 21) |
        ((file[7] & 0x7F) << 14) |
        ((file[8] & 0x7F) << 7) |
        (file[9] & 0x7F);
    final result = <({String id, Uint8List bytes})>[];
    var offset = 10;
    final end = 10 + size;
    while (offset + 10 <= end) {
      final id = ascii.decode(file.sublist(offset, offset + 4));
      if (id.codeUnits.every((unit) => unit == 0)) break;
      final length = version == 4
          ? ((file[offset + 4] & 0x7F) << 21) |
                ((file[offset + 5] & 0x7F) << 14) |
                ((file[offset + 6] & 0x7F) << 7) |
                (file[offset + 7] & 0x7F)
          : (file[offset + 4] << 24) |
                (file[offset + 5] << 16) |
                (file[offset + 6] << 8) |
                file[offset + 7];
      result.add((
        id: id,
        bytes: Uint8List.sublistView(file, offset, offset + 10 + length),
      ));
      offset += 10 + length;
    }
    return result;
  }

  Uint8List audioOfMp3(Uint8List file, int audioStart) =>
      Uint8List.sublistView(file, audioStart);

  final audio = <int>[0xFF, 0xFB, 0x90, 0x00, 1, 2, 3, 4];

  test('ID3v2.3：只替换 TIT2，其它帧与音频逐字节保留', () async {
    final apic = frame('APIC', [0, ...utf8.encode('image/png'), 0, 9, 8, 7]);
    final uslt = frame('USLT', [3, ...utf8.encode('lyrics')]);
    final original = id3File(
      frames: [
        textFrame('TIT2', '旧标题'),
        textFrame('TPE1', '歌手'),
        textFrame('TALB', '专辑'),
        apic,
        uslt,
        frame('TXXX', [3, ...utf8.encode('k=v')]),
      ],
      audio: audio,
    );
    storage.files[path] = original;
    final oldFrames = mp3Frames(original);
    final oldAudioStart =
        10 +
        ((original[6] & 0x7F) << 21) +
        ((original[7] & 0x7F) << 14) +
        ((original[8] & 0x7F) << 7) +
        (original[9] & 0x7F);

    final outcome = await rewriteAudioTitle(
      storage: storage,
      filePath: path,
      title: '新标题',
    );
    expect(outcome, TagWriteOutcome.written);

    final updated = Uint8List.fromList(storage.files[path]!);
    final newFrames = mp3Frames(updated);
    expect(newFrames.where((frame) => frame.id == 'TIT2'), hasLength(1));
    expect(debugReadTitle(updated, extension: '.mp3'), '新标题');
    // 非标题帧顺序与字节完全一致。
    expect(
      [
        for (final frame in newFrames)
          if (frame.id != 'TIT2') frame.bytes,
      ],
      [
        for (final frame in oldFrames)
          if (frame.id != 'TIT2') frame.bytes,
      ],
    );
    final newAudioStart =
        10 +
        ((updated[6] & 0x7F) << 21) +
        ((updated[7] & 0x7F) << 14) +
        ((updated[8] & 0x7F) << 7) +
        (updated[9] & 0x7F);
    expect(
      audioOfMp3(updated, newAudioStart),
      audioOfMp3(original, oldAudioStart),
    );
    expect(storage.files.keys.where((key) => key.endsWith('.tmp')), isEmpty);
  });

  test('ID3v2.4：synchsafe 帧长、UTF-8 编码，其它帧保留', () async {
    final original = id3File(
      version: 4,
      frames: [
        textFrame('TPE1', '歌手', version: 4),
        textFrame('TIT2', '旧标题', version: 4),
      ],
      audio: audio,
    );
    storage.files[path] = original;

    expect(
      await rewriteAudioTitle(storage: storage, filePath: path, title: '新标题'),
      TagWriteOutcome.written,
    );
    final updated = Uint8List.fromList(storage.files[path]!);
    expect(updated[3], 4);
    expect(debugReadTitle(updated, extension: '.mp3'), '新标题');
    final frames = mp3Frames(updated);
    expect(frames.first.id, 'TPE1');
    expect(frames.last.id, 'TIT2');
    expect(frames.last.bytes[10], 3, reason: 'v2.4 用 UTF-8');
  });

  test('MP3 无标签：新建 v2.3 标签，音频字节不变', () async {
    storage.files[path] = audio;
    expect(
      await rewriteAudioTitle(storage: storage, filePath: path, title: '新标题'),
      TagWriteOutcome.written,
    );
    final updated = Uint8List.fromList(storage.files[path]!);
    expect(debugReadTitle(updated, extension: '.mp3'), '新标题');
    final frames = mp3Frames(updated);
    final audioStart = updated.length - audio.length;
    expect(updated.sublist(audioStart), audio);
    expect(frames.single.id, 'TIT2');
  });

  test('不支持的结构：v2.2 / 非同步 / 扩展头 / 压缩帧 → unsupported 且原文件不变', () async {
    final v22 = Uint8List.fromList([
      0x49, 0x44, 0x33, 2, 0, 0, 0, 0, 0, 0, //
      0x54, 0x54, 0x32, 0, 0, 0,
      ...audio,
    ]);
    storage.files[path] = v22;
    expect(
      await rewriteAudioTitle(storage: storage, filePath: path, title: 'x'),
      TagWriteOutcome.unsupported,
    );
    expect(storage.files[path], v22);

    final unsync = id3File(
      frames: [textFrame('TIT2', '旧标题')],
      audio: audio,
      flags: 0x80,
    );
    storage.files[path] = unsync;
    expect(
      await rewriteAudioTitle(storage: storage, filePath: path, title: 'x'),
      TagWriteOutcome.unsupported,
    );
    expect(storage.files[path], unsync);

    final compressed = frame('APIC', [0, ...utf8.encode('img')]);
    compressed[9] = 0x80; // v2.3 format flags: compression
    final badFrame = id3File(
      frames: [compressed, textFrame('TIT2', '旧标题')],
      audio: audio,
    );
    storage.files[path] = badFrame;
    expect(
      await rewriteAudioTitle(storage: storage, filePath: path, title: 'x'),
      TagWriteOutcome.unsupported,
    );
    expect(storage.files[path], badFrame);
  });

  test('不支持的格式与非法标题：unsupported；缺文件 fileMissing', () async {
    for (final extension in ['.m4a', '.ogg', '.wav']) {
      storage.files['/music/song$extension'] = audio;
      expect(
        await rewriteAudioTitle(
          storage: storage,
          filePath: '/music/song$extension',
          title: '标题',
        ),
        TagWriteOutcome.unsupported,
      );
    }
    storage.files[path] = audio;
    for (final title in ['', '   ', 'a\nb', 'x' * 201]) {
      expect(
        await rewriteAudioTitle(storage: storage, filePath: path, title: title),
        TagWriteOutcome.unsupported,
      );
    }
    expect(
      await rewriteAudioTitle(
        storage: storage,
        filePath: '/music/missing.mp3',
        title: '标题',
      ),
      TagWriteOutcome.fileMissing,
    );
  });

  test('写入中途失败：原文件一字节不变，临时文件清理', () async {
    final original = id3File(frames: [textFrame('TIT2', '旧标题')], audio: audio);
    storage.files[path] = original;
    final failing = _FailingWriteStorage();
    failing.files[path] = original;
    expect(
      await rewriteAudioTitle(storage: failing, filePath: path, title: '新标题'),
      TagWriteOutcome.failed,
    );
    expect(failing.files[path], original);
    expect(failing.files.keys.where((key) => key.endsWith('.tmp')), isEmpty);
  });

  group('FLAC', () {
    Uint8List block(int type, List<int> data, {required bool last}) =>
        Uint8List.fromList([
          (last ? 0x80 : 0) | type,
          (data.length >> 16) & 0xFF,
          (data.length >> 8) & 0xFF,
          data.length & 0xFF,
          ...data,
        ]);

    List<int> vorbisComment({
      required String vendor,
      required List<String> entries,
    }) {
      final builder = BytesBuilder();
      void uint32(int value) => builder.add([
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ]);

      final vendorBytes = utf8.encode(vendor);
      uint32(vendorBytes.length);
      builder.add(vendorBytes);
      uint32(entries.length);
      for (final entry in entries) {
        final bytes = utf8.encode(entry);
        uint32(bytes.length);
        builder.add(bytes);
      }
      return builder.takeBytes();
    }

    List<({int type, Uint8List data})> flacBlocks(Uint8List file) {
      final result = <({int type, Uint8List data})>[];
      var offset = 4;
      var last = false;
      while (!last) {
        last = file[offset] & 0x80 != 0;
        final type = file[offset] & 0x7F;
        final length =
            (file[offset + 1] << 16) |
            (file[offset + 2] << 8) |
            file[offset + 3];
        offset += 4;
        result.add((
          type: type,
          data: Uint8List.sublistView(file, offset, offset + length),
        ));
        offset += length;
      }
      return result;
    }

    Uint8List flacFile({
      required List<Uint8List> blocks,
      required List<int> audio,
    }) {
      final result = <int>[0x66, 0x4C, 0x61, 0x43];
      for (var i = 0; i < blocks.length; i++) {
        final copy = Uint8List.fromList(blocks[i]);
        if (i == blocks.length - 1) {
          copy[0] |= 0x80;
        } else {
          copy[0] &= 0x7F;
        }
        result.addAll(copy);
      }
      return Uint8List.fromList([...result, ...audio]);
    }

    final flacPath = '/music/song.flac';

    test('只改 TITLE：vendor、其它键、PICTURE / PADDING / SEEKTABLE 不变', () async {
      final streamInfo = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      final comment = vorbisComment(
        vendor: 'reference libFLAC',
        entries: [
          'TITLE=旧标题',
          'ARTIST=歌手 A',
          'ARTIST=歌手 B',
          'ALBUM=专辑',
          'LYRICS=歌词',
        ],
      );
      final picture = Uint8List.fromList([9, 9, 9, 9]);
      final padding = Uint8List.fromList([0, 0, 0, 0, 0]);
      final seektable = Uint8List.fromList([1, 1, 1, 1, 1, 1]);
      final original = flacFile(
        blocks: [
          block(0, streamInfo, last: false),
          block(4, comment, last: false),
          block(6, picture, last: false),
          block(1, padding, last: false),
          block(3, seektable, last: false),
        ],
        audio: audio,
      );
      storage.files[flacPath] = original;

      expect(
        await rewriteAudioTitle(
          storage: storage,
          filePath: flacPath,
          title: '新标题',
        ),
        TagWriteOutcome.written,
      );
      final updated = Uint8List.fromList(storage.files[flacPath]!);
      expect(debugReadTitle(updated, extension: '.flac'), '新标题');
      final oldBlocks = flacBlocks(original);
      final newBlocks = flacBlocks(updated);
      expect(newBlocks.map((block) => block.type), [0, 4, 6, 1, 3]);
      expect(newBlocks[0].data, oldBlocks[0].data);
      expect(newBlocks[2].data, picture);
      expect(newBlocks[3].data, padding);
      expect(newBlocks[4].data, seektable);
      final commentText = utf8.decode(newBlocks[1].data);
      expect(commentText, contains('ARTIST=歌手 A'));
      expect(commentText, contains('ARTIST=歌手 B'));
      expect(commentText, contains('ALBUM=专辑'));
      expect(commentText, contains('LYRICS=歌词'));
      expect(commentText, contains('reference libFLAC'));
      expect(commentText, contains('TITLE=新标题'));
      expect(commentText, isNot(contains('TITLE=旧标题')));
      final audioStart = updated.length - audio.length;
      expect(updated.sublist(audioStart), audio);
    });

    test('重复 TITLE 保留数量与顺序；非 UTF-8 条目逐字节不变', () async {
      final streamInfo = Uint8List.fromList([1, 2, 3, 4]);
      // 手工构造：vendor + 两个 TITLE + 非法 UTF-8 键的条目 + ARTIST。
      final builder = BytesBuilder();
      void uint32(int value) => builder.add([
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ]);

      final vendor = utf8.encode('vendor');
      uint32(vendor.length);
      builder.add(vendor);
      final entries = <List<int>>[
        utf8.encode('TITLE=旧一'),
        utf8.encode('ARTIST=歌手'),
        [0xFF, 0xFE, 0x3D, 0x31], // 非法 UTF-8 键
        utf8.encode('TITLE=旧二'),
      ];
      uint32(entries.length);
      for (final entry in entries) {
        uint32(entry.length);
        builder.add(entry);
      }
      final comment = builder.takeBytes();
      final original = flacFile(
        blocks: [
          block(0, streamInfo, last: false),
          block(4, comment, last: false),
        ],
        audio: audio,
      );
      storage.files[flacPath] = original;
      expect(
        await rewriteAudioTitle(
          storage: storage,
          filePath: flacPath,
          title: '新标题',
        ),
        TagWriteOutcome.written,
      );
      final updated = Uint8List.fromList(storage.files[flacPath]!);
      final commentBlock = flacBlocks(updated)[1].data;
      final text = utf8.decode(commentBlock, allowMalformed: true);
      expect(text, contains('TITLE=新标题'));
      expect(text, isNot(contains('TITLE=旧一')));
      expect(text, isNot(contains('TITLE=旧二')));
      expect('TITLE='.allMatches(text), hasLength(2), reason: '重复 TITLE 保留');
      // 非法 UTF-8 条目字节原样保留（从注释块中直接找字节序列）。
      expect(_containsBytes(commentBlock, [0xFF, 0xFE, 0x3D, 0x31]), isTrue);
      expect(String.fromCharCodes(_titleValues(commentBlock)), contains('AR'));
    });

    test('没有 Vorbis Comment：在 STREAMINFO 后插入只含 TITLE 的块', () async {
      final streamInfo = Uint8List.fromList([1, 2, 3, 4]);
      final original = flacFile(
        blocks: [
          block(0, streamInfo, last: false),
          block(1, Uint8List.fromList([0, 0]), last: false),
        ],
        audio: audio,
      );
      storage.files[flacPath] = original;
      expect(
        await rewriteAudioTitle(
          storage: storage,
          filePath: flacPath,
          title: '新标题',
        ),
        TagWriteOutcome.written,
      );
      final updated = Uint8List.fromList(storage.files[flacPath]!);
      final blocks = flacBlocks(updated);
      expect(blocks.map((block) => block.type), [0, 4, 1]);
      expect(debugReadTitle(updated, extension: '.flac'), '新标题');
      expect(updated.sublist(updated.length - audio.length), audio);
    });

    test('损坏 / 截断的 FLAC → unsupported 且原文件不变', () async {
      final broken = Uint8List.fromList([0x66, 0x4C, 0x61, 0x43, 0x00]);
      storage.files[flacPath] = broken;
      expect(
        await rewriteAudioTitle(
          storage: storage,
          filePath: flacPath,
          title: '新标题',
        ),
        TagWriteOutcome.unsupported,
      );
      expect(storage.files[flacPath], broken);
    });
  });
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

List<int> _titleValues(List<int> comment) {
  var cursor = 0;
  int readUint32() {
    final value =
        comment[cursor] |
        (comment[cursor + 1] << 8) |
        (comment[cursor + 2] << 16) |
        (comment[cursor + 3] << 24);
    cursor += 4;
    return value;
  }

  final vendorLength = readUint32();
  cursor += vendorLength;
  final count = readUint32();
  final values = <int>[];
  for (var i = 0; i < count; i++) {
    final length = readUint32();
    final entry = comment.sublist(cursor, cursor + length);
    cursor += length;
    values.addAll(entry);
  }
  return values;
}

class _FailingWriteStorage extends FakeDownloadStorage {
  @override
  Future<void> writeStream(
    String path,
    Stream<List<int>> stream, {
    int? total,
    void Function(int received, int? total)? onProgress,
  }) async {
    throw const FileSystemException('disk full');
  }
}
