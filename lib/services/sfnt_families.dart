/// sfnt（TrueType / OpenType）字体文件的家族名解析。
///
/// **为什么需要解析文件**：只有家族名能被 `TextStyle.fontFamily` 解析。
/// 文件名是缩写（`msyh.ttc`），Windows 注册表值名是「每文件全名」且带样式后缀
/// （`Arial Bold (TrueType)`），两者当家族名用都会静默回退默认字体。
///
/// 取值口径与渲染器（DirectWrite / Skia 的字体匹配）一致：
/// - nameID 16（typographic family）优先，其次 nameID 1（family）；
/// - platform 3（Windows，UTF-16BE）取 lang 0x409（en-US），否则同平台其它
///   语言；再退 platform 0（Unicode）；最后 platform 1（Mac，按 latin1 近似）；
/// - `.ttc` / `.otc` 字体集合逐 face 解析（各 face 表偏移是文件绝对偏移，
///   已用 Noto CJK 字体集合实测核对）。
///
/// 读取走 [SfntBytes] 回调：CJK 字体集合单文件可达数十 MB，只读解析所需区间。
library;

import 'dart:typed_data';

/// 同步随机读取：返回 `[offset, offset + length)` 的字节；越界允许返回不足
/// 长度的字节 —— 解析器把缺失数据一律视为「不可解析」，不抛异常。
typedef SfntBytes = Uint8List Function(int offset, int length);

/// 解析字体文件里所有 face 的家族名：去重（大小写不敏感）、去空白，
/// 保持出现顺序；不可解析返回空列表。
List<String> sfntFamilyNames(SfntBytes read) {
  final families = <String>[];
  final seen = <String>{};
  for (final faceOffset in _faceOffsets(read)) {
    final family = _faceFamilyName(read, faceOffset);
    if (family == null || family.isEmpty) continue;
    if (seen.add(family.toLowerCase())) {
      families.add(family);
    }
  }
  return families;
}

/// face 起点列表：普通字体是 0；`ttcf` 集合读头部偏移表。
/// 非 sfnt / 头部异常返回空列表。
List<int> _faceOffsets(SfntBytes read) {
  final header = read(0, 12);
  if (header.length < 12) return const <int>[];
  if (_tagAt(header, 0) != 'ttcf') return const <int>[0];

  final numFonts = _uint32(header, 8);
  if (numFonts <= 0 || numFonts > 0x1000) return const <int>[];
  final table = read(12, numFonts * 4);
  final offsets = <int>[];
  for (var i = 0; i + 4 <= table.length; i += 4) {
    final offset = _uint32(table, i);
    if (offset > 0) offsets.add(offset);
  }
  return offsets;
}

/// 单个 face 的家族名；表目录 / name 表缺失或损坏返回 null。
String? _faceFamilyName(SfntBytes read, int faceOffset) {
  final header = read(faceOffset, 12);
  if (header.length < 12) return null;
  final numTables = _uint16(header, 4);
  if (numTables <= 0 || numTables > 0x1000) return null;

  final records = read(faceOffset + 12, numTables * 16);
  for (var i = 0; i + 16 <= records.length; i += 16) {
    if (_tagAt(records, i) != 'name') continue;
    final nameTableOffset = _uint32(records, i + 8);
    if (nameTableOffset <= 0) return null;
    return _nameTableFamily(read, nameTableOffset);
  }
  return null;
}

/// `name` 表里挑优先级最高的家族名（见库注释的口径）。
String? _nameTableFamily(SfntBytes read, int tableOffset) {
  final header = read(tableOffset, 6);
  if (header.length < 6) return null;
  final version = _uint16(header, 0);
  if (version != 0 && version != 1) return null;
  final recordCount = _uint16(header, 2);
  final storageOffset = _uint16(header, 4);
  if (recordCount <= 0 || recordCount > 0x800) return null;

  final records = read(tableOffset + 6, recordCount * 12);
  String? best;
  var bestScore = 1 << 30;
  for (var i = 0; i + 12 <= records.length; i += 12) {
    final platformId = _uint16(records, i);
    final languageId = _uint16(records, i + 4);
    final nameId = _uint16(records, i + 6);
    if (nameId != 1 && nameId != 16) continue;
    final score = _nameScore(nameId, platformId, languageId);
    if (score >= bestScore) continue;
    final length = _uint16(records, i + 8);
    final offset = _uint16(records, i + 10);
    if (length <= 0) continue;
    final value = _decodeName(
      read(tableOffset + storageOffset + offset, length),
      platformId,
    );
    if (value == null || value.isEmpty) continue;
    best = value;
    bestScore = score;
  }
  return best;
}

/// 记录优先级，越小越优先；不支持的平台返回 `1 << 20`（永不入选）。
int _nameScore(int nameId, int platformId, int languageId) {
  final familyScore = nameId == 16 ? 0 : 1;
  final platformScore = switch (platformId) {
    3 => languageId == 0x409 ? 0 : 1,
    0 => 1,
    1 => 2,
    _ => 1 << 19,
  };
  return (familyScore << 4) | platformScore;
}

/// 名称字符串解码：platform 3/0 是 UTF-16BE；platform 1 按 latin1 近似
/// （Dart 没有 Mac Roman 解码器，非拉丁名称会退化为近似字形，可接受）。
String? _decodeName(Uint8List bytes, int platformId) {
  final text = switch (platformId) {
    3 || 0 => _decodeUtf16Be(bytes),
    1 => String.fromCharCodes(bytes),
    _ => null,
  };
  // 少数字体的字符串区有 NUL 填充，去掉再判空。
  return text?.replaceAll('\u0000', '').trim();
}

String _decodeUtf16Be(Uint8List bytes) {
  final codes = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codes.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(codes);
}

/// 4 字节 ASCII tag（`ttcf` / `name` …）；长度不足返回空串。
String _tagAt(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return '';
  return String.fromCharCodes(bytes, offset, offset + 4);
}

/// 调用方保证 `offset + 2 <= bytes.length`。
int _uint16(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

/// 调用方保证 `offset + 4 <= bytes.length`。
int _uint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
