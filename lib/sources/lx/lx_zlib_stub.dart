/// Web 平台占位实现：LX 音源引擎不支持 Web。
List<int> zlibInflate(List<int> data) {
  throw UnsupportedError('zlib is not available on this platform');
}

List<int> zlibDeflate(List<int> data) {
  throw UnsupportedError('zlib is not available on this platform');
}
