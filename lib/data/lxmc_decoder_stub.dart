/// `.lxmc` 解码的 Web/不支持平台实现（gzip 依赖 dart:io）。
library;

import 'dart:typed_data';

import 'lxmc_decoder_models.dart';

LxmcDecodedPlaylist decodeLxmcBytes(Uint8List bytes, {String? fileName}) {
  throw const LxmcDecodeException('unsupported');
}
