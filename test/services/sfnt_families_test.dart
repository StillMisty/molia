import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/sfnt_families.dart';

/// sfnt 家族名解析器的纯解析测试：测试内构造最小字体字节，不依赖系统字体。
///
/// 字体布局（与真实文件同构，见 sfnt / OpenType 规范）：
/// - 头部 12 字节（version + numTables）→ 一条 `name` 表记录（16 字节）；
/// - `name` 表：6 字节头 + 12 字节/记录 + 字符串区；
/// - platform 3 的字符串是 UTF-16BE，platform 1 按字节直取。
void main() {
  group('sfntFamilyNames', () {
    test('取 platform 3 / en-US 的 nameID 1', () {
      final font = buildSfntFont([
        (platform: 3, language: 0x409, nameId: 1, text: 'Adwaita Sans'),
      ]);
      expect(sfntFamilyNames(readerOf(font)), ['Adwaita Sans']);
    });

    test('nameID 16（typographic family）优先于 nameID 1', () {
      final font = buildSfntFont([
        (platform: 3, language: 0x409, nameId: 1, text: 'Family A'),
        (platform: 3, language: 0x409, nameId: 16, text: 'Typographic A'),
      ]);
      expect(sfntFamilyNames(readerOf(font)), ['Typographic A']);
    });

    test('nameID 1 的 en-US 优先于其它语言', () {
      final font = buildSfntFont([
        (platform: 3, language: 0x804, nameId: 1, text: '微软雅黑'),
        (platform: 3, language: 0x409, nameId: 1, text: 'Microsoft YaHei'),
      ]);
      expect(sfntFamilyNames(readerOf(font)), ['Microsoft YaHei']);
    });

    test('只有 platform 1（Mac）时按 latin1 近似取 nameID 1', () {
      final font = buildSfntFont([
        (platform: 1, language: 0, nameId: 1, text: 'Geneva'),
      ]);
      expect(sfntFamilyNames(readerOf(font)), ['Geneva']);
    });

    test('忽略 nameID 之外的记录，缺失家族名返回空列表', () {
      final font = buildSfntFont([
        (platform: 3, language: 0x409, nameId: 4, text: 'Full Name Only'),
      ]);
      expect(sfntFamilyNames(readerOf(font)), isEmpty);
    });

    test('TTC 字体集合逐 face 解析（表偏移是文件绝对偏移）', () {
      final ttc = buildSfntCollection([
        [
          (platform: 3, language: 0x409, nameId: 1, text: 'Noto Sans CJK JP'),
        ],
        [
          (platform: 3, language: 0x409, nameId: 1, text: 'Noto Sans CJK SC'),
        ],
      ]);
      expect(sfntFamilyNames(readerOf(ttc)),
          ['Noto Sans CJK JP', 'Noto Sans CJK SC']);
    });

    test('家族名去重（大小写不敏感），保持出现顺序', () {
      final ttc = buildSfntCollection([
        [
          (platform: 3, language: 0x409, nameId: 1, text: 'Arial'),
        ],
        [
          (platform: 3, language: 0x409, nameId: 1, text: 'arial'),
        ],
      ]);
      expect(sfntFamilyNames(readerOf(ttc)), ['Arial']);
    });

    test('损坏 / 截断字节返回空列表且不抛异常', () {
      expect(sfntFamilyNames(readerOf(Uint8List(0))), isEmpty);
      expect(sfntFamilyNames(readerOf(Uint8List.fromList([1, 2, 3]))), isEmpty);

      final font = buildSfntFont([
        (platform: 3, language: 0x409, nameId: 1, text: 'Adwaita Sans'),
      ]);
      for (final length in [4, 12, 20, 30, font.length ~/ 2]) {
        expect(
          sfntFamilyNames(readerOf(Uint8List.sublistView(font, 0, length))),
          isEmpty,
          reason: '截断到 $length 字节应不可解析',
        );
      }
    });

    test('没有 name 表的字体返回空列表', () {
      final font = Uint8List(28);
      final data = ByteData.sublistView(font);
      data.setUint32(0, 0x00010000);
      data.setUint16(4, 1);
      data.buffer.asUint8List().setRange(12, 16, 'cmap'.codeUnits);
      data.setUint32(20, 28);
      data.setUint32(24, 0);
      expect(sfntFamilyNames(readerOf(font)), isEmpty);
    });
  });
}

/// 读取回调：越界返回短字节（解析器按「不可解析」处理）。
SfntBytes readerOf(Uint8List bytes) => (offset, length) {
      if (offset < 0 || length <= 0 || offset >= bytes.length) {
        return Uint8List(0);
      }
      final end = offset + length;
      return Uint8List.sublistView(
        bytes,
        offset,
        end > bytes.length ? bytes.length : end,
      );
    };

typedef NameRecord = ({
  int platform,
  int language,
  int nameId,
  String text,
});

/// 单 face 字体：12 字节头 + 1 条表目录记录 + `name` 表。
/// `name` 表偏移（28）写进表目录，与真实文件一致。
Uint8List buildSfntFont(List<NameRecord> records) {
  final nameTable = _buildNameTable(records);
  const nameTableOffset = 28;
  final font = Uint8List(nameTableOffset + nameTable.length);
  final data = ByteData.sublistView(font);
  data.setUint32(0, 0x00010000); // TrueType 轮廓版本
  data.setUint16(4, 1); // numTables
  font.setRange(12, 16, 'name'.codeUnits);
  data.setUint32(20, nameTableOffset);
  data.setUint32(24, nameTable.length);
  font.setRange(nameTableOffset, font.length, nameTable);
  return font;
}

/// TTC 字体集合：头部偏移表 + 依次排布的 face；各 face 的表目录偏移
/// 改写为文件绝对偏移（真实 TTC 的约定）。
Uint8List buildSfntCollection(List<List<NameRecord>> faces) {
  final faceBytes = faces.map(buildSfntFont).toList(growable: false);
  final headerLength = 12 + faces.length * 4;
  final total =
      headerLength + faceBytes.fold<int>(0, (sum, bytes) => sum + bytes.length);
  final ttc = Uint8List(total);
  final data = ByteData.sublistView(ttc);
  ttc.setRange(0, 4, 'ttcf'.codeUnits);
  data.setUint32(4, 0x00010000); // version 1.0
  data.setUint32(8, faces.length);
  var offset = headerLength;
  for (var i = 0; i < faceBytes.length; i++) {
    data.setUint32(12 + i * 4, offset);
    ttc.setRange(offset, offset + faceBytes[i].length, faceBytes[i]);
    // face 的表目录里 name 表偏移（记录内第 8 字节起）改成绝对偏移。
    data.setUint32(offset + 20, offset + 28);
    offset += faceBytes[i].length;
  }
  return ttc;
}

Uint8List _buildNameTable(List<NameRecord> records) {
  final strings = BytesBuilder();
  final offsets = <int>[];
  final encoded = <Uint8List>[];
  for (final record in records) {
    offsets.add(strings.length);
    final bytes = record.platform == 3
        ? _utf16be(record.text)
        : Uint8List.fromList(record.text.codeUnits);
    encoded.add(bytes);
    strings.add(bytes);
  }

  final table = BytesBuilder();
  final header = ByteData(6 + records.length * 12);
  header.setUint16(0, 0); // 格式 0
  header.setUint16(2, records.length);
  header.setUint16(4, header.lengthInBytes); // 字符串区偏移
  for (var i = 0; i < records.length; i++) {
    final base = 6 + i * 12;
    header.setUint16(base, records[i].platform);
    header.setUint16(base + 2, 1); // encodingID：固定 1，被测代码不使用
    header.setUint16(base + 4, records[i].language);
    header.setUint16(base + 6, records[i].nameId);
    header.setUint16(base + 8, encoded[i].length);
    header.setUint16(base + 10, offsets[i]);
  }
  table.add(header.buffer.asUint8List());
  table.add(strings.takeBytes());
  return table.takeBytes();
}

Uint8List _utf16be(String text) {
  final units = text.codeUnits;
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes[i * 2] = units[i] >> 8;
    bytes[i * 2 + 1] = units[i] & 0xFF;
  }
  return bytes;
}
