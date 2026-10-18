/// 记录集内容指纹（`snapshotId`）：跨设备比对「内容是否一致」的唯一口径。
///
/// 语义：逐类别按键排序后流式喂进 SHA-256（与集合顺序无关；同一记录集在任何
/// 设备上得到同一个值）。**不是密码学用途**——它只表达「内容变了没有」，
/// 但对端用它比对静默分歧，因此必须逐字节确定。
///
/// 为什么流式：一次全库指纹是本轮唯一遍历全库的 CPU 工作，旧实现先拼一个
/// 覆盖整库的 StringBuffer 再整体 UTF-8 编码（峰值内存 ≈ 明文 3 份）；
/// 流式喂入省掉这两次大分配，也让它可以整体放进 worker isolate 执行
/// （见 `sync_codec_isolate.dart` 的 fingerprint 操作）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../domain/models/device_sync.dart';

/// 记录集指纹（见文件头）。
String syncFingerprint(Map<SyncCategory, List<SyncRecord>> records) {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  const separator = 0x01;
  const newline = 0x0a;
  for (final category in SyncCategory.values) {
    final list = records[category];
    if (list == null || list.isEmpty) continue;
    final sorted = [...list]..sort((a, b) => a.key.compareTo(b.key));
    for (final record in sorted) {
      input.add(utf8.encode(category.name));
      input.add(const [separator]);
      input.add(utf8.encode(record.key));
      input.add(const [separator]);
      input.add(utf8.encode(record.version.physical.toString()));
      input.add(const [separator]);
      input.add(utf8.encode(record.version.counter.toString()));
      input.add(const [separator]);
      input.add(utf8.encode(record.version.deviceId));
      input.add(const [separator]);
      input.add(Uint8List.fromList([record.deleted ? 0x31 : 0x30]));
      input.add(const [separator]);
      final data = record.data;
      if (data != null) input.add(utf8.encode(jsonEncode(data)));
      input.add(const [newline]);
    }
  }
  input.close();
  return sink.value.toString();
}

/// 只收一个摘要的 sink（`package:convert` 的 `AccumulatorSink` 等价物，
/// 避免为了一个容器引入新依赖）。
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
