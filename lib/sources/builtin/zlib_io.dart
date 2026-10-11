import 'dart:io';
import 'dart:typed_data';

/// 原生平台 zlib 实现（builtin 平台取词解码用；Web 见 stub）。

/// 标准 zlib inflate（完整流）。
List<int> zlibInflate(List<int> data) => zlib.decode(data);

/// zlib deflate（QRC 加解密往返测试用）。
List<int> zlibDeflate(List<int> data) => zlib.encode(data);

/// 容忍尾部截断的 zlib inflate（对应 pako 的 `Z_SYNC_FLUSH` 语义）。
///
/// QRC 歌词流可能不完整收尾，`zlib.decode` 会整体失败；`RawZLibFilter`
/// 允许保留已解出的部分（LX `qrcDecode.js` 依赖同一行为）。
Uint8List zlibInflateTolerant(List<int> data) {
  final filter = RawZLibFilter.inflateFilter();
  final out = BytesBuilder(copy: false);
  try {
    filter.process(data, 0, data.length);
    while (true) {
      final chunk = filter.processed(flush: true);
      if (chunk == null || chunk.isEmpty) break;
      out.add(chunk);
    }
  } catch (_) {
    // 流截断/尾部损坏：保留已解出的内容。
  }
  return out.takeBytes();
}
