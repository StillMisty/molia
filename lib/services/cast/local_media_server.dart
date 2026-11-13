/// 本地投屏媒体服务：只服务本次会话登记过的本地 / 下载文件。
///
/// 安全边界：
/// - 只监听局域网（测试可指定 loopback），端口随机；
/// - 路径含不可猜的会话令牌，令牌不匹配 / 不在登记表 / 带路径分隔符一律 404；
/// - 没有目录列表，也不能读取登记表以外的路径；
/// - 支持 Range（渲染器按需拖动），结束后关闭端口。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class LocalMediaServer {
  LocalMediaServer({
    InternetAddress? bindAddress,
    Random? random,
    this.port = 0,
  }) : _bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _random = random ?? Random.secure();

  final InternetAddress _bindAddress;
  final Random _random;
  final int port;

  HttpServer? _server;
  String? _token;
  Map<String, File> _files = const {};

  bool get isRunning => _server != null;

  /// 启动并登记本次允许服务的文件；返回服务根地址。
  Future<Uri> start({required Map<String, File> files}) async {
    await stop();
    _files = Map<String, File>.unmodifiable(files);
    _token = _newToken();
    final server = await HttpServer.bind(_bindAddress, port);
    _server = server;
    unawaited(_serve(server));
    final address = _bindAddress.address == '0.0.0.0'
        ? InternetAddress.loopbackIPv4.address
        : _bindAddress.address;
    return Uri.parse('http://$address:${server.port}');
  }

  /// 某个已登记文件的局域网地址；未启动 / 未登记返回 null。
  Uri? uriFor(String id) {
    final server = _server;
    final token = _token;
    if (server == null || token == null || !_files.containsKey(id)) return null;
    final address = _bindAddress.address == '0.0.0.0'
        ? InternetAddress.loopbackIPv4.address
        : _bindAddress.address;
    return Uri.parse(
      'http://$address:${server.port}/m/$token/${Uri.encodeComponent(id)}',
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    _files = const {};
    if (server != null) await server.close(force: true);
  }

  String _newToken() {
    final bytes = Uint8List(24);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _handle(request);
      } catch (_) {
        // 单个坏请求不能带倒整个会话；能回 500 就回，连接已断就忽略。
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      await _notFound(request);
      return;
    }
    final segments = request.uri.pathSegments;
    if (segments.length != 3 || segments[0] != 'm') {
      await _notFound(request);
      return;
    }
    if (segments[1] != _token) {
      await _notFound(request);
      return;
    }
    final id = segments[2];
    if (id.isEmpty ||
        id.contains('/') ||
        id.contains('\\') ||
        id.contains('..')) {
      await _notFound(request);
      return;
    }
    final file = _files[id];
    if (file == null || !await file.exists()) {
      await _notFound(request);
      return;
    }
    final length = await file.length();
    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      length,
    );
    final response = request.response
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.contentType = _contentTypeOf(file.path);
    if (range == null) {
      response.statusCode = HttpStatus.ok;
      response.contentLength = length;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      await response.addStream(file.openRead());
      await response.close();
      return;
    }
    if (range.invalid) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      await response.close();
      return;
    }
    final start = range.start;
    final end = range.end;
    response
      ..statusCode = HttpStatus.partialContent
      ..contentLength = end - start + 1
      ..headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(start, end + 1));
    await response.close();
  }

  Future<void> _notFound(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  static _ByteRange? _parseRange(String? header, int length) {
    if (header == null || !header.startsWith('bytes=')) return null;
    final value = header.substring('bytes='.length);
    // 多段 Range 不支持：按整段返回，避免渲染器拿到拼接错位的数据。
    if (value.contains(',')) return null;
    final dash = value.indexOf('-');
    if (dash < 0) return const _ByteRange.invalid();
    final startText = value.substring(0, dash).trim();
    final endText = value.substring(dash + 1).trim();
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return const _ByteRange.invalid();
      final start = max(0, length - suffix);
      return _ByteRange(start, length - 1);
    }
    final start = int.tryParse(startText);
    if (start == null || start < 0 || start >= length) {
      return const _ByteRange.invalid();
    }
    final end = endText.isEmpty ? length - 1 : int.tryParse(endText);
    if (end == null || end < start) return const _ByteRange.invalid();
    return _ByteRange(start, min(end, length - 1));
  }

  static ContentType _contentTypeOf(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.flac')) return ContentType('audio', 'flac');
    if (lower.endsWith('.wav')) return ContentType('audio', 'wav');
    if (lower.endsWith('.ogg')) return ContentType('audio', 'ogg');
    if (lower.endsWith('.opus')) return ContentType('audio', 'opus');
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) {
      return ContentType('audio', 'mp4');
    }
    if (lower.endsWith('.aac')) return ContentType('audio', 'aac');
    return ContentType('audio', 'mpeg');
  }
}

class _ByteRange {
  const _ByteRange(this.start, this.end) : invalid = false;

  const _ByteRange.invalid() : start = 0, end = 0, invalid = true;

  final int start;
  final int end;
  final bool invalid;
}
