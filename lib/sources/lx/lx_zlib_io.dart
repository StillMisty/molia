import 'dart:io';

/// 原生平台 zlib 实现（同步），对应 Node.js 的 zlib.inflate / zlib.deflate。
List<int> zlibInflate(List<int> data) => zlib.decode(data);

List<int> zlibDeflate(List<int> data) => zlib.encode(data);
