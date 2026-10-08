/// `.lxmc` 收藏夹解码入口：IO 平台（gzip + JSON），Web 返回不支持。
library;

import 'dart:typed_data';

import 'lxmc_decoder_models.dart';
import 'lxmc_decoder_stub.dart'
    if (dart.library.io) 'lxmc_decoder_io.dart' as impl;

export 'lxmc_decoder_models.dart';

/// 解码 LX Music 收藏夹导出文件（`.lxmc`，gzip 压缩的 JSON）。
///
/// 校验根节点 `type == playListPart_v2`；非法/非 gzip/非该类型时抛
/// [LxmcDecodeException]（reason：`unsupported` / `not_gzip` / `invalid_json`
/// / `not_play_list`）。
LxmcDecodedPlaylist decodeLxmcBytes(Uint8List bytes, {String? fileName}) =>
    impl.decodeLxmcBytes(bytes, fileName: fileName);
