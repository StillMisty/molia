/// 封面风格处理器：主 isolate 只做取图 / 缓存编排，像素计算放进长驻 worker。
///
/// 为什么不是每张图 `Isolate.run`：列表一次可见几十张缩略图，每张都新起
/// isolate 会把启动开销放大到与像素计算同量级；长驻 worker 只在第一次处理时
/// 启动，之后复用同一条消息通道。worker 崩溃时在途请求立即返回 null，下一次
/// 调用自动重新拉起（自愈），展示层始终可以回退原图。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../../domain/models/cover_style.dart';
import 'cover_style_renderer.dart';

/// 处理器端口：测试注入 fake，避免真的起 isolate。
abstract interface class CoverStyleProcessorPort {
  Future<Uint8List?> process(
    Uint8List source, {
    required CoverStyle style,
    required int edge,
  });
}

/// worker 启动器（单测注入：验证启动失败后的自愈路径）。
typedef CoverStyleWorkerSpawner = Future<Isolate> Function(
  void Function(SendPort) entryPoint,
  SendPort message,
  SendPort errorPort,
);

Future<Isolate> _spawnCoverStyleWorker(
  void Function(SendPort) entryPoint,
  SendPort message,
  SendPort errorPort,
) => Isolate.spawn(
  entryPoint,
  message,
  debugName: 'molia-cover-style',
  onError: errorPort,
  onExit: errorPort,
);

/// 生产处理器：`processSync` 是纯 Dart 像素入口，`process` 走长驻 isolate。
class CoverStyleProcessor implements CoverStyleProcessorPort {
  CoverStyleProcessor({CoverStyleWorkerSpawner? spawner})
    : _spawner = spawner ?? _spawnCoverStyleWorker;

  final CoverStyleWorkerSpawner _spawner;

  Isolate? _isolate;
  SendPort? _worker;
  ReceivePort? _inbox;
  StreamSubscription<dynamic>? _isolateEvents;
  Future<SendPort>? _starting;
  final Map<int, Completer<_RenderReply>> _pending = {};
  int _nextId = 0;
  bool _disposed = false;

  /// worker 是否已就绪（单测用；未启动 / 已退出为 false）。
  bool get workerReady => _worker != null;

  @override
  Future<Uint8List?> process(
    Uint8List source, {
    required CoverStyle style,
    required int edge,
  }) async {
    if (_disposed || !style.isStylized || source.isEmpty) return null;
    try {
      final worker = await _ensureWorker();
      if (_disposed) return null;
      final id = _nextId++;
      final completer = Completer<_RenderReply>();
      _pending[id] = completer;
      worker.send(_RenderRequest(id, source, style.id, edge));
      final reply = await completer.future;
      return reply.bytes;
    } catch (_) {
      return null;
    }
  }

  /// 同步实现（测试 / 已在 worker 内时使用）：非法字节或处理失败返回 null。
  static Uint8List? processSync(
    Uint8List bytes, {
    required CoverStyle style,
    required int edge,
  }) {
    return CoverStyleRenderer.render(bytes, style: style, edge: edge);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failPending();
    await _isolateEvents?.cancel();
    _isolateEvents = null;
    _inbox?.close();
    _inbox = null;
    _worker = null;
    _starting = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  Future<SendPort> _ensureWorker() {
    final ready = _worker;
    if (ready != null) return Future.value(ready);
    final starting = _starting;
    if (starting != null) return starting;
    final attempt = _start();
    _starting = attempt;
    // 启动失败必须清掉缓存 future，否则后续调用会永远拿到同一个失败结果，
    // worker 再也无法重新拉起。成功时 worker 已就绪，清空也不影响复用。
    attempt.whenComplete(() {
      if (identical(_starting, attempt)) _starting = null;
    }).ignore();
    return attempt;
  }

  Future<SendPort> _start() async {
    final receive = ReceivePort();
    final errors = ReceivePort();
    _inbox = receive;
    final ready = Completer<SendPort>();
    // 启动失败可能发生在 await ready.future 之前；先认领错误，避免
    // completeError 在无人监听时变成未处理异步异常。
    ready.future.ignore();
    StreamSubscription<dynamic>? events;
    Isolate? isolate;
    try {
      receive.listen((message) {
        if (message is _RenderReply) {
          final completer = _pending.remove(message.id);
          if (completer != null && !completer.isCompleted) {
            completer.complete(message);
          }
        } else if (message is SendPort) {
          if (!ready.isCompleted) ready.complete(message);
        }
      });
      isolate = await _spawner(
        _renderWorker,
        receive.sendPort,
        errors.sendPort,
      );
      _isolate = isolate;
      if (_disposed) throw StateError('封面风格处理器已释放');
      events = errors.listen((_) {
        // 只处理当前 worker 的退出事件；旧 worker 的迟到事件不能清掉新 worker。
        if (!identical(_isolate, isolate)) return;
        _worker = null;
        _starting = null;
        _isolate = null;
        _isolateEvents = null;
        if (identical(_inbox, receive)) _inbox = null;
        if (!ready.isCompleted) {
          ready.completeError(StateError('封面风格 worker 启动失败'));
        }
        _failPending();
        unawaited(events?.cancel());
        errors.close();
        receive.close();
      });
      _isolateEvents = events;
      final port = await ready.future;
      _worker = port;
      return port;
    } catch (error) {
      await events?.cancel();
      if (identical(_isolateEvents, events)) _isolateEvents = null;
      errors.close();
      receive.close();
      if (identical(_inbox, receive)) _inbox = null;
      if (isolate != null) {
        if (identical(_isolate, isolate)) _isolate = null;
        isolate.kill(priority: Isolate.immediate);
      }
      _worker = null;
      _starting = null;
      rethrow;
    }
  }

  void _failPending() {
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete(const _RenderReply(-1));
    }
  }
}

void _renderWorker(SendPort mainPort) {
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! _RenderRequest) return;
    Uint8List? bytes;
    try {
      bytes = CoverStyleProcessor.processSync(
        message.source,
        style: CoverStyle.fromId(message.styleId),
        edge: message.edge,
      );
    } catch (_) {
      bytes = null;
    }
    mainPort.send(_RenderReply(message.id, bytes: bytes));
  });
}

class _RenderRequest {
  const _RenderRequest(this.id, this.source, this.styleId, this.edge);

  final int id;
  final Uint8List source;
  final String styleId;
  final int edge;
}

class _RenderReply {
  const _RenderReply(this.id, {this.bytes});

  final int id;
  final Uint8List? bytes;
}
