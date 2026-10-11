import 'dart:typed_data';

/// Web 平台占位：builtin 平台歌词解码（KRC/LRCX/QRC/MRC）依赖 zlib，
/// Web 上优雅降级为「无原生歌词」（调用方捕获异常后回退名字搜索）。
List<int> zlibInflate(List<int> data) {
  throw UnsupportedError('zlib is not available on this platform');
}

Uint8List zlibInflateTolerant(List<int> data) {
  throw UnsupportedError('zlib is not available on this platform');
}

List<int> zlibDeflate(List<int> data) {
  throw UnsupportedError('zlib is not available on this platform');
}
