/// 统计载荷编解码入口：`play_tracks.raw` 以 gzip(JSON) 存 BLOB。
///
/// 见 `stats_payload_codec_io.dart`（IO 实现）。
library;

import 'dart:typed_data';

import 'stats_payload_codec_io.dart' as impl;

/// JSON 文本 → 存储字节（gzip）；空文本 → null（无载荷）。
Uint8List? encodeStatsPayload(String json) => impl.encodeStatsPayload(json);

/// 存储字节 → JSON 文本；空 / 损坏 → 空串（调用方按「无载荷」处理）。
String decodeStatsPayload(Object? bytes) => impl.decodeStatsPayload(bytes);
