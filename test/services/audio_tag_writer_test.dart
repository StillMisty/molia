import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/audio_tag_writer.dart';

import '../support/fake_download_storage.dart';

/// 标签写入：MP3（ID3v2.3）与 FLAC（Vorbis Comment + PICTURE）的结构断言。
///
/// 真实可读性用 `ffprobe` 人工验证（`title/artist/album/lyrics` 与
/// `attached_pic` 均可读）；这里守住结构不回归：帧标记、BOM、音频数据保留、
/// 重复写入不叠加标签、不支持格式返回 false。
List<int> syntheticMp3() => <int>[
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      for (var i = 0; i < 20; i++) ...[
        0xFF, 0xFB, 0x90, 0x00,
        for (var j = 0; j < 400; j++) 0x00,
      ],
    ];

List<int> syntheticFlac() => <int>[
      0x66, 0x4C, 0x61, 0x43, // 'fLaC'
      0x80, 0x00, 0x00, 0x22, // STREAMINFO（last），长度 34
      for (var i = 0; i < 34; i++) 0x00,
      for (var i = 0; i < 200; i++) 0xAA,
    ];

String ascii(List<int> bytes) =>
    String.fromCharCodes(bytes.where((b) => b >= 32 && b < 127));

void main() {
  late FakeDownloadStorage storage;

  setUp(() {
    storage = FakeDownloadStorage();
  });

  Future<bool> embed(
    String path, {
    String? lyrics = '[00:01.00]第一行',
    List<int>? cover,
  }) async {
    storage.files[path] = Uint8List.fromList(
      path.endsWith('.flac') ? syntheticFlac() : syntheticMp3(),
    );
    return embedDownloadTags(
      storage: storage,
      filePath: path,
      title: 'Title',
      artist: 'Artist 艺术家',
      album: 'Album',
      lyrics: lyrics,
      coverBytes: cover == null ? null : Uint8List.fromList(cover),
    );
  }

  test('MP3：写入 ID3v2.3 文本 / USLT / APIC，音频数据保留', () async {
    const path = '/downloads/a.mp3';
    final ok = await embed(path, cover: [9, 9, 9]);
    expect(ok, isTrue);

    final bytes = storage.files[path]!;
    expect(ascii(bytes).startsWith('ID3'), isTrue);
    expect(ascii(bytes).contains('TIT2'), isTrue);
    expect(ascii(bytes).contains('TPE1'), isTrue);
    expect(ascii(bytes).contains('TALB'), isTrue);
    expect(ascii(bytes).contains('USLT'), isTrue);
    expect(ascii(bytes).contains('APIC'), isTrue);
    // UTF-16LE + BOM（ID3v2.3 的中文安全编码）。
    expect(bytes.contains(0xFF), isTrue);
    // 音频数据（0xFF 0xFB 帧头序列）仍在标签之后。
    expect(_containsSequence(bytes, const [0xFF, 0xFB, 0x90, 0x00]), isTrue);
    // 临时文件不残留。
    expect(storage.files.containsKey('$path.part'), isFalse);
  });

  test('MP3：重复写入不叠加 ID3 标签', () async {
    const path = '/downloads/a.mp3';
    await embed(path);
    final first = storage.files[path]!;
    final firstSize = first.length;
    await embed(path);
    final second = storage.files[path]!;
    expect(second.length, firstSize);
    expect(ascii(second).indexOf('ID3'), ascii(second).lastIndexOf('ID3'));
  });

  test('FLAC：Vorbis Comment + PICTURE 块，STREAMINFO 保留在首位', () async {
    const path = '/downloads/a.flac';
    final ok = await embed(path, cover: [7, 7, 7]);
    expect(ok, isTrue);

    final bytes = storage.files[path]!;
    final utf8Text = utf8.decode(bytes, allowMalformed: true);
    expect(ascii(bytes).startsWith('fLaC'), isTrue);
    expect(utf8Text.contains('TITLE=Title'), isTrue);
    expect(utf8Text.contains('ARTIST=Artist 艺术家'), isTrue);
    expect(utf8Text.contains('ALBUM=Album'), isTrue);
    expect(utf8Text.contains('LYRICS='), isTrue);
    // STREAMINFO 类型位仍在第一个块（块头低 7 位 = 0）。
    expect(bytes[4] & 0x7F, 0);
    // 原始音频尾部（0xAA 填充）保留。
    expect(bytes.last, 0xAA);
  });

  test('不支持格式：返回 false（sidecar 保留）', () async {
    const path = '/downloads/a.m4a';
    final ok = await embed(path);
    expect(ok, isFalse);
    // 文件不被改写。
    expect(storage.files[path], Uint8List.fromList(syntheticMp3()));
  });

  test('无歌词 / 无封面：仅文本帧', () async {
    const path = '/downloads/a.mp3';
    final ok = await embed(path, lyrics: null);
    expect(ok, isTrue);
    final text = ascii(storage.files[path]!);
    expect(text.contains('TIT2'), isTrue);
    expect(text.contains('USLT'), isFalse);
    expect(text.contains('APIC'), isFalse);
  });

  test('UTF-16 编码：中文以 UTF-16LE 字节写入', () async {
    const path = '/downloads/a.mp3';
    await embed(path);
    final bytes = storage.files[path]!;
    // '艺' = U+827A → 7A 82（UTF-16LE）。
    expect(
      _containsSequence(bytes, const [0x7A, 0x82]),
      isTrue,
      reason: '中文应写成 UTF-16LE 码元',
    );
    expect(
      _containsSequence(bytes, utf8.encode('艺术家')),
      isFalse,
      reason: '不应写 UTF-8 中文（ID3v2.3 文本帧）',
    );
  });
}

bool _containsSequence(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
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
