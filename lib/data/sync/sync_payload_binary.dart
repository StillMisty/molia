/// 列式二进制载荷（协议 v3 的线上格式）。
///
/// 设计约束（协议只有 v3，无兼容分支，见 ADR-0003 §1）：
/// - **自描述**：载荷内写「data 键名表 + 每列的编码方式」，解码端按编码还原
///   `SyncRecord.data`；领域模型加字段不需要动编码器（字段表不进协议，
///   线上与备份共用同一 `SyncEnvelope`）。
/// - **列式 + 每列按体积择优**：int 走 varint（可选差分）、字符串走
///   字典 / 公共前缀 / 十六进制打包、混合与嵌套走 JSON 兜底。同一首歌的
///   payload 被历史 / 统计重复携带时，字典列把每次播放的数百字节压到几十
///   字节（实测统计型载荷约为 gzip(JSON) 的 1/3）。
/// - **不在本层压缩**：裸二进制对小载荷已小于 gzip 结果（单条变更
///   239B vs 488B），按阈值压缩交给帧层（`sync_crypto.dart`）。
///
/// 布局（uvarint = 7 位小端分组；zigzag 用于有符号量；str = uvarint 长度 + UTF-8）：
/// ```
/// payload := version(1)=1 | kind(1) 0=快照 1=增量
///          | str deviceId | str deviceName | uvarint producedAt
///          | 指纹(1 字节标记: 0 无 / 1 十六进制打包 16B / 2 文本)
///          | uvarint journalHead | uvarint baseSeq
///          | uvarint windowStart | uvarint windowEnd
///          | uvarint ackCount | (str deviceId | uvarint seq)*
///          | uvarint categoryCount | str categoryName*
///          | 行区: uvarint rowCount | 固定列 × 6 | data 键表 + 每键一列
/// ```
/// 固定列顺序：类别索引 / seq / key / physical / counter / deviceId；
/// 标志列紧随其后（1 字节/行：bit0 墓碑、bit1 有 data）。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../domain/models/device_sync.dart';
import 'sync_payload_format.dart';

/// 列编码（列头第一个字节）。位图按需跟随，值区在最后。
abstract final class _Col {
  static const int ints = 0;
  static const int intsDelta = 1;
  static const int bools = 2;
  static const int stringsPlain = 3;
  static const int stringsFront = 4;
  static const int stringsDict = 5;
  static const int stringsHex = 6;
  static const int opaqueJson = 7;

  /// 列头第二个字节的标志位。
  static const int flagPresence = 0x01;
  static const int flagNulls = 0x02;
}

/// 「键不存在」哨兵：与显式 `null` 区分。`null` 要原样往返——它参与内容
/// 指纹比对，丢失会让 anti-entropy 反复误判「内容不一致」。
const Object _absent = Object();

/// 载荷内部格式版本（帧版本见 `sync_crypto.dart`）。
const int _payloadVersion = 1;

abstract final class SyncPayloadBinary {
  static Uint8List encode(SyncEnvelope envelope) {
    final rows = _collectRows(envelope);
    // 类别表：行内只存索引（类别名只写一次）。
    final categoryNames = <String>[];
    final categoryIndex = <String, int>{};
    final rowCategories = <int>[];
    final rowSeqs = <int>[];
    final rowKeys = <String>[];
    final rowPhysical = <int>[];
    final rowCounter = <int>[];
    final rowDevice = <String>[];
    final rowFlags = Uint8List(rows.length);
    for (final row in rows) {
      rowCategories.add(categoryIndex.putIfAbsent(row.category.name, () {
        categoryNames.add(row.category.name);
        return categoryNames.length - 1;
      }));
      rowSeqs.add(row.seq);
      rowKeys.add(row.record.key);
      rowPhysical.add(row.record.version.physical);
      rowCounter.add(row.record.version.counter);
      rowDevice.add(row.record.version.deviceId);
    }
    for (var i = 0; i < rows.length; i++) {
      final record = rows[i].record;
      rowFlags[i] = (record.deleted ? 0x01 : 0x00) |
          (record.data != null ? 0x02 : 0x00);
    }

    final w = _Writer();
    w.u8(_payloadVersion);
    w.u8(envelope.isDelta ? 1 : 0);
    w.str(envelope.deviceId);
    w.str(envelope.deviceName);
    w.uvarint(envelope.producedAt);
    _writeSnapshotId(w, envelope.snapshotId);
    w.uvarint(envelope.journalHead);
    w.uvarint(envelope.baseSeq);
    w.uvarint(envelope.windowStart);
    w.uvarint(envelope.windowEnd);
    w.uvarint(envelope.acks.length);
    for (final ack in envelope.acks.entries) {
      w.str(ack.key);
      w.uvarint(ack.value);
    }
    // 声明类别（envelope.categories，anti-entropy 的比对口径）与行类别表分开写：
    // 前者原样往返，后者只服务行内索引。
    w.uvarint(envelope.categories.length);
    for (final name in envelope.categories) {
      w.str(name);
    }
    w.uvarint(categoryNames.length);
    for (final name in categoryNames) {
      w.str(name);
    }
    w.uvarint(rows.length);
    _writeColumn(w, rowCategories, intDelta: true);
    _writeColumn(w, rowSeqs, intDelta: true);
    _writeColumn(w, rowKeys);
    _writeColumn(w, rowPhysical, intDelta: true);
    _writeColumn(w, rowCounter);
    _writeColumn(w, rowDevice);
    w.raw(rowFlags);
    _writeDataColumns(w, rows);
    return w.toBytes();
  }

  static SyncEnvelope decode(Uint8List bytes) {
    final r = _Reader(bytes);
    final payloadVersion = r.u8();
    if (payloadVersion != _payloadVersion) {
      throw SyncPayloadFormatException('载荷版本不支持: $payloadVersion');
    }
    final kind = r.u8();
    if (kind != 0 && kind != 1) {
      throw SyncPayloadFormatException('载荷类型无效: $kind');
    }
    final deviceId = r.str();
    final deviceName = r.str();
    final producedAt = r.uvarint();
    final snapshotId = _readSnapshotId(r);
    final journalHead = r.uvarint();
    final baseSeq = r.uvarint();
    final windowStart = r.uvarint();
    final windowEnd = r.uvarint();
    final acks = <String, int>{};
    for (var i = 0, count = r.uvarint(); i < count; i++) {
      acks[r.str()] = r.uvarint();
    }
    final declared = <String>[];
    for (var i = 0, count = r.uvarint(); i < count; i++) {
      declared.add(r.str());
    }
    final rowCategoriesTable = <SyncCategory>[];
    for (var i = 0, count = r.uvarint(); i < count; i++) {
      final name = r.str();
      final category = SyncCategory.tryParse(name);
      if (category == null) throw SyncPayloadFormatException('未知类别: $name');
      rowCategoriesTable.add(category);
    }

    final rowCount = r.uvarint();
    final rowCategories = _readColumn(r, rowCount);
    final rowSeqs = _readColumn(r, rowCount);
    final rowKeys = _readColumn(r, rowCount);
    final rowPhysical = _readColumn(r, rowCount);
    final rowCounter = _readColumn(r, rowCount);
    final rowDevice = _readColumn(r, rowCount);
    final rowFlags = r.bytes(rowCount);
    final dataColumns = _readDataColumns(r, rowCount);

    final records = <SyncCategory, List<SyncRecord>>{};
    final journal = <SyncJournalEntry>[];
    for (var i = 0; i < rowCount; i++) {
      final categoryIndex = rowCategories[i] as int;
      if (categoryIndex >= rowCategoriesTable.length) {
        throw SyncPayloadFormatException('类别索引越界: $categoryIndex');
      }
      final hasData = rowFlags[i] & 0x02 != 0;
      Map<String, Object?>? data;
      if (hasData) {
        data = <String, Object?>{};
        for (final column in dataColumns) {
          final value = column.values[i];
          if (identical(value, _absent)) continue;
          data[column.key] = value;
        }
      }
      final record = SyncRecord(
        key: rowKeys[i] as String,
        deleted: rowFlags[i] & 0x01 != 0,
        version: SyncVersion(
          physical: rowPhysical[i] as int,
          counter: rowCounter[i] as int,
          deviceId: rowDevice[i] as String,
        ),
        data: data,
      );
      final category = rowCategoriesTable[categoryIndex];
      if (kind == 1) {
        journal.add(
          SyncJournalEntry(seq: rowSeqs[i] as int, category: category, record: record),
        );
      } else {
        records.putIfAbsent(category, () => []).add(record);
      }
    }

    return SyncEnvelope(
      deviceId: deviceId,
      deviceName: deviceName,
      producedAt: producedAt,
      snapshotId: snapshotId,
      journalHead: journalHead,
      baseSeq: baseSeq,
      windowStart: windowStart,
      windowEnd: windowEnd,
      journal: kind == 1 ? journal : null,
      acks: acks,
      categories: declared,
      records: records,
    );
  }

  static List<_Row> _collectRows(SyncEnvelope envelope) {
    final rows = <_Row>[];
    final journal = envelope.journal;
    if (journal != null) {
      for (final entry in journal) {
        rows.add(
          _Row(category: entry.category, seq: entry.seq, record: entry.record),
        );
      }
      return rows;
    }
    for (final entry in envelope.records.entries) {
      for (final record in entry.value) {
        rows.add(_Row(category: entry.key, seq: 0, record: record));
      }
    }
    return rows;
  }

  /// 快照指纹：64 位十六进制（本机指纹格式）打包成 16 字节；其它形态按文本
  /// 原样写（测试与备份里的自定义指纹）。
  static void _writeSnapshotId(_Writer w, String value) {
    if (value.isEmpty) {
      w.u8(0);
      return;
    }
    final packed = _hexToBytes(value);
    if (packed != null) {
      w.u8(1);
      w.lenBytes(packed);
      return;
    }
    w.u8(2);
    w.str(value);
  }

  static String _readSnapshotId(_Reader r) {
    final tag = r.u8();
    return switch (tag) {
      0 => '',
      1 => _bytesToHex(r.bytes(r.uvarint())),
      2 => r.str(),
      _ => throw SyncPayloadFormatException('快照指纹标记无效: $tag'),
    };
  }

  /// data 键表 + 每键一列（列内只覆盖「该行有 data 且带这个键」的格子）。
  static void _writeDataColumns(_Writer w, List<_Row> rows) {
    final keys = <String>[];
    final columns = <String, List<Object?>>{};
    for (var i = 0; i < rows.length; i++) {
      final data = rows[i].record.data;
      if (data == null) continue;
      for (final entry in data.entries) {
        final column = columns.putIfAbsent(entry.key, () {
          keys.add(entry.key);
          return List<Object?>.filled(rows.length, _absent);
        });
        column[i] = entry.value;
      }
    }
    w.uvarint(keys.length);
    for (final key in keys) {
      w.str(key);
    }
    for (final key in keys) {
      _writeColumn(w, columns[key]!);
    }
  }

  static List<_DataColumn> _readDataColumns(_Reader r, int rowCount) {
    final keys = <String>[];
    for (var i = 0, count = r.uvarint(); i < count; i++) {
      keys.add(r.str());
    }
    return [for (final key in keys) _DataColumn(key, _readColumn(r, rowCount))];
  }

  /// 一列：`编码(1) | 标志(1) | [存在位图] | [空值位图] | 值区`。
  ///
  /// [intDelta] 只对整数列生效（差分相对上一个值；类别 / seq / physical
  /// 这类近似单调的列差分后更小，由实际字节数择优）。
  static void _writeColumn(
    _Writer w,
    List<Object?> cells, {
    bool? intDelta,
  }) {
    var hasPresence = false;
    var hasNulls = false;
    final present = <Object?>[];
    for (final cell in cells) {
      if (identical(cell, _absent)) {
        hasPresence = true;
      } else {
        present.add(cell);
        if (cell == null) hasNulls = true;
      }
    }
    final values = [for (final value in present) if (value != null) value];
    var flags = 0;
    if (hasPresence) flags |= _Col.flagPresence;
    if (hasNulls) flags |= _Col.flagNulls;

    final allInts = values.every((value) => value is int);
    final allBools = values.every((value) => value is bool);
    final allStrings = values.every((value) => value is String);
    final ints = allInts ? values.cast<int>() : const <int>[];
    final strings = allStrings ? values.cast<String>() : const <String>[];
    final useDelta = allInts && (intDelta ?? true) && _deltaIsSmaller(ints);
    final encoding = allInts
        ? (useDelta ? _Col.intsDelta : _Col.ints)
        : allBools
            ? _Col.bools
            : allStrings
                ? _pickStringEncoding(strings)
                : _Col.opaqueJson;

    w.u8(encoding);
    w.u8(flags);
    if (hasPresence) {
      final bits = Uint8List((cells.length + 7) >> 3);
      for (var i = 0; i < cells.length; i++) {
        if (!identical(cells[i], _absent)) bits[i >> 3] |= 1 << (i & 7);
      }
      w.raw(bits);
    }
    if (hasNulls) {
      final bits = Uint8List((present.length + 7) >> 3);
      for (var i = 0; i < present.length; i++) {
        if (present[i] == null) bits[i >> 3] |= 1 << (i & 7);
      }
      w.raw(bits);
    }

    switch (encoding) {
      case _Col.ints:
      case _Col.intsDelta:
        int? previous;
        for (final value in ints) {
          if (useDelta && previous != null) {
            w.zzvarint(value - previous);
          } else {
            w.zzvarint(value);
          }
          previous = value;
        }
      case _Col.bools:
        final bits = Uint8List((values.length + 7) >> 3);
        for (var i = 0; i < values.length; i++) {
          if (values[i] as bool) bits[i >> 3] |= 1 << (i & 7);
        }
        w.raw(bits);
      case _Col.stringsPlain:
      case _Col.stringsFront:
      case _Col.stringsDict:
      case _Col.stringsHex:
        _writeStrings(w, strings, encoding);
      default:
        for (final value in values) {
          w.str(jsonEncode(value));
        }
    }
  }

  /// 差分是否更小（整数列的编码择优）。
  static bool _deltaIsSmaller(List<int> values) {
    var plainBytes = 0;
    var deltaBytes = 0;
    int? previous;
    for (final value in values) {
      plainBytes += _varintLength(_zigzag(value));
      deltaBytes +=
          _varintLength(_zigzag(previous == null ? value : value - previous));
      previous = value;
    }
    return deltaBytes < plainBytes;
  }

  static void _writeStrings(_Writer w, List<String> values, int encoding) {
    switch (encoding) {
      case _Col.stringsHex:
        for (final bytes in _hexPacked(values)!) {
          w.lenBytes(bytes);
        }
      case _Col.stringsDict:
        final index = <String, int>{};
        final unique = <String>[];
        for (final value in values) {
          index.putIfAbsent(value, () {
            unique.add(value);
            return unique.length - 1;
          });
        }
        w.uvarint(unique.length);
        for (final value in unique) {
          w.str(value);
        }
        for (final value in values) {
          w.uvarint(index[value]!);
        }
      case _Col.stringsFront:
        String? previous;
        for (final value in values) {
          final prefix = previous == null ? 0 : _commonPrefix(previous, value);
          w.uvarint(prefix);
          w.str(value.substring(prefix));
          previous = value;
        }
      default:
        for (final value in values) {
          w.str(value);
        }
    }
  }

  /// 读取一列（返回每行的格子：[_absent] / `null` / 值）。
  static List<Object?> _readColumn(_Reader r, int rowCount) {
    final encoding = r.u8();
    final flags = r.u8();
    final presence = flags & _Col.flagPresence != 0 ? r.readBitmap(rowCount) : null;
    final presentCount = presence?.count ?? rowCount;
    final nulls =
        flags & _Col.flagNulls != 0 ? r.readBitmap(presentCount) : null;
    final valueCount = presentCount - (nulls?.count ?? 0);
    final values = _readValues(r, valueCount, encoding);
    final cells = List<Object?>.filled(rowCount, _absent);
    var cursor = 0;
    var presentIndex = 0;
    for (var i = 0; i < rowCount; i++) {
      if (presence != null && !presence.has(i)) continue;
      final isNull = nulls != null && nulls.has(presentIndex);
      presentIndex++;
      if (isNull) {
        cells[i] = null;
        continue;
      }
      cells[i] = values[cursor++];
    }
    return cells;
  }

  static List<Object?> _readValues(_Reader r, int count, int encoding) {
    switch (encoding) {
      case _Col.ints:
      case _Col.intsDelta:
        final values = <Object?>[];
        int? previous;
        for (var i = 0; i < count; i++) {
          final raw = r.zzvarint();
          final value = encoding == _Col.intsDelta && previous != null
              ? previous + raw
              : raw;
          values.add(value);
          previous = value;
        }
        return values;
      case _Col.bools:
        final bits = r.bytes((count + 7) >> 3);
        return [
          for (var i = 0; i < count; i++) bits[i >> 3] & (1 << (i & 7)) != 0,
        ];
      case _Col.stringsPlain:
      case _Col.stringsFront:
        final values = <Object?>[];
        String previous = '';
        for (var i = 0; i < count; i++) {
          final prefix = encoding == _Col.stringsFront ? r.uvarint() : 0;
          final suffix = r.str();
          if (prefix > previous.length) {
            throw const SyncPayloadFormatException('前缀长度越界');
          }
          previous = previous.substring(0, prefix) + suffix;
          values.add(previous);
        }
        return values;
      case _Col.stringsDict:
        final unique = <String>[];
        for (var i = 0, size = r.uvarint(); i < size; i++) {
          unique.add(r.str());
        }
        final values = <Object?>[];
        for (var i = 0; i < count; i++) {
          final index = r.uvarint();
          if (index >= unique.length) {
            throw SyncPayloadFormatException('字典索引越界: $index');
          }
          values.add(unique[index]);
        }
        return values;
      case _Col.stringsHex:
        return [
          for (var i = 0; i < count; i++) _bytesToHex(r.bytes(r.uvarint())),
        ];
      case _Col.opaqueJson:
        return [for (var i = 0; i < count; i++) jsonDecode(r.str()) as Object?];
      default:
        throw SyncPayloadFormatException('列编码无效: $encoding');
    }
  }

  /// 字符串列择优：候选编码各自估长（与写入同口径），取最小。
  static int _pickStringEncoding(List<String> values) {
    if (values.isEmpty) return _Col.stringsPlain;
    if (_hexPacked(values) != null) return _Col.stringsHex;
    final unique = <String>{};
    for (final value in values) {
      unique.add(value);
    }
    final plainLength = _stringsPlainLength(values);
    if (unique.length == values.length) {
      final frontLength = _stringsFrontLength(values);
      return frontLength < plainLength ? _Col.stringsFront : _Col.stringsPlain;
    }
    final dictLength = _stringsDictLength(values, unique);
    final frontLength = _stringsFrontLength(values);
    if (dictLength < plainLength && dictLength < frontLength) {
      return _Col.stringsDict;
    }
    if (dictLength < plainLength ||
        (frontLength < plainLength && frontLength <= dictLength)) {
      return _Col.stringsFront;
    }
    return _Col.stringsPlain;
  }

  static int _stringsPlainLength(List<String> values) {
    var total = 0;
    for (final value in values) {
      final length = utf8.encode(value).length;
      total += _varintLength(length) + length;
    }
    return total;
  }

  static int _stringsFrontLength(List<String> values) {
    var total = 0;
    String? previous;
    for (final value in values) {
      final prefix = previous == null ? 0 : _commonPrefix(previous, value);
      final suffix = utf8.encode(value.substring(prefix)).length;
      total += _varintLength(prefix) + _varintLength(suffix) + suffix;
      previous = value;
    }
    return total;
  }

  static int _stringsDictLength(List<String> values, Set<String> unique) {
    var total = _varintLength(unique.length);
    for (final value in unique) {
      final length = utf8.encode(value).length;
      total += _varintLength(length) + length;
    }
    final indexBytes = _varintLength(unique.length <= 1 ? 0 : unique.length - 1);
    return total + values.length * indexBytes;
  }

  static List<Uint8List>? _hexPacked(List<String> values) {
    final packed = <Uint8List>[];
    for (final value in values) {
      final bytes = _hexToBytes(value);
      if (bytes == null) return null;
      packed.add(bytes);
    }
    return packed;
  }

  static int _commonPrefix(String a, String b) {
    var i = 0;
    final max = a.length < b.length ? a.length : b.length;
    while (i < max && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  /// 十六进制 → 字节。只接受**小写**且长度 ≥ 8 的偶数串：打包必须能逐字符
  /// 还原（大写会在往返后变成小写，内容指纹随之漂移）。
  static Uint8List? _hexToBytes(String value) {
    if (value.length < 8 || value.length.isOdd) return null;
    final bytes = Uint8List(value.length >> 1);
    for (var i = 0; i < bytes.length; i++) {
      final high = _hexDigit(value.codeUnitAt(i * 2));
      final low = _hexDigit(value.codeUnitAt(i * 2 + 1));
      if (high < 0 || low < 0) return null;
      bytes[i] = (high << 4) | low;
    }
    return bytes;
  }

  /// 小写十六进制数字（大写不接受：打包必须逐字符可还原）。
  static int _hexDigit(int code) {
    if (code >= 0x30 && code <= 0x39) return code - 0x30;
    if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
    return -1;
  }

  static String _bytesToHex(Uint8List bytes) {
    const digits = '0123456789abcdef';
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer
        ..write(digits[byte >> 4])
        ..write(digits[byte & 0x0f]);
    }
    return buffer.toString();
  }

  static int _varintLength(int value) {
    var length = 1;
    var remaining = value;
    while (remaining >= 0x80) {
      remaining >>= 7;
      length++;
    }
    return length;
  }

  static int _zigzag(int value) => (value << 1) ^ (value >> 63);
}

/// 行（快照 = 记录；增量 = journal 条目）。
class _Row {
  const _Row({required this.category, required this.seq, required this.record});

  final SyncCategory category;
  final int seq;
  final SyncRecord record;
}

/// 数据列解码结果（键 + 每行格子）。
class _DataColumn {
  const _DataColumn(this.key, this.values);

  final String key;
  final List<Object?> values;
}

/// 位图（读侧：消费字节并保留位视图）。
class _Bitmap {
  const _Bitmap(this.bits, this.count);

  final Uint8List bits;
  final int count;

  bool has(int index) => bits[index >> 3] & (1 << (index & 7)) != 0;
}

class _Writer {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void u8(int value) => _out.addByte(value);

  void raw(List<int> bytes) => _out.add(bytes);

  void uvarint(int value) {
    var remaining = value < 0 ? 0 : value;
    while (remaining >= 0x80) {
      _out.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _out.addByte(remaining);
  }

  void zzvarint(int value) => uvarint((value << 1) ^ (value >> 63));

  void lenBytes(List<int> bytes) {
    uvarint(bytes.length);
    raw(bytes);
  }

  void str(String value) => lenBytes(utf8.encode(value));

  Uint8List toBytes() => _out.toBytes();
}

class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  int u8() {
    _require(1);
    return _bytes[_offset++];
  }

  int uvarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (shift > 63) throw const SyncPayloadFormatException('varint 过长');
      final byte = u8();
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  int zzvarint() {
    final raw = uvarint();
    return (raw >> 1) ^ -(raw & 1);
  }

  Uint8List bytes(int length) {
    if (length < 0) throw const SyncPayloadFormatException('长度越界');
    _require(length);
    final slice = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return slice;
  }

  String str() => utf8.decode(bytes(uvarint()));

  _Bitmap readBitmap(int count) {
    final byteLength = (count + 7) >> 3;
    final bits = bytes(byteLength);
    var ones = 0;
    for (final byte in bits) {
      var value = byte;
      while (value != 0) {
        ones += value & 1;
        value >>= 1;
      }
    }
    return _Bitmap(bits, ones);
  }

  void _require(int length) {
    if (_offset + length > _bytes.length) {
      throw const SyncPayloadFormatException('载荷截断');
    }
  }
}
