/// worker isolate 版载荷编解码端口：主 isolate 只做 I/O 与编排。
///
/// 为什么长驻 isolate 而不是每次 `Isolate.run`：
/// - `SyncCodec` 的根密钥按口令缓存（PBKDF2 120k 只派生一次），`Isolate.run`
///   每次调用都是新 isolate，缓存与派生都要重来；
/// - 一轮同步里编解码会被调用多次（每对端拉 / 推各一次），长驻省掉重复启动。
///
/// 同一 isolate group 内的消息按引用传递：`SyncEnvelope` / `Uint8List` 不做
/// 深拷贝，跨边界成本可忽略。worker 异常退出时在途请求立即失败（不挂起），
/// 下一次调用重新拉起（自愈）。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import 'sync_codec_port.dart';
import 'sync_crypto.dart';
import 'sync_fingerprint.dart';

/// 请求操作码（跨 isolate 消息里只传 int）。
abstract final class _CodecOp {
  static const int encrypt = 0;
  static const int decrypt = 1;
  static const int fingerprint = 2;
}

class IsolateSyncCodecPort implements SyncCodecPort {
  IsolateSyncCodecPort({this.iterations = 120000});

  /// PBKDF2 迭代数（测试注入小值避免慢测）。
  final int iterations;

  final Logger _logger = Logger('molia.sync.codec');
  final Map<int, Completer<_CodecReply>> _pending = {};
  Isolate? _isolate;
  SendPort? _worker;
  ReceivePort? _inbox;
  StreamSubscription<dynamic>? _isolateEvents;
  Future<SendPort>? _starting;
  int _nextId = 0;
  bool _disposed = false;

  /// worker 是否已就绪（单测用；未启动 / 已退出为 false）。
  @visibleForTesting
  bool get workerReady => _worker != null;

  @override
  Future<Uint8List> encrypt(SyncEnvelope envelope, String passphrase) async {
    final reply = await _send(
      _CodecOp.encrypt,
      envelope: envelope,
      passphrase: passphrase,
    );
    return reply.bytes!;
  }

  @override
  Future<SyncEnvelope> decrypt(Uint8List bytes, String passphrase) async {
    final reply = await _send(
      _CodecOp.decrypt,
      bytes: bytes,
      passphrase: passphrase,
    );
    return reply.envelope!;
  }

  @override
  Future<String> fingerprint(Map<SyncCategory, List<SyncRecord>> records) async {
    final reply = await _send(
      _CodecOp.fingerprint,
      records: records,
      passphrase: '',
    );
    return reply.fingerprint!;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failPending(StateError('同步编码端口已释放'));
    await _isolateEvents?.cancel();
    _isolateEvents = null;
    _inbox?.close();
    _inbox = null;
    _worker = null;
    _starting = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  Future<_CodecReply> _send(
    int op, {
    SyncEnvelope? envelope,
    Uint8List? bytes,
    Map<SyncCategory, List<SyncRecord>>? records,
    required String passphrase,
  }) async {
    if (_disposed) throw StateError('同步编码端口已释放');
    final worker = await _ensureWorker();
    final id = _nextId++;
    final completer = Completer<_CodecReply>();
    _pending[id] = completer;
    worker.send(_CodecRequest(
      id,
      op,
      passphrase,
      envelope: envelope,
      bytes: bytes,
      records: records,
    ));
    final reply = await completer.future;
    final error = reply.error;
    if (error != null) throw SyncCryptoException(error);
    return reply;
  }

  Future<SendPort> _ensureWorker() {
    final ready = _worker;
    if (ready != null) return Future.value(ready);
    return _starting ??= _start();
  }

  Future<SendPort> _start() async {
    final receive = ReceivePort();
    _inbox = receive;
    final ready = Completer<SendPort>();
    receive.listen((message) {
      if (message is _CodecReply) {
        _pending.remove(message.id)?.complete(message);
      } else if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      }
    });
    final errors = ReceivePort();
    final isolate = await Isolate.spawn(
      _codecWorker,
      <Object?>[receive.sendPort, iterations],
      debugName: 'molia-sync-codec',
      onError: errors.sendPort,
      onExit: errors.sendPort,
    );
    _isolate = isolate;
    _isolateEvents = errors.listen((event) {
      // isolate 退出 / 未捕获异常：在途请求立即失败，下一次调用重新拉起。
      _logger.warning('同步编码 isolate 退出（下一次调用重新拉起）', event);
      _worker = null;
      _starting = null;
      if (!ready.isCompleted) {
        ready.completeError(StateError('同步编码 isolate 启动失败: $event'));
      }
      _failPending(StateError('同步编码 isolate 已退出: $event'));
    });
    final port = await ready.future;
    _worker = port;
    return port;
  }

  void _failPending(Object error) {
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}

/// worker 主函数：持有唯一 `SyncCodec`（根密钥缓存跨请求复用）。
void _codecWorker(List<Object?> args) {
  final mainPort = args[0] as SendPort;
  final iterations = args[1] as int;
  final codec = SyncCodec(iterations: iterations);
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! _CodecRequest) return;
    final reply = _CodecReply(message.id);
    try {
      switch (message.op) {
        case _CodecOp.encrypt:
          reply.bytes = codec.encrypt(message.envelope!, message.passphrase);
        case _CodecOp.decrypt:
          reply.envelope = codec.decrypt(message.bytes!, message.passphrase);
        case _CodecOp.fingerprint:
          reply.fingerprint = syncFingerprint(message.records!);
      }
    } on SyncCryptoException catch (e) {
      reply.error = e.message;
    } catch (e) {
      reply.error = '$e';
    }
    mainPort.send(reply);
  });
}

/// 编解码请求（同一 isolate group 内按引用传递，不做深拷贝）。
class _CodecRequest {
  const _CodecRequest(
    this.id,
    this.op,
    this.passphrase, {
    this.envelope,
    this.bytes,
    this.records,
  });

  final int id;
  final int op;
  final String passphrase;
  final SyncEnvelope? envelope;
  final Uint8List? bytes;
  final Map<SyncCategory, List<SyncRecord>>? records;
}

/// 编解码应答（error 非空即为失败原因）。
class _CodecReply {
  _CodecReply(this.id);

  final int id;
  Uint8List? bytes;
  SyncEnvelope? envelope;
  String? fingerprint;
  String? error;
}
