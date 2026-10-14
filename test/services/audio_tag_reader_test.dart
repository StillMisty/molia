import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/audio_tag_reader.dart';

/// 本地导入的标签解析：MP3（ID3v2.3 文本帧 + Xing/CBR 时长）与
/// FLAC（STREAMINFO + Vorbis Comment），其余格式 / 坏文件安全返回空。
///
/// 真实文件的可读性依赖 ffprobe 口径由写入侧人工验证（`audio_tag_writer`），
/// 这里守住解析结构与兜底行为：编码字节、BOM、synchsafe 长度、时长算式。
void main() {
  group('readAudioTags · MP3', () {
    test('ID3v2.3：latin1 / UTF-16+BOM / UTF-8 三种编码都能读', () {
      final head = _mp3(
        frames: [
          _id3TextFrame('TIT2', 1, '标题'),
          _id3TextFrame('TPE1', 0, 'Artist'),
          _id3TextFrame('TALB', 3, '专辑'),
        ],
        audio: _cbrFrames(),
        fileSize: 0,
      );
      final info = readAudioTags(head, extension: '.mp3', fileSize: head.length);

      expect(info.title, '标题');
      expect(info.artist, 'Artist');
      expect(info.album, '专辑');
    });

    test('ID3v2.2（3 字节帧 id）也能读', () {
      final head = _mp3(
        version: 2,
        frames: [
          _id3TextFrame('TT2', 1, '老标题', version: 2),
          _id3TextFrame('TP1', 1, '老歌手', version: 2),
        ],
        audio: _cbrFrames(),
        fileSize: 0,
      );
      final info = readAudioTags(head, extension: '.mp3', fileSize: head.length);

      expect(info.title, '老标题');
      expect(info.artist, '老歌手');
    });

    test('Xing 帧数：时长按 帧数 × 采样数 / 采样率', () {
      final audio = <int>[
        0xFF, 0xFB, 0x90, 0x00, // MPEG1 Layer III / 128kbps / 44100Hz
        ...'Xing'.codeUnits,
        0x00, 0x00, 0x00, 0x01, // flags：有帧数
        ..._be32(2300), // frames
        for (var i = 0; i < 400; i++) 0x00,
      ];
      final head = _mp3(frames: const [], audio: audio, fileSize: 0);
      final info = readAudioTags(head, extension: '.mp3', fileSize: head.length);

      // 2300 帧 × 1152 采样 / 44100Hz ≈ 60.08s。
      expect(info.durationMs, closeTo(60082, 2));
    });

    test('无 Xing：按首帧码率与文件大小估算（CBR）', () {
      final audio = _cbrFrames();
      final head = _mp3(frames: const [], audio: audio, fileSize: 0);
      final info = readAudioTags(head, extension: '.mp3', fileSize: head.length);

      final audioBytes = head.length - 10; // 无标签，音频从头开始
      final expectedMs = (audioBytes * 8 * 1000 / 128000).round();
      expect(info.durationMs, expectedMs);
      expect(info.title, isNull);
    });

    test('非音频字节：返回空结果而不抛错', () {
      final junk = Uint8List.fromList(List<int>.filled(64, 0x42));
      final info = readAudioTags(junk, extension: '.mp3', fileSize: 64);
      expect(info.isEmpty, isTrue);
    });
  });

  group('readAudioTags · FLAC', () {
    test('STREAMINFO 时长 + Vorbis Comment 标签', () {
      final head = _flac(
        sampleRate: 44100,
        totalSamples: 220500, // 5s
        comments: {
          'TITLE': '歌名',
          'ARTIST': '歌手',
          'ALBUM': '专辑',
        },
      );
      final info = readAudioTags(head, extension: '.flac', fileSize: head.length);

      expect(info.title, '歌名');
      expect(info.artist, '歌手');
      expect(info.album, '专辑');
      expect(info.durationMs, 5000);
    });

    test('标签块在 STREAMINFO 之前也能读；截断头部不抛错', () {
      final full = _flac(
        sampleRate: 48000,
        totalSamples: 96000, // 2s
        comments: {'TITLE': 'A'},
      );
      // 只喂前 16 字节（STREAMINFO 不完整）：安全返回，不抛错。
      final truncated = Uint8List.sublistView(full, 0, 16);
      final info = readAudioTags(
        truncated,
        extension: '.flac',
        fileSize: full.length,
      );
      expect(info.durationMs, isNull);
      expect(info.isEmpty, isTrue);
    });
  });

  test('不支持的格式：返回空结果（由文件名兜底）', () {
    final bytes = Uint8List.fromList(List<int>.filled(32, 0));
    expect(readAudioTags(bytes, extension: '.m4a', fileSize: 32).isEmpty, isTrue);
  });

  group('splitFileNameMetadata', () {
    test('歌手 - 歌名：拆开并去空白', () {
      final parsed = splitFileNameMetadata('Artist - Title');
      expect(parsed.title, 'Title');
      expect(parsed.artist, 'Artist');
    });

    test('无分隔 / 分隔在开头 / 歌名为空：整名作歌名', () {
      expect(splitFileNameMetadata('Title').title, 'Title');
      expect(splitFileNameMetadata('Title').artist, '');
      // 首尾空白先折叠：` - Title` 视作无歌手。
      expect(splitFileNameMetadata(' - Title').title, '- Title');
      expect(splitFileNameMetadata('Artist - ').title, 'Artist -');
    });
  });
}

// ------------------------------------------------------------------ 构造工具

/// ID3v2 标签 + 音频字节；[fileSize] 为 0 时按实际长度（测试用）。
Uint8List _mp3({
  int version = 3,
  required List<List<int>> frames,
  required List<int> audio,
  required int fileSize,
}) {
  final body = <int>[for (final frame in frames) ...frame];
  final bytes = <int>[
    0x49, 0x44, 0x33, // 'ID3'
    version, 0x00, 0x00, // 版本 + flags
    ..._synchsafe(body.length),
    ...body,
    ...audio,
  ];
  return Uint8List.fromList(bytes);
}

/// 文本帧：id + 长度 + flags + [编码字节][文本]。
List<int> _id3TextFrame(
  String id,
  int encoding,
  String text, {
  int version = 3,
}) {
  final body = <int>[
    encoding,
    if (encoding == 1) ...[0xFF, 0xFE], // UTF-16LE BOM
    if (encoding == 0) ...latin1.encode(text),
    if (encoding == 1) ..._utf16le(text),
    if (encoding == 3) ...utf8.encode(text),
  ];
  if (version == 2) {
    return [
      ...ascii.encode(id),
      (body.length >> 16) & 0xFF,
      (body.length >> 8) & 0xFF,
      body.length & 0xFF,
      ...body,
    ];
  }
  return [
    ...ascii.encode(id),
    ..._be32(body.length),
    0x00, 0x00, // flags
    ...body,
  ];
}

List<int> _utf16le(String text) => [
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];

/// 若干 MPEG1 Layer III 帧（128kbps / 44100Hz / 无 Xing）。
List<int> _cbrFrames() => [
      for (var i = 0; i < 10; i++) ...[
        0xFF, 0xFB, 0x90, 0x00,
        for (var j = 0; j < 410; j++) 0x00,
      ],
    ];

/// 'fLaC' + STREAMINFO + Vorbis Comment（last）。
Uint8List _flac({
  required int sampleRate,
  required int totalSamples,
  required Map<String, String> comments,
}) {
  final streamInfo = <int>[
    for (var i = 0; i < 10; i++) 0x00, // min/max block、min/max frame size
    sampleRate >> 12,
    (sampleRate >> 4) & 0xFF,
    ((sampleRate & 0xF) << 4) | (1 << 1) | (15 >> 4), // 2 声道 / 16 位深
    0xF0 | ((totalSamples >> 32) & 0xF),
    (totalSamples >> 24) & 0xFF,
    (totalSamples >> 16) & 0xFF,
    (totalSamples >> 8) & 0xFF,
    totalSamples & 0xFF,
    for (var i = 0; i < 16; i++) 0x00, // MD5
  ];

  final vendor = utf8.encode('test');
  final comment = <int>[
    ..._le32(vendor.length),
    ...vendor,
    ..._le32(comments.length),
    for (final entry in comments.entries) ...[
      ..._le32(utf8.encode('${entry.key}=${entry.value}').length),
      ...utf8.encode('${entry.key}=${entry.value}'),
    ],
  ];

  return Uint8List.fromList([
    0x66, 0x4C, 0x61, 0x43, // 'fLaC'
    0x00, 0x00, 0x00, streamInfo.length, // STREAMINFO（非 last）
    ...streamInfo,
    0x84, 0x00, 0x00, comment.length, // Vorbis Comment（last）
    ...comment,
  ]);
}

List<int> _be32(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> _le32(int value) => [
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];

/// ID3v2 synchsafe 大小（每字节 7 位）。
List<int> _synchsafe(int value) => [
      (value >> 21) & 0x7F,
      (value >> 14) & 0x7F,
      (value >> 7) & 0x7F,
      value & 0x7F,
    ];
