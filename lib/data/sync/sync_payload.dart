/// 帧内载荷编码：`SyncEnvelope` ⇄ 明文字节。
///
/// 编码标识随帧携带（见 `sync_crypto.dart` 的明文头），取值见
/// [SyncPayloadCodec]：
/// - [SyncPayloadCodec.binary]：列式二进制，**线上唯一格式**
///   （见 `sync_payload_binary.dart`）；
/// - [SyncPayloadCodec.json]：JSON 文本，只服务测试对照与排障渲染，不参与
///   线上；完整备份走 `SyncEnvelope.toJson`（同一模型、不经帧层）。
///
/// 为什么保留 JSON 编码：二进制编解码用它做**双向对照测试**（同一 envelope
/// 两种编码往返必须等价），排障时也能把线上载荷渲染回可读文本。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../domain/models/device_sync.dart';
import 'sync_payload_binary.dart';
import 'sync_payload_format.dart';

export 'sync_payload_format.dart' show SyncPayloadCodec, SyncPayloadFormatException;

/// 载荷编码入口（`SyncCodec` 只依赖它，不直接接触 JSON 或列式细节）。
abstract final class SyncPayload {
  /// 线上默认编码。
  static const int wireCodec = SyncPayloadCodec.binary;

  static Uint8List encode(SyncEnvelope envelope, {int codec = wireCodec}) =>
      switch (codec) {
        SyncPayloadCodec.binary => SyncPayloadBinary.encode(envelope),
        SyncPayloadCodec.json => Uint8List.fromList(
            utf8.encode(jsonEncode(envelope.toJson())),
          ),
        _ => throw SyncPayloadFormatException('未知载荷编码: $codec'),
      };

  static SyncEnvelope decode(Uint8List bytes, {required int codec}) {
    try {
      return switch (codec) {
        SyncPayloadCodec.binary => SyncPayloadBinary.decode(bytes),
        SyncPayloadCodec.json => _requireEnvelope(jsonDecode(utf8.decode(bytes))),
        _ => throw SyncPayloadFormatException('未知载荷编码: $codec'),
      };
    } on SyncPayloadFormatException {
      rethrow;
    } catch (e) {
      throw SyncPayloadFormatException('载荷解析失败: $e');
    }
  }

  static SyncEnvelope _requireEnvelope(Object? raw) {
    final envelope = SyncEnvelope.fromJson(raw);
    if (envelope == null) throw const SyncPayloadFormatException('载荷结构无效');
    return envelope;
  }
}
