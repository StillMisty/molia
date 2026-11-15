/// 最小 ZIP 中央目录读取（只取条目名与压缩前后大小）。
///
/// 为什么自己解而不是加依赖：`apk_size` 只需要中央目录里的三个字段，
/// 引一个 ZIP 库会给工具链加长期维护面；`dart:io` 本身没有 ZIP。
/// 限制：不支持 ZIP64（APK 远小于 4GB，条目数也远小于 65535），遇到时
/// 显式报错而不是给出错误数字。
library;

import 'dart:io';
import 'dart:typed_data';

class ZipEntryInfo {
  const ZipEntryInfo({
    required this.name,
    required this.compressedSize,
    required this.uncompressedSize,
  });

  final String name;
  final int compressedSize;
  final int uncompressedSize;
}

const int _endOfCentralDirectorySignature = 0x06054b50;
const int _centralFileHeaderSignature = 0x02014b50;
const int _maxEndOfCentralDirectoryTail = 65557; // 22 字节固定头 + 65535 注释

/// 读中央目录。顺序即归档顺序，调用方自行排序。
List<ZipEntryInfo> readZipDirectory(File file) {
  final RandomAccessFile raf = file.openSync();
  try {
    final length = raf.lengthSync();
    if (length < 22) {
      throw FormatException('不是 ZIP：文件太短（$length 字节）');
    }
    final tailLength = length < _maxEndOfCentralDirectoryTail
        ? length
        : _maxEndOfCentralDirectoryTail;
    raf.setPositionSync(length - tailLength);
    final tail = raf.readSync(tailLength);

    final eocdOffset = _findEndOfCentralDirectory(tail);
    if (eocdOffset < 0) {
      throw FormatException('不是 ZIP：找不到中央目录结尾记录');
    }
    final entries = _u16(tail, eocdOffset + 10);
    final directorySize = _u32(tail, eocdOffset + 12);
    final directoryOffset = _u32(tail, eocdOffset + 16);
    if (entries == 0xFFFF ||
        directoryOffset == 0xFFFFFFFF ||
        directorySize == 0xFFFFFFFF) {
      throw UnsupportedError('ZIP64 暂不支持（APK 正常不会用到）');
    }

    raf.setPositionSync(directoryOffset);
    final directory = raf.readSync(directorySize);
    return _parseCentralDirectory(directory);
  } finally {
    raf.closeSync();
  }
}

int _findEndOfCentralDirectory(Uint8List tail) {
  for (var index = tail.length - 22; index >= 0; index--) {
    if (_u32(tail, index) == _endOfCentralDirectorySignature) return index;
  }
  return -1;
}

List<ZipEntryInfo> _parseCentralDirectory(Uint8List directory) {
  final result = <ZipEntryInfo>[];
  var offset = 0;
  while (offset + 46 <= directory.length) {
    if (_u32(directory, offset) != _centralFileHeaderSignature) break;
    final compressed = _u32(directory, offset + 20);
    final uncompressed = _u32(directory, offset + 24);
    final nameLength = _u16(directory, offset + 28);
    final extraLength = _u16(directory, offset + 30);
    final commentLength = _u16(directory, offset + 32);
    final nameStart = offset + 46;
    final name = String.fromCharCodes(
      directory.sublist(nameStart, nameStart + nameLength),
    );
    result.add(
      ZipEntryInfo(
        name: name,
        compressedSize: compressed,
        uncompressedSize: uncompressed,
      ),
    );
    offset = nameStart + nameLength + extraLength + commentLength;
  }
  return result;
}

int _u16(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.little);

int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
