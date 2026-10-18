/// 载荷编解码端口：传输层只依赖它。
///
/// 生产实现是 worker isolate（`sync_codec_isolate.dart`）：载荷编码 / 压缩 /
/// PBKDF2 / AES-GCM 都是纯计算，放到独立 isolate 后**不占 UI isolate 的帧**
/// （PBKDF2 120k 纯 Dart 在手机上是数百毫秒到秒级；整库快照的编码与压缩同理）。
/// 单测用 [InlineSyncCodecPort]（同步执行、无 isolate，便于断言内部状态）。
library;

import 'dart:typed_data';

import '../../domain/models/device_sync.dart';
import 'sync_crypto.dart';
import 'sync_fingerprint.dart';

abstract interface class SyncCodecPort {
  /// 编码一份载荷（帧字节）。
  Future<Uint8List> encrypt(SyncEnvelope envelope, String passphrase);

  /// 解码一份帧；口令 / 认证 / 载荷结构失败抛 [SyncCryptoException]。
  Future<SyncEnvelope> decrypt(Uint8List bytes, String passphrase);

  /// 记录集内容指纹（`snapshotId`）：引擎每轮按需重算，也是全库遍历的 CPU 工作。
  Future<String> fingerprint(Map<SyncCategory, List<SyncRecord>> records);

  /// 释放底层资源（worker isolate 等）；重复调用幂等。
  Future<void> dispose();
}

/// 进程内实现（单测与需要同步语义的调用方）。
class InlineSyncCodecPort implements SyncCodecPort {
  InlineSyncCodecPort(this.codec);

  final SyncCodec codec;

  @override
  Future<Uint8List> encrypt(SyncEnvelope envelope, String passphrase) async =>
      codec.encrypt(envelope, passphrase);

  @override
  Future<SyncEnvelope> decrypt(Uint8List bytes, String passphrase) async =>
      codec.decrypt(bytes, passphrase);

  @override
  Future<String> fingerprint(Map<SyncCategory, List<SyncRecord>> records) async =>
      syncFingerprint(records);

  @override
  Future<void> dispose() async {}
}
