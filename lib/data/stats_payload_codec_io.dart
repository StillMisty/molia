/// 统计载荷的 IO 实现（gzip + UTF-8 JSON）。
///
/// 为什么压：载荷是取链参数的完整 JSON——LX 脚本原样透传平台对象时单条
/// 2–8 KB，保留窗口（20k 行 / 365 天）内是库里最大的可压缩块。实测 gzip(6)：
/// 平台对象 3.6 KB → 1.4 KB（39%）、内置平台载荷 693 B → 387 B（56%）。
/// 读取侧只在「明细点播 / 同步导出」解压，量级是每曲一次。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// JSON 文本 → 存储字节（gzip）；空文本 → null（无载荷）。
Uint8List? encodeStatsPayload(String json) {
  if (json.isEmpty) return null;
  return Uint8List.fromList(gzip.encode(utf8.encode(json)));
}

/// 存储字节 → JSON 文本；空 / 损坏 → 空串（调用方按「无载荷」处理）。
String decodeStatsPayload(Object? bytes) {
  final data = switch (bytes) {
    Uint8List value => value,
    List<int> value => Uint8List.fromList(value),
    _ => null,
  };
  if (data == null || data.isEmpty) return '';
  // gzip 魔数（0x1f 0x8b）：v5 迁移前的载荷是明文 UTF-8，手动降级读一次，
  // 不让历史行（或迁移中断留下的明文）整条失效。
  if (data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b) {
    try {
      return utf8.decode(gzip.decode(data), allowMalformed: true);
    } on Object {
      return '';
    }
  }
  try {
    return utf8.decode(data, allowMalformed: true);
  } on Object {
    return '';
  }
}
