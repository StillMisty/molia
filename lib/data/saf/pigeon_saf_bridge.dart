/// SAF 的 Pigeon bridge 与旧通道 fallback 组合（issue #85）。
///
/// [PigeonSafBridge] 把生成的 Pigeon transport 映射成 data 层的 [SafBridge]；
/// [PigeonFirstSafBridge] 在 Android 上优先 Pigeon，连接层失败时回退旧
/// `MethodChannelSafBridge`。平台层不 import data，本文件是唯一的组合点。
library;

import 'dart:async';
import 'dart:typed_data';

import '../../platform/pigeon/saf_adapter.dart';
import 'method_channel_saf_bridge.dart';
import 'saf_bridge.dart';

/// 把 Pigeon 消息映射成 [SafBridge] 端口。
class PigeonSafBridge implements SafBridge {
  PigeonSafBridge(this._transport);

  final SafPigeonTransport _transport;

  /// 每页条目数，与旧通道一致（本地 provider 一次目录查询通常远小于它）。
  static const int batchSize = MethodChannelSafBridge.batchSize;

  @override
  Future<SafDocument?> stat(String uri) async {
    final message = await _guard(() => _transport.stat(uri));
    if (message == null) return null;
    return SafDocument(
      uri: message.uri.isNotEmpty ? message.uri : uri,
      displayName: message.displayName.trim(),
      isDirectory: message.isDirectory,
      sizeBytes: message.sizeBytes,
      mtimeMs: message.mtimeMs,
    );
  }

  @override
  Stream<SafTreeEvent> listTree(
    String uri, {
    required int maxDepth,
    bool Function()? isCancelled,
  }) async* {
    final token = await _guard(() => _transport.listTreeBegin(uri, maxDepth));
    if (token == null) {
      throw const SafBridgeException(
        SafFailureKind.unsupported,
        'listTreeBegin returned no token',
      );
    }
    try {
      while (isCancelled?.call() != true) {
        final batch = await _guard(
          () => _transport.listTreeNext(token, batchSize),
        );
        if (batch == null) break;
        for (final item in batch.entries) {
          final skip = item.skip;
          if (skip != null && skip.isNotEmpty) {
            yield SafTreeSkipped(skip, item.relativePath);
            continue;
          }
          yield SafTreeEntry(
            uri: item.uri,
            displayName: item.name,
            relativePath: item.relativePath,
            isDirectory: item.isDirectory,
            sizeBytes: item.sizeBytes,
            mtimeMs: item.mtimeMs,
          );
        }
        if (batch.done) break;
      }
    } finally {
      await _close(token);
    }
  }

  @override
  Future<Uint8List?> readHead(String uri, int length) async {
    if (length <= 0) return Uint8List(0);
    return _guard(() => _transport.readHead(uri, length));
  }

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) async {
    if (start < 0 || length < 0) return null;
    return _guard(() => _transport.readRange(uri, start, length));
  }

  /// 关闭失败只影响 native 会话回收，扫描结果已经拿到；不能覆盖原始错误。
  Future<void> _close(String token) async {
    try {
      await _transport.listTreeClose(token);
    } catch (_) {}
  }

  /// 业务错误 → [SafBridgeException]；连接层失败保持原类型，交给组合层回退。
  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on SafPigeonException catch (e) {
      throw SafBridgeException(_kindOf(e.code), e.message);
    }
  }

  static SafFailureKind _kindOf(String code) => switch (code) {
    'MISSING' => SafFailureKind.missing,
    'PERMISSION_DENIED' => SafFailureKind.permissionDenied,
    'UNSUPPORTED' => SafFailureKind.unsupported,
    _ => SafFailureKind.io,
  };
}

/// Pigeon 优先、旧通道兜底的 [SafBridge]。
///
/// 只有 transport 连接层失败才回退旧通道；原生业务错误（权限撤销 / 文件
/// 缺失）直接按 [SafBridgeException] 上抛，换 transport 不会改变结果。
///
/// 流式 `listTree` 只在**首批之前**失败时回退：一旦已经向调用方产出条目，
/// 中途换 transport 会从头重扫并造成重复条目，因此中途失败统一抛
/// [SafBridgeException]，由调用方整轮作废。
class PigeonFirstSafBridge implements SafBridge {
  PigeonFirstSafBridge({
    required SafPigeonTransport pigeon,
    SafBridge? fallback,
  }) : _transport = pigeon,
       _pigeon = PigeonSafBridge(pigeon),
       _fallback = fallback ?? MethodChannelSafBridge();

  final SafPigeonTransport _transport;
  final PigeonSafBridge _pigeon;
  final SafBridge _fallback;

  @override
  Future<SafDocument?> stat(String uri) => _viaPigeonOrFallback(
    primary: () => _pigeon.stat(uri),
    fallback: () => _fallback.stat(uri),
  );

  @override
  Future<Uint8List?> readHead(String uri, int length) => _viaPigeonOrFallback(
    primary: () => _pigeon.readHead(uri, length),
    fallback: () => _fallback.readHead(uri, length),
  );

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) =>
      _viaPigeonOrFallback(
        primary: () => _pigeon.readRange(uri, start, length),
        fallback: () => _fallback.readRange(uri, start, length),
      );

  @override
  Stream<SafTreeEvent> listTree(
    String uri, {
    required int maxDepth,
    bool Function()? isCancelled,
  }) async* {
    if (!_transport.transportAvailable) {
      yield* _fallback.listTree(
        uri,
        maxDepth: maxDepth,
        isCancelled: isCancelled,
      );
      return;
    }
    final iterator = StreamIterator<SafTreeEvent>(
      _pigeon.listTree(uri, maxDepth: maxDepth, isCancelled: isCancelled),
    );
    try {
      final bool hasFirst;
      try {
        hasFirst = await iterator.moveNext();
      } on SafTransportUnavailable {
        // 首批之前失败：还没有产出任何条目，回退不会重复。
        await iterator.cancel();
        yield* _fallback.listTree(
          uri,
          maxDepth: maxDepth,
          isCancelled: isCancelled,
        );
        return;
      }
      if (!hasFirst) return;
      yield iterator.current;
      while (true) {
        final bool hasNext;
        try {
          hasNext = await iterator.moveNext();
        } on SafTransportUnavailable catch (e) {
          throw SafBridgeException(SafFailureKind.io, e.message);
        }
        if (!hasNext) break;
        yield iterator.current;
      }
    } finally {
      await iterator.cancel();
    }
  }

  /// 正常完成才算 Pigeon 成功；连接层失败（含适配器已标记不可用）回退。
  Future<T> _viaPigeonOrFallback<T>({
    required Future<T> Function() primary,
    required Future<T> Function() fallback,
  }) async {
    if (_transport.transportAvailable) {
      try {
        return await primary();
      } on SafTransportUnavailable {
        // transport 缺失：落到旧通道。
      }
    }
    return fallback();
  }
}
