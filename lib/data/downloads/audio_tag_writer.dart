/// 下载完成后的音频标签写入：标题 / 歌手 / 专辑 / 歌词 / 封面。
///
/// **为什么自写而不是用包**：`phonic` 等纯 Dart 包写出的 ID3 文本帧编码
/// 不自洽（声明 UTF-16 却写无 BOM 的 UTF-16LE），ffmpeg/ffprobe 直接跳过
/// 帧；FFI/TagLib 绑定又会引入原生构建链。这里只覆盖下载最常见的两种格式，
/// 帧结构按规范手写，用 ffprobe 验证：
/// - **MP3**：ID3v2.3（UTF-16LE + BOM 文本、USLT 歌词、APIC 封面）；
/// - **FLAC**：Vorbis Comment（TITLE/ARTIST/ALBUM/LYRICS）+ PICTURE 块。
///
/// 其余格式（m4a / ogg / wav…）与写入失败都返回 false——sidecar 文件
/// （`.lrc` / 封面图）仍然保留，下载结果不受影响。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'download_storage.dart';

final _logger = Logger('molia.audio_tag_writer');

/// 把下载元数据写入音频文件标签；不支持 / 失败返回 false。
Future<bool> embedDownloadTags({
  required DownloadStorage storage,
  required String filePath,
  required String title,
  required String artist,
  required String album,
  String? lyrics,
  Uint8List? coverBytes,
  String coverMimeType = 'image/jpeg',
}) async {
  final extension = p.extension(filePath).toLowerCase();
  final existing = await storage.readBytes(filePath);
  if (existing == null || existing.isEmpty) return false;
  final text = lyrics?.trim();
  try {
    final Uint8List? rewritten = switch (extension) {
      '.mp3' => _writeId3v23(
          existing,
          title: title,
          artist: artist,
          album: album,
          lyrics: (text == null || text.isEmpty) ? null : text,
          coverBytes: coverBytes,
          coverMimeType: coverMimeType,
        ),
      '.flac' => _writeFlacComments(
          existing,
          title: title,
          artist: artist,
          album: album,
          lyrics: (text == null || text.isEmpty) ? null : text,
          coverBytes: coverBytes,
          coverMimeType: coverMimeType,
        ),
      _ => null,
    };
    if (rewritten == null) return false;
    // 原子替换：先写同目录临时文件再改名，避免写坏已完成的下载文件。
    final tempPath = '$filePath$downloadPartSuffix';
    await storage.writeBytes(tempPath, rewritten);
    await storage.rename(tempPath, filePath);
    return true;
  } catch (e) {
    _logger.warning('音频标签写入失败（保留 sidecar）: $e');
    return false;
  }
}

// ---------------------------------------------------------------- MP3 / ID3v2.3

/// 写入 ID3v2.3 标签并前置到音频数据之前（替换已有 ID3v2 标签）。
Uint8List _writeId3v23(
  Uint8List file, {
  required String title,
  required String artist,
  required String album,
  required String? lyrics,
  required Uint8List? coverBytes,
  required String coverMimeType,
}) {
  final audio = _stripId3v2(file);
  final frames = BytesBuilder();
  if (title.isNotEmpty) frames.add(_id3TextFrame('TIT2', title));
  if (artist.isNotEmpty) frames.add(_id3TextFrame('TPE1', artist));
  if (album.isNotEmpty) frames.add(_id3TextFrame('TALB', album));
  if (lyrics != null) frames.add(_id3UsltFrame(lyrics));
  if (coverBytes != null && coverBytes.isNotEmpty) {
    frames.add(_id3ApicFrame(coverBytes, coverMimeType));
  }
  final framesBytes = frames.takeBytes();
  final header = BytesBuilder()
    ..add(const [0x49, 0x44, 0x33]) // 'ID3'
    ..add(const [0x03, 0x00]) // v2.3, revision 0
    ..addByte(0x00) // flags：无 unsynchronisation / extended header
    ..add(_syncSafe(framesBytes.length));
  final out = BytesBuilder()
    ..add(header.takeBytes())
    ..add(framesBytes)
    ..add(audio);
  return out.takeBytes();
}

/// 去掉文件开头的 ID3v2 标签（若存在），返回纯音频数据。
Uint8List _stripId3v2(Uint8List file) {
  if (file.length < 10) return file;
  if (file[0] != 0x49 || file[1] != 0x44 || file[2] != 0x33) return file;
  final size = (file[6] & 0x7F) << 21 |
      (file[7] & 0x7F) << 14 |
      (file[8] & 0x7F) << 7 |
      (file[9] & 0x7F);
  final total = 10 + size;
  if (total >= file.length) return Uint8List(0);
  return Uint8List.sublistView(file, total);
}

/// ID3v2.3 文本帧：UTF-16LE + BOM（中文安全；v2.3 不支持 UTF-8）。
Uint8List _id3TextFrame(String id, String text) {
  final payload = BytesBuilder()..addByte(0x01);
  payload.add(_utf16WithBom(text));
  return _id3Frame(id, payload.takeBytes());
}

/// USLT（非同步歌词）：编码 + 语言 + 内容描述 + 歌词文本。
Uint8List _id3UsltFrame(String lyrics) {
  final payload = BytesBuilder()
    ..addByte(0x01)
    ..add(const [0x58, 0x58, 0x58]) // 'XXX'：语言未指定
    ..add(_utf16WithBom('')); // 内容描述（空）
  payload.add(_utf16WithBom(lyrics));
  return _id3Frame('USLT', payload.takeBytes());
}

/// APIC（封面）：编码 + MIME + 类型 + 描述 + 图片字节。
Uint8List _id3ApicFrame(Uint8List image, String mimeType) {
  final payload = BytesBuilder()
    ..addByte(0x00) // ISO-8859-1（MIME / 描述都是 ASCII）
    ..add(utf8.encode(mimeType))
    ..addByte(0x00)
    ..addByte(0x03) // 类型：front cover
    ..addByte(0x00) // 描述（空）
    ..add(image);
  return _id3Frame('APIC', payload.takeBytes());
}

/// 帧头（v2.3：4 字节 id + 4 字节 big-endian 长度 + 2 字节 flags）+ 载荷。
Uint8List _id3Frame(String id, Uint8List payload) {
  final header = BytesBuilder()
    ..add(utf8.encode(id))
    ..add(_uint32be(payload.length))
    ..add(const [0x00, 0x00]);
  return (BytesBuilder()
        ..add(header.takeBytes())
        ..add(payload))
      .takeBytes();
}

/// UTF-16LE 文本 + 前置 BOM + 结尾 NUL（ID3 文本帧约定）。
Uint8List _utf16WithBom(String text) {
  final out = BytesBuilder()..add(const [0xFF, 0xFE]);
  for (final unit in text.codeUnits) {
    out.addByte(unit & 0xFF);
    out.addByte((unit >> 8) & 0xFF);
  }
  out.add(const [0x00, 0x00]);
  return out.takeBytes();
}

Uint8List _uint32be(int value) => Uint8List.fromList([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);

/// ID3 标签长度：4 字节 syncsafe（每字节 7 位）。
Uint8List _syncSafe(int value) => Uint8List.fromList([
      (value >> 21) & 0x7F,
      (value >> 14) & 0x7F,
      (value >> 7) & 0x7F,
      value & 0x7F,
    ]);

// ----------------------------------------------------------------- FLAC 标签

/// 重写 FLAC 元数据块：替换 VORBIS_COMMENT（4）与 PICTURE（6），其余原样保留。
Uint8List? _writeFlacComments(
  Uint8List file, {
  required String title,
  required String artist,
  required String album,
  required String? lyrics,
  required Uint8List? coverBytes,
  required String coverMimeType,
}) {
  if (file.length < 8 ||
      file[0] != 0x66 ||
      file[1] != 0x4C ||
      file[2] != 0x61 ||
      file[3] != 0x43) {
    return null; // 'fLaC'
  }
  final blocks = <_FlacBlock>[];
  var offset = 4;
  var last = false;
  while (!last) {
    if (offset + 4 > file.length) return null;
    final header = file[offset];
    last = header & 0x80 != 0;
    final type = header & 0x7F;
    final length = (file[offset + 1] << 16) |
        (file[offset + 2] << 8) |
        file[offset + 3];
    final start = offset + 4;
    final end = start + length;
    if (end > file.length) return null;
    // 已有注释 / 图片块由新写的替换，其余块（STREAMINFO / SEEKTABLE…）保留。
    if (type != 4 && type != 6) {
      blocks.add(_FlacBlock(type, Uint8List.sublistView(file, start, end)));
    }
    offset = end;
  }
  final audio = Uint8List.sublistView(file, offset);

  final newBlocks = <_FlacBlock>[];
  // STREAMINFO 必须是第一个块：把它顶到最前（原顺序里它本来就是第一个）。
  final streamInfoIndex = blocks.indexWhere((block) => block.type == 0);
  if (streamInfoIndex > 0) {
    final info = blocks.removeAt(streamInfoIndex);
    blocks.insert(0, info);
  }
  newBlocks.addAll(blocks);
  final comments = _vorbisComments(
    title: title,
    artist: artist,
    album: album,
    lyrics: lyrics,
  );
  if (comments.isNotEmpty) newBlocks.add(_FlacBlock(4, comments));
  if (coverBytes != null && coverBytes.isNotEmpty) {
    newBlocks.add(
      _FlacBlock(6, _flacPicture(coverBytes, coverMimeType)),
    );
  }
  if (newBlocks.isEmpty) return null;

  final out = BytesBuilder()..add(const [0x66, 0x4C, 0x61, 0x43]); // 'fLaC'
  for (var i = 0; i < newBlocks.length; i++) {
    final block = newBlocks[i];
    final isLast = i == newBlocks.length - 1;
    final length = block.data.length;
    out.addByte((isLast ? 0x80 : 0x00) | block.type);
    out.add([
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ]);
    out.add(block.data);
  }
  out.add(audio);
  return out.takeBytes();
}

/// Vorbis Comment 块：vendor + 键值对（UTF-8，`KEY=value`）。
Uint8List _vorbisComments({
  required String title,
  required String artist,
  required String album,
  required String? lyrics,
}) {
  final comments = <String>[
    if (title.isNotEmpty) 'TITLE=$title',
    if (artist.isNotEmpty) 'ARTIST=$artist',
    if (album.isNotEmpty) 'ALBUM=$album',
    if (lyrics != null && lyrics.isNotEmpty) 'LYRICS=$lyrics',
  ];
  if (comments.isEmpty) return Uint8List(0);
  const vendor = 'Molia';
  final out = BytesBuilder()
    ..add(_uint32le(vendor.length))
    ..add(utf8.encode(vendor))
    ..add(_uint32le(comments.length));
  for (final comment in comments) {
    final bytes = utf8.encode(comment);
    out
      ..add(_uint32le(bytes.length))
      ..add(bytes);
  }
  return out.takeBytes();
}

/// FLAC PICTURE 块：类型 3（front cover）+ MIME + 尺寸 0（未知）+ 图片字节。
Uint8List _flacPicture(Uint8List image, String mimeType) {
  final mime = utf8.encode(mimeType);
  final out = BytesBuilder()
    ..add(_uint32be(3))
    ..add(_uint32be(mime.length))
    ..add(mime)
    ..add(_uint32be(0)) // 描述长度
    ..add(_uint32be(0)) // 宽（未知）
    ..add(_uint32be(0)) // 高（未知）
    ..add(_uint32be(0)) // 色深（未知）
    ..add(_uint32be(0)) // 颜色数（未知）
    ..add(_uint32be(image.length))
    ..add(image);
  return out.takeBytes();
}

Uint8List _uint32le(int value) => Uint8List.fromList([
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ]);

class _FlacBlock {
  const _FlacBlock(this.type, this.data);

  final int type;
  final Uint8List data;
}
