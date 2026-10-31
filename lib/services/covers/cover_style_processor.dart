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

/// 生产处理器：`processSync` 是纯 Dart 像素入口，`process` 走长驻 isolate。
class CoverStyleProcessor implements CoverStyleProcessorPort {
  CoverStyleProcessor();

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
    return _starting ??= _start();
  }

  Future<SendPort> _start() async {
    final receive = ReceivePort();
    _inbox = receive;
    final ready = Completer<SendPort>();
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
    final errors = ReceivePort();
    final isolate = await Isolate.spawn(
      _renderWorker,
      receive.sendPort,
      debugName: 'molia-cover-style',
      onError: errors.sendPort,
      onExit: errors.sendPort,
    );
    _isolate = isolate;
    _isolateEvents = errors.listen((_) {
      _worker = null;
      _starting = null;
      if (!ready.isCompleted) {
        ready.completeError(StateError('封面风格 worker 启动失败'));
      }
      _failPending();
    });
    final port = await ready.future;
    _worker = port;
    return port;
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
