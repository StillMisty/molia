/// 本地导入的音频标签解析：MP3（ID3v2.2/2.3/2.4）与 FLAC（Vorbis Comment）。
///
/// 与 `audio_tag_writer.dart` 同一取舍：只覆盖本地音乐最常见的两种格式，
/// 不引入 FFI / TagLib 依赖；其余格式（m4a / ogg / wav…）返回空结果，由
/// 调用方按文件名兜底。
///
/// 只吃文件头部字节（[kAudioTagReadLimit]），不整文件读入；时长同理：
/// FLAC 用 STREAMINFO 精确解析，MP3 优先 Xing/Info 帧数、否则按首帧码率
/// 估算（CBR 常见，VBR 无 Xing 时会偏）。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// 标签读取的头部字节上限：ID3v2 标签可能内嵌大封面，留足空间。
const int kAudioTagReadLimit = 512 * 1024;

/// 解析结果（空值一律为 null，UI 按缺失处理）。
class AudioTagInfo {
  const AudioTagInfo({this.title, this.artist, this.album, this.durationMs});

  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;

  bool get isEmpty =>
      title == null &&
      artist == null &&
      album == null &&
      durationMs == null;
}

/// 解析音频头部字节；[extension] 为小写后缀（含点，如 `.mp3`）。
///
/// [fileSize] 用于 MP3 CBR 时长估算（头部缓冲区不含文件尾）。
/// 任何解析异常都归一为「无标签」，导入流程不因坏文件中断。
AudioTagInfo readAudioTags(
  Uint8List head, {
  required String extension,
  required int fileSize,
}) {
  if (head.isEmpty) return const AudioTagInfo();
  try {
    return switch (extension.toLowerCase()) {
      '.mp3' => _readMp3(head, fileSize: fileSize),
      '.flac' => _readFlac(head),
      _ => const AudioTagInfo(),
    };
  } catch (_) {
    return const AudioTagInfo();
  }
}

/// 文件名兜底元数据：`歌手 - 歌名`（首个 ` - ` 分隔）拆出歌手；
/// 无分隔 / 分隔在开头时整名作歌名，歌手留空。
({String title, String artist}) splitFileNameMetadata(String baseName) {
  final name = baseName.trim();
  final index = name.indexOf(' - ');
  if (index <= 0) return (title: name, artist: '');
  final artist = name.substring(0, index).trim();
  final title = name.substring(index + 3).trim();
  if (title.isEmpty) return (title: name, artist: '');
  return (title: title, artist: artist);
}

AudioTagInfo _readMp3(Uint8List bytes, {required int fileSize}) {
  final tag = _readId3v2(bytes);
  final durationMs = _mp3DurationMs(
    bytes,
    audioStart: tag.audioStart,
    fileSize: fileSize,
  );
  return AudioTagInfo(
    title: tag.title,
    artist: tag.artist,
    album: tag.album,
    durationMs: durationMs,
  );
}

({String? title, String? artist, String? album, int audioStart}) _readId3v2(
  Uint8List bytes,
) {
  const empty = (title: null, artist: null, album: null, audioStart: 0);
  if (bytes.length < 10 ||
      bytes[0] != 0x49 || // 'I'
      bytes[1] != 0x44 || // 'D'
      bytes[2] != 0x33) {
    // '3'
    return empty;
  }
  final version = bytes[3];
  final flags = bytes[5];
  final tagSize = _synchsafe(bytes, 6);
  final hasFooter = flags & 0x10 != 0;
  final audioStart = 10 + tagSize + (hasFooter ? 10 : 0);
  final tagEnd = math.min(10 + tagSize, bytes.length);

  String? title;
  String? artist;
  String? album;
  var offset = 10;
  if (version == 2) {
    // v2.2：3 字节帧 id + 3 字节长度。
    while (offset + 6 <= tagEnd) {
      final id = String.fromCharCodes(bytes, offset, offset + 3);
      final frameSize = (bytes[offset + 3] << 16) |
          (bytes[offset + 4] << 8) |
          bytes[offset + 5];
      if (id.codeUnits.every((unit) => unit == 0) || frameSize <= 0) break;
      final text = _decodeTextFrame(bytes, offset + 6, frameSize);
      switch (id) {
        case 'TT2':
          title ??= text;
        case 'TP1':
          artist ??= text;
        case 'TAL':
          album ??= text;
      }
      offset += 6 + frameSize;
    }
  } else {
    // v2.3 / v2.4：4 字节帧 id + 4 字节长度（v2.4 为 synchsafe）。
    while (offset + 10 <= tagEnd) {
      final id = String.fromCharCodes(bytes, offset, offset + 4);
      if (id.codeUnits.every((unit) => unit == 0)) break; // 填充区
      final frameSize = version >= 4
          ? _synchsafe(bytes, offset + 4)
          : _be32(bytes, offset + 4);
      if (frameSize <= 0) break;
      final text = _decodeTextFrame(bytes, offset + 10, frameSize);
      switch (id) {
        case 'TIT2':
          title ??= text;
        case 'TPE1':
          artist ??= text;
        case 'TALB':
          album ??= text;
      }
      offset += 10 + frameSize;
    }
  }
  return (title: title, artist: artist, album: album, audioStart: audioStart);
}

/// 文本帧：首字节为编码（0=latin1 / 1=UTF-16+BOM / 2=UTF-16BE / 3=UTF-8），
/// 多值与结尾 NUL 只取第一段。
String? _decodeTextFrame(Uint8List bytes, int start, int length) {
  final end = math.min(start + length, bytes.length);
  if (start + 1 > end) return null;
  final encoding = bytes[start];
  final body = Uint8List.sublistView(bytes, start + 1, end);
  final text = switch (encoding) {
    0 => latin1.decode(body, allowInvalid: true),
    1 => _decodeUtf16(body),
    2 => _decodeUtf16(body, bigEndian: true),
    3 => utf8.decode(body, allowMalformed: true),
    _ => '',
  };
  final first = text.split('\u0000').first.trim();
  return first.isEmpty ? null : first;
}

/// UTF-16 解码：可选 BOM 决定字节序（无 BOM 时按参数），忽略结尾 NUL。
String _decodeUtf16(Uint8List bytes, {bool bigEndian = false}) {
  var start = 0;
  var be = bigEndian;
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    start = 2;
  } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    start = 2;
    be = true;
  }
  final units = <int>[];
  for (var i = start; i + 2 <= bytes.length; i += 2) {
    units.add(be ? (bytes[i] << 8) | bytes[i + 1] : bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

/// MP3 时长：首帧码率 + Xing/Info 帧数（VBR 精确）或 CBR 估算。
int? _mp3DurationMs(
  Uint8List bytes, {
  required int audioStart,
  required int fileSize,
}) {
  final frame = _firstMp3Frame(bytes, audioStart);
  if (frame == null) return null;
  final padding = (bytes[frame.headerOffset + 2] >> 1) & 0x1;
  final frameSize = _layer3FrameSize(
    samplesPerFrame: frame.samplesPerFrame,
    bitrateBps: frame.bitrateBps,
    sampleRate: frame.sampleRate,
    padding: padding,
  );

  // Xing / Info 头（首帧内的帧数，VBR 精确）。
  final searchEnd = math.min(frame.headerOffset + frameSize, bytes.length);
  for (var i = frame.headerOffset + 4; i + 12 <= searchEnd; i++) {
    final isXing = bytes[i] == 0x58 && bytes[i + 1] == 0x69 && bytes[i + 2] == 0x6E;
    final isInfo = bytes[i] == 0x49 && bytes[i + 1] == 0x6E && bytes[i + 2] == 0x66;
    if (!isXing && !isInfo) continue;
    final flags = _be32(bytes, i + 4);
    if (flags & 0x1 == 0) break;
    final frames = _be32(bytes, i + 8);
    if (frames > 0) {
      return (frames * frame.samplesPerFrame * 1000 / frame.sampleRate).round();
    }
    break;
  }

  // CBR 估算：音频字节数 × 8 / 码率。
  final audioBytes = fileSize - audioStart;
  if (audioBytes <= 0 || frame.bitrateBps <= 0) return null;
  return (audioBytes * 8 * 1000 / frame.bitrateBps).round();
}

/// 首个 MPEG 帧头信息；非 Layer III / 保留值 / 找不到同步字返回 null。
({int headerOffset, int sampleRate, int samplesPerFrame, int bitrateBps})?
    _firstMp3Frame(Uint8List bytes, int audioStart) {
  var i = audioStart;
  while (i + 4 <= bytes.length) {
    if (bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0) {
      final version = (bytes[i + 1] >> 3) & 0x3; // 0=2.5 / 2=2 / 3=1
      final layer = (bytes[i + 1] >> 1) & 0x3; // 1=Layer III
      final bitrateIndex = (bytes[i + 2] >> 4) & 0xF;
      final sampleRateIndex = (bytes[i + 2] >> 2) & 0x3;
      if (version != 1 &&
          layer == 1 &&
          bitrateIndex > 0 &&
          bitrateIndex < 0xF &&
          sampleRateIndex != 3) {
        final mpeg1 = version == 3;
        final sampleRates = switch (version) {
          3 => const [44100, 48000, 32000],
          2 => const [22050, 24000, 16000],
          _ => const [11025, 12000, 8000],
        };
        const v1Bitrates = [
          0, 32000, 40000, 48000, 56000, 64000, 80000, 96000,
          112000, 128000, 160000, 192000, 224000, 256000, 320000, 0,
        ];
        const v2Bitrates = [
          0, 8000, 16000, 24000, 32000, 40000, 48000, 56000,
          64000, 80000, 96000, 112000, 128000, 144000, 160000, 0,
        ];
        return (
          headerOffset: i,
          sampleRate: sampleRates[sampleRateIndex],
          // MPEG1 Layer III = 1152 采样 / 帧；MPEG2 / 2.5 = 576。
          samplesPerFrame: mpeg1 ? 1152 : 576,
          bitrateBps: (mpeg1 ? v1Bitrates : v2Bitrates)[bitrateIndex],
        );
      }
    }
    i++;
  }
  return null;
}

/// Layer III 帧长（字节）；slot 对齐见 ISO 11172-3。
int _layer3FrameSize({
  required int samplesPerFrame,
  required int bitrateBps,
  required int sampleRate,
  required int padding,
}) {
  if (sampleRate <= 0) return 0;
  return (samplesPerFrame ~/ 8) * bitrateBps ~/ sampleRate + padding;
}

AudioTagInfo _readFlac(Uint8List bytes) {
  if (bytes.length < 4 ||
      bytes[0] != 0x66 || // 'f'
      bytes[1] != 0x4C || // 'L'
      bytes[2] != 0x61 || // 'a'
      bytes[3] != 0x43) {
    // 'C'
    return const AudioTagInfo();
  }
  String? title;
  String? artist;
  String? album;
  int? durationMs;
  var offset = 4;
  while (offset + 4 <= bytes.length) {
    final header = bytes[offset];
    final isLast = header & 0x80 != 0;
    final type = header & 0x7F;
    final length = (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final start = offset + 4;
    final end = start + length;
    if (end > bytes.length) break; // 头部缓冲区被截断
    if (type == 0) {
      durationMs = _flacDurationMs(bytes, start, end);
    } else if (type == 4) {
      final comments = _readVorbisComments(bytes, start, end);
      title ??= comments['TITLE'];
      artist ??= comments['ARTIST'];
      album ??= comments['ALBUM'];
    }
    if (isLast || type == 127) break;
    offset = end;
  }
  return AudioTagInfo(
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
  );
}

/// STREAMINFO：20 位采样率 + 36 位总采样数 → 精确时长。
int? _flacDurationMs(Uint8List bytes, int start, int end) {
  if (end - start < 34) return null;
  // 块内偏移 10：min/max block(2+2) + min/max frame(3+3) 之后。
  final b = start + 10;
  final sampleRate = (bytes[b] << 12) | (bytes[b + 1] << 4) | (bytes[b + 2] >> 4);
  if (sampleRate <= 0) return null;
  final totalSamples = ((bytes[b + 3] & 0x0F) << 32) |
      (bytes[b + 4] << 24) |
      (bytes[b + 5] << 16) |
      (bytes[b + 6] << 8) |
      bytes[b + 7];
  if (totalSamples <= 0) return null;
  return (totalSamples * 1000 / sampleRate).round();
}

/// Vorbis Comment（小端）：vendor + `KEY=value`（键大写，取首个）。
Map<String, String> _readVorbisComments(Uint8List bytes, int start, int end) {
  final result = <String, String>{};
  var offset = start;
  if (offset + 4 > end) return result;
  final vendorLength = _le32(bytes, offset);
  offset += 4;
  if (vendorLength < 0 || offset + vendorLength + 4 > end) return result;
  offset += vendorLength;
  final count = _le32(bytes, offset);
  offset += 4;
  for (var i = 0; i < count && offset + 4 <= end; i++) {
    final length = _le32(bytes, offset);
    offset += 4;
    if (length < 0 || offset + length > end) break;
    final entry = utf8.decode(
      Uint8List.sublistView(bytes, offset, offset + length),
      allowMalformed: true,
    );
    offset += length;
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    final key = entry.substring(0, eq).toUpperCase();
    final value = entry.substring(eq + 1).trim();
    if (value.isNotEmpty) result.putIfAbsent(key, () => value);
  }
  return result;
}

int _be32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _le32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

/// ID3v2 同步安全整数（每字节 7 位）。
int _synchsafe(Uint8List bytes, int offset) =>
    ((bytes[offset] & 0x7F) << 21) |
    ((bytes[offset + 1] & 0x7F) << 14) |
    ((bytes[offset + 2] & 0x7F) << 7) |
    (bytes[offset + 3] & 0x7F);
