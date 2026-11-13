/// 轮转文件日志 sink：异步队列 + 有界回退 + 脱敏后落盘。
///
/// 只挂在组合根（生产）与显式构造的测试里；控制台输出仍由
/// `app_logging.dart` 负责，本模块永远不调用 `Logger` / `debugPrint`，
/// 避免“记录失败又写日志”的递归。
///
/// 预算：单文件 [maxBytes]（默认 5 MB）× [maxFiles]（默认 3，含活动文件）。
/// 写入按队列异步执行，调用方（`package:logging` 的监听回调）从不等待磁盘；
/// 首次写入才解析应用数据目录，启动与播放路径不被目录解析阻塞。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'redaction.dart';

/// sink 状态（设置页只需区分“正在记录 / 不可用”）。
enum DiagnosticLogStatus { recording, unavailable, stopped }

/// 文件操作端口：生产用 [IoDiagnosticLogStore]，测试可注入抛异常 / 慢写入实现。
abstract interface class DiagnosticLogStore {
  Future<bool> exists(String path);
  Future<int> length(String path);
  Future<void> delete(String path);
  Future<void> rename(String from, String to);
  Future<void> writeAppend(String path, String text);
  Future<void> replace(String path, String text);

  /// 读取文件末尾最多 [maxBytes] 字节（启动时裁剪超限活动文件用）。
  Future<List<int>> readTail(String path, int maxBytes);
}

/// 默认 `dart:io` 实现。
class IoDiagnosticLogStore implements DiagnosticLogStore {
  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<int> length(String path) => File(path).length();

  @override
  Future<void> delete(String path) => File(path).delete();

  @override
  Future<void> rename(String from, String to) => File(from).rename(to);

  @override
  Future<void> writeAppend(String path, String text) =>
      File(path).writeAsString(text, mode: FileMode.append, flush: true);

  @override
  Future<void> replace(String path, String text) =>
      File(path).writeAsString(text, mode: FileMode.write, flush: true);

  @override
  Future<List<int>> readTail(String path, int maxBytes) async {
    final file = File(path);
    final length = await file.length();
    final start = length > maxBytes ? length - maxBytes : 0;
    final handle = await file.open();
    try {
      await handle.setPosition(start);
      return await handle.read(length - start);
    } finally {
      await handle.close();
    }
  }
}

/// 一条待落盘记录（已在入队时脱敏 / 截断）。
class _PendingLine {
  const _PendingLine(this.text, this.priority);

  final String text;
  final int priority;
}

/// 轮转文件日志 sink。
class RotatingFileLogSink {
  RotatingFileLogSink({
    required Future<Directory> Function() directory,
    DiagnosticLogStore? store,
    this.maxBytes = 5 * 1024 * 1024,
    this.maxFiles = 3,
    this.maxMessageBytes = 16 * 1024,
    this.backlogLimit = 256,
    this.flushInterval = const Duration(seconds: 1),
    this.maxConsecutiveFailures = 3,
    DateTime Function()? now,
  }) : assert(maxBytes > 0),
       assert(maxFiles >= 2),
       assert(backlogLimit > 0),
       _directory = directory,
       _store = store ?? IoDiagnosticLogStore(),
       _now = now ?? DateTime.now;

  final Future<Directory> Function() _directory;
  final DiagnosticLogStore _store;
  final int maxBytes;
  final int maxFiles;
  final int maxMessageBytes;
  final int backlogLimit;
  final Duration flushInterval;
  final int maxConsecutiveFailures;
  final DateTime Function() _now;

  final ListQueue<_PendingLine> _queue = ListQueue();
  StreamSubscription<LogRecord>? _subscription;
  DiagnosticLogStatus _status = DiagnosticLogStatus.recording;
  String? _activePath;
  int _activeSize = 0;
  bool _closed = false;
  bool _draining = false;
  Future<void>? _drainFuture;
  Timer? _flushTimer;
  DateTime? _lastWriteAt;
  int _consecutiveFailures = 0;
  int _droppedLines = 0;

  DiagnosticLogStatus get status => _status;

  bool get isRecording => _status == DiagnosticLogStatus.recording;

  /// 活动文件名（导出时按目录列出即可，这里只用于测试 / 文档）。
  static const String activeFileName = 'molia.log';

  static String archiveFileName(int index) => 'molia.$index.log';

  /// 挂到日志流；失败只影响文件记录，不向日志流抛异常。
  void attach(Stream<LogRecord> records) {
    if (_closed || _subscription != null) return;
    _subscription = records.listen(_onRecord, onError: (Object _) {});
  }

  bool shouldPersist(LogRecord record) {
    final isMolia =
        record.loggerName == 'molia' || record.loggerName.startsWith('molia.');
    if (isMolia) return record.level.value >= Level.FINE.value;
    return record.level.value >= Level.INFO.value;
  }

  void _onRecord(LogRecord record) {
    if (_closed || _status != DiagnosticLogStatus.recording) return;
    if (!shouldPersist(record)) return;
    _enqueue(_PendingLine(_formatRecord(record), _priority(record.level)));
  }

  static int _priority(Level level) {
    if (level.value >= Level.SEVERE.value) return 3;
    if (level.value >= Level.WARNING.value) return 2;
    if (level.value >= Level.INFO.value) return 1;
    return 0;
  }

  String _formatRecord(LogRecord record) {
    final buffer = StringBuffer()
      ..write(_formatDate(record.time))
      ..write(' ')
      ..write(record.level.name.padRight(7))
      ..write(' ')
      ..write(record.loggerName)
      ..write(': ')
      ..write(_cap(redactSecrets(record.message)));
    final error = record.error;
    if (error != null) {
      buffer
        ..write('\n    error: ')
        ..write(_cap(redactSecrets(error.toString())));
    }
    final stack = record.stackTrace;
    if (stack != null) {
      buffer
        ..write('\n')
        ..write(_cap(redactSecrets(stack.toString())));
    }
    return buffer.toString();
  }

  String _cap(String text) {
    final bytes = utf8.encode(text);
    if (bytes.length <= maxMessageBytes) return text;
    const marker = ' … [truncated]';
    final budget = maxMessageBytes - utf8.encode(marker).length;
    if (budget <= 0) return marker.trim();
    return '${utf8.decode(bytes.sublist(0, budget), allowMalformed: true)}$marker';
  }

  String _formatDate(DateTime time) {
    String two(int value) => value < 10 ? '0$value' : '$value';
    String three(int value) =>
        value < 10 ? '00$value' : (value < 100 ? '0$value' : '$value');
    return '${time.year.toString().padLeft(4, '0')}-'
        '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
        '${three(time.millisecond)}';
  }

  void _enqueue(_PendingLine line) {
    if (_queue.length >= backlogLimit) {
      // 先丢最低优先级；同优先级丢更早的，保留新记录。
      var dropIndex = -1;
      var lowest = 4;
      for (var i = 0; i < _queue.length; i++) {
        final priority = _queue.elementAt(i).priority;
        if (priority < lowest) {
          lowest = priority;
          dropIndex = i;
        }
      }
      if (line.priority > lowest) {
        _queue.remove(_queue.elementAt(dropIndex));
        _droppedLines++;
      } else {
        _droppedLines++;
        return;
      }
    }
    _queue.addLast(line);
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_closed || _status != DiagnosticLogStatus.recording) return;
    if (_draining || _flushTimer != null) return;
    final last = _lastWriteAt;
    if (last == null || _now().difference(last) >= flushInterval) {
      unawaited(_drain());
      return;
    }
    final wait = flushInterval - _now().difference(last);
    _flushTimer = Timer(wait, () {
      _flushTimer = null;
      unawaited(_drain());
    });
  }

  Future<void> _drain() {
    final running = _drainFuture;
    if (running != null) return running;
    final future = _doDrain().whenComplete(() => _drainFuture = null);
    _drainFuture = future;
    return future;
  }

  Future<void> _doDrain() async {
    if (_draining || _closed) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && _status == DiagnosticLogStatus.recording) {
        final batch = _takeBatch();
        if (batch.isEmpty) break;
        final ok = await _writeBatch(batch);
        if (!ok) break;
        _lastWriteAt = _now();
        if (_droppedLines > 0) {
          final dropped = _droppedLines;
          _droppedLines = 0;
          final marker =
              '--- $dropped log lines dropped under backpressure ---\n';
          if (!await _append(marker)) {
            _droppedLines += dropped;
          }
        }
      }
    } finally {
      _draining = false;
    }
    if (_queue.isNotEmpty && _status == DiagnosticLogStatus.recording) {
      _scheduleDrain();
    }
  }

  String _takeBatch() {
    final buffer = StringBuffer();
    var size = 0;
    while (_queue.isNotEmpty) {
      final line = _queue.first;
      final bytes = utf8.encode('${line.text}\n').length;
      if (size > 0 && size + bytes > maxBytes) break;
      _queue.removeFirst();
      buffer
        ..write(line.text)
        ..write('\n');
      size += bytes;
      if (size >= maxBytes / 2) break;
    }
    return _truncateBatch(buffer.toString());
  }

  String _truncateBatch(String batch) {
    final bytes = utf8.encode(batch);
    if (bytes.length <= maxBytes) return batch;
    return utf8.decode(
      bytes.sublist(bytes.length - maxBytes),
      allowMalformed: true,
    );
  }

  Future<bool> _writeBatch(String batch) async {
    try {
      if (!await _ensureActiveFile()) return false;
      final path = _activePath!;
      final bytes = utf8.encode(batch).length;
      if (_activeSize + bytes > maxBytes) {
        // 轮转失败不丢记录：继续追加，下一批再试。活动文件可能暂时超限，
        // 但下次成功轮转后会回到预算内。
        await _rotate();
      }
      await _store.writeAppend(path, batch);
      _activeSize += bytes;
      _consecutiveFailures = 0;
      return true;
    } catch (_) {
      _consecutiveFailures++;
      if (_consecutiveFailures >= maxConsecutiveFailures) {
        _disable();
      }
      return false;
    }
  }

  Future<bool> _append(String text) async {
    try {
      if (!await _ensureActiveFile()) return false;
      await _store.writeAppend(_activePath!, text);
      _activeSize += utf8.encode(text).length;
      _consecutiveFailures = 0;
      return true;
    } catch (_) {
      _consecutiveFailures++;
      if (_consecutiveFailures >= maxConsecutiveFailures) _disable();
      return false;
    }
  }

  Future<bool> _ensureActiveFile() async {
    if (_activePath != null) return true;
    final directory = await _directory();
    // 目录解析器可能只给路径，不保证已创建；创建失败走统一失败处理。
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final path = p.join(directory.path, activeFileName);
    var size = 0;
    if (await _store.exists(path)) {
      size = await _store.length(path);
      if (size > maxBytes) {
        // 旧版本可能留下超预算活动文件：启动先裁到最新字节。
        final tail = await _store.readTail(path, maxBytes);
        final text = utf8.decode(tail, allowMalformed: true);
        await _store.replace(path, text);
        size = utf8.encode(text).length;
      }
    }
    _activePath = path;
    _activeSize = size;
    return true;
  }

  Future<void> _rotate() async {
    final active = _activePath!;
    final oldest = p.join(p.dirname(active), archiveFileName(maxFiles - 1));
    try {
      if (await _store.exists(oldest)) await _store.delete(oldest);
      for (var index = maxFiles - 1; index >= 2; index--) {
        final from = p.join(p.dirname(active), archiveFileName(index - 1));
        final to = p.join(p.dirname(active), archiveFileName(index));
        if (await _store.exists(from)) await _store.rename(from, to);
      }
      final first = p.join(p.dirname(active), archiveFileName(1));
      if (await _store.exists(active)) await _store.rename(active, first);
      _activeSize = 0;
    } catch (_) {
      // 文件被占用 / 权限问题：本批继续追加到原活动文件，下一批再试。
    }
  }

  void _disable() {
    _status = DiagnosticLogStatus.unavailable;
    _queue.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  /// 立即落盘当前队列（测试 / 关闭 / 导出前用）；失败不抛异常。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    while (_queue.isNotEmpty && _status == DiagnosticLogStatus.recording) {
      await _drain();
      final running = _drainFuture;
      if (running != null) await running;
    }
    final running = _drainFuture;
    if (running != null) await running;
  }

  /// 解析日志目录；不可用时返回 null（导出继续，只是没有日志段）。
  Future<Directory?> directory() async {
    try {
      return await _directory();
    } catch (_) {
      return null;
    }
  }

  /// 关闭：尽力刷完队列，随后停止接收记录。不把异常抛给退出路径。
  Future<void> close() async {
    if (_closed) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    if (_status == DiagnosticLogStatus.recording && _queue.isNotEmpty) {
      try {
        await _drain().timeout(const Duration(milliseconds: 500));
      } catch (_) {
        // 关闭有界：磁盘卡住也不能拖住退出。
      }
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    _closed = true;
    _status = DiagnosticLogStatus.stopped;
  }
}
