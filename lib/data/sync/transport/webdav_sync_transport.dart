import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/sync_transport.dart';
import '../../http/app_dio.dart';
import '../sync_crypto.dart';
import '../sync_state_store.dart';

/// WebDAV 请求返回了非预期状态码（调用方按「本轮失败、下轮重试」处理）。
class WebDavHttpException implements Exception {
  WebDavHttpException(this.message);

  final String message;

  @override
  String toString() => 'WebDavHttpException($message)';
}

/// 用户自备 WebDAV 的传输：每台设备上传一份加密快照，读取其余设备快照。
///
/// - 文件布局：`<baseUrl>/<remoteDir>/<deviceId>.msync`（二进制密文）；
/// - 目录不存在时 MKCOL 自动创建；列表用 PROPFIND（Depth: 1）并请求
///   `getetag` / `getlastmodified`：文件版本与上次拉到的一致时跳过
///   GET + 解密 + 合并；
/// - 数据在离开设备前已用同步口令加密，服务端只见密文；
/// - 失败容忍与局域网一致：单个文件读取/解密失败只跳过该文件。
class WebDavSyncTransport implements SyncTransport {
  WebDavSyncTransport({
    required this.deviceId,
    required SyncCodec codec,
    required Future<String?> Function() passphraseProvider,
    required WebDavConfig Function() configProvider,
    required Future<String?> Function() passwordProvider,
    Dio? dio,
    Duration requestTimeout = const Duration(seconds: 15),
  })  : _codec = codec,
        _passphraseProvider = passphraseProvider,
        _configProvider = configProvider,
        _passwordProvider = passwordProvider,
        _dio = dio,
        _ownsDio = dio == null,
        _requestTimeout = requestTimeout;

  static const String snapshotSuffix = '.msync';
  static const int maxSnapshotBytes = 32 * 1024 * 1024;

  final String deviceId;
  final SyncCodec _codec;
  final Future<String?> Function() _passphraseProvider;
  final WebDavConfig Function() _configProvider;
  final Future<String?> Function() _passwordProvider;
  final bool _ownsDio;
  final Duration _requestTimeout;
  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();

  Dio? _dio;
  bool _running = false;
  final Set<String> _ensuredDirs = {};

  /// 上次成功拉到的各远端文件版本（`etag` 优先，缺省 `lastmodified`）：
  /// 与 PROPFIND 结果一致时跳过 GET + 解密。进程内缓存。
  final Map<String, String> _fileVersions = {};
  final Logger _logger = Logger('molia.sync.webdav');

  @override
  String get kind => SyncTransportKind.webdav;

  @override
  bool get isRunning => _running;

  @override
  String? get unavailableReason =>
      _configProvider().isConfigured ? null : SyncUnavailableReason.notConfigured;

  /// 未配置没有额外技术细节（原因码已说明一切）。
  @override
  String? get unavailableDetail => null;

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
    if (_ownsDio) {
      _dio?.close(force: true);
      _dio = null;
    }
    _ensuredDirs.clear();
  }

  @override
  Future<SyncPullResult> pull() async {
    if (!_running) return SyncPullResult.none;
    final config = _configProvider();
    final passphrase = await _passphraseProvider();
    if (!config.isConfigured ||
        passphrase == null ||
        passphrase.trim().isEmpty) {
      return SyncPullResult(
        error: SyncIssue(
          code: config.isConfigured
              ? SyncIssueCode.noPassphrase
              : SyncIssueCode.notConfigured,
        ),
      );
    }

    final envelopes = <SyncEnvelope>[];
    try {
      await _ensureDir(config);
    } catch (e) {
      _logger.warning('WebDAV 目录准备失败', e);
      // 目录准备失败计入失败对端：否则「没有任何文件」会被判成「没发现对端」，
      // 启动类故障在状态面上不可见。
      return SyncPullResult(
        failedPeers: 1,
        error: SyncIssue(code: SyncIssueCode.webdavDirFailed, detail: '$e'),
      );
    }
    final List<_RemoteFile>? files;
    try {
      files = await _listSnapshotFiles(config);
    } catch (e) {
      _logger.warning('WebDAV 目录列表失败', e);
      return SyncPullResult(
        failedPeers: 1,
        error: SyncIssue(code: SyncIssueCode.webdavListFailed, detail: '$e'),
      );
    }
    if (files == null) {
      return const SyncPullResult(
        failedPeers: 1,
        error: SyncIssue(code: SyncIssueCode.webdavListFailed),
      );
    }
    var failed = 0;
    var skipped = 0;
    var bytesIn = 0;
    SyncIssue? firstError;
    for (final file in files) {
      // 文件版本未变：跳过 GET + 解密 + 合并（服务端未给版本时照常拉取）。
      final cached = _fileVersions[file.name];
      if (file.version.isNotEmpty && cached == file.version) {
        skipped++;
        continue;
      }
      final bytes = await _getFile(config, file.name);
      if (bytes == null) {
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.webdavReadFailed,
          args: {'peer': file.name},
        );
        continue;
      }
      bytesIn += bytes.length;
      try {
        envelopes.add(_codec.decrypt(bytes, passphrase));
        if (file.version.isNotEmpty) _fileVersions[file.name] = file.version;
      } on SyncCryptoException {
        // 口令不同或文件损坏：跳过（不记版本，下轮重试）。
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.webdavDecryptFailed,
          args: {'peer': file.name},
        );
      }
    }
    return SyncPullResult(
      envelopes: envelopes,
      peersSeen: files.length,
      skippedUnchanged: skipped,
      failedPeers: failed,
      bytesIn: bytesIn,
      error: firstError,
    );
  }

  @override
  Future<SyncPushResult> push(SyncEnvelope envelope) async {
    if (!_running) return SyncPushResult.none;
    final config = _configProvider();
    final passphrase = await _passphraseProvider();
    if (!config.isConfigured ||
        passphrase == null ||
        passphrase.trim().isEmpty) {
      return SyncPushResult(
        error: SyncIssue(
          code: config.isConfigured
              ? SyncIssueCode.noPassphrase
              : SyncIssueCode.notConfigured,
        ),
      );
    }
    try {
      await _ensureDir(config);
      final payload = _codec.encrypt(envelope, passphrase);
      await _putFile(config, '$deviceId$snapshotSuffix', payload);
      return SyncPushResult(succeededPeers: 1, bytesOut: payload.length);
    } catch (e) {
      _logger.warning('WebDAV 快照上传失败', e);
      return SyncPushResult(
        failedPeers: 1,
        error: SyncIssue(code: SyncIssueCode.webdavUploadFailed, detail: '$e'),
      );
    }
  }

  Future<void> _ensureDir(WebDavConfig config) async {
    final dir = _dirUri(config);
    if (_ensuredDirs.contains(dir.toString())) return;
    final response = await _send(
      'MKCOL',
      dir,
      headers: await _authHeaders(config),
    );
    // 201 新建 / 405 已存在 / 301/302 部分服务端对目录的跳转均视为可用。
    if (response.httpStatus == 201 ||
        response.httpStatus == 200 ||
        response.httpStatus == 301 ||
        response.httpStatus == 302 ||
        response.httpStatus == 405) {
      _ensuredDirs.add(dir.toString());
      return;
    }
    throw WebDavHttpException('MKCOL 失败: ${response.httpStatus}');
  }

  /// 列出远端快照文件（含 `getetag` / `getlastmodified` 版本）；
  /// 服务端返回错误状态码时返回 null（由调用方计为失败）。
  Future<List<_RemoteFile>?> _listSnapshotFiles(WebDavConfig config) async {
    final response = await _send(
      'PROPFIND',
      _dirUri(config),
      headers: {
        ...await _authHeaders(config),
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: '<?xml version="1.0" encoding="utf-8"?>'
          '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/>'
          '<d:getetag/><d:getlastmodified/></d:prop></d:propfind>',
    );
    if (response.httpStatus >= 400) return null;
    final body = utf8.decode(
      await _collectBodyBytes(response) ?? const <int>[],
      allowMalformed: true,
    );
    final own = '$deviceId$snapshotSuffix';
    final files = <_RemoteFile>[];
    for (final entry in _parsePropfind(body)) {
      final segments =
          entry.name.split('/').where((segment) => segment.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      final name = segments.last;
      if (name == own || !name.endsWith(snapshotSuffix)) continue;
      if (files.any((file) => file.name == name)) continue;
      files.add(_RemoteFile(name: name, version: entry.version));
    }
    return files;
  }

  /// 解析 multistatus 响应：逐 `<response>` 块取 `href` 与版本
  /// （`getetag` 优先，缺省 `getlastmodified`；两者都没有时版本为空）。
  ///
  /// 服务端响应缺少成对 `<response>` 标签时退回「只按 href 列出」的宽松解析。
  static List<({String name, String version})> _parsePropfind(String body) {
    final hrefPattern = RegExp(
      r'<(?:\w+:)?href(?:\s[^>]*)?>([^<]+)</(?:\w+:)?href>',
      caseSensitive: false,
    );
    final blockPattern = RegExp(
      r'<(?:\w+:)?response(?:\s[^>]*)?>(.*?)</(?:\w+:)?response>',
      caseSensitive: false,
      dotAll: true,
    );
    final etagPattern = RegExp(
      r'<(?:\w+:)?getetag(?:\s[^>]*)?>([^<]*)</(?:\w+:)?getetag>',
      caseSensitive: false,
    );
    final modifiedPattern = RegExp(
      r'<(?:\w+:)?getlastmodified(?:\s[^>]*)?>([^<]*)</(?:\w+:)?getlastmodified>',
      caseSensitive: false,
    );
    final entries = <({String name, String version})>[];
    for (final block in blockPattern.allMatches(body)) {
      final text = block.group(1) ?? '';
      final href = hrefPattern.firstMatch(text)?.group(1);
      if (href == null) continue;
      final etag = etagPattern.firstMatch(text)?.group(1)?.trim() ?? '';
      final modified = modifiedPattern.firstMatch(text)?.group(1)?.trim() ?? '';
      entries.add((
        name: Uri.decodeComponent(href.trim()),
        version: etag.isNotEmpty ? etag : modified,
      ));
    }
    if (entries.isEmpty) {
      for (final match in hrefPattern.allMatches(body)) {
        entries.add((
          name: Uri.decodeComponent(match.group(1)!.trim()),
          version: '',
        ));
      }
    }
    return entries;
  }

  Future<Uint8List?> _getFile(WebDavConfig config, String name) async {
    try {
      final response = await _send(
        'GET',
        _fileUri(config, name),
        headers: await _authHeaders(config),
      );
      if (response.httpStatus != 200) return null;
      final bytes = await _collectBodyBytes(response);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _putFile(
      WebDavConfig config, String name, Uint8List payload) async {
    final response = await _send(
      'PUT',
      _fileUri(config, name),
      headers: {
        ...await _authHeaders(config),
        'Content-Type': 'application/octet-stream',
      },
      body: payload,
    );
    if (response.httpStatus >= 400) {
      throw WebDavHttpException('PUT 失败: ${response.httpStatus}');
    }
  }

  Future<Map<String, String>> _authHeaders(WebDavConfig config) async {
    final headers = <String, String>{};
    final password = await _passwordProvider();
    if (config.username.isNotEmpty) {
      final token = base64Encode(
          utf8.encode('${config.username}:${password ?? ''}'));
      headers['Authorization'] = 'Basic $token';
    }
    return headers;
  }

  /// 发一次请求并拿流式响应；[body] 为 String 时按文本发，`Uint8List` 按二进制发。
  Future<Response<dynamic>> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) {
    final dio = _dio ??= createAppDio();
    return dio
        .requestUri<dynamic>(
          uri,
          data: body,
          options: Options(
            method: method,
            headers: headers,
            responseType: ResponseType.stream,
          ),
        )
        .timeout(_requestTimeout);
  }

  Future<Uint8List?> _collectBodyBytes(Response<dynamic> response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamBody(response).stream) {
      builder.add(chunk);
      if (builder.length > maxSnapshotBytes) return null;
    }
    return builder.toBytes();
  }

  Uri _dirUri(WebDavConfig config) {
    final base = Uri.parse(config.baseUrl.trim());
    final dir = config.remoteDir.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    var path = base.path;
    if (path.isEmpty) path = '/';
    if (!path.endsWith('/')) path = '$path/';
    return base.replace(path: '$path$dir/');
  }

  Uri _fileUri(WebDavConfig config, String name) {
    final dir = _dirUri(config);
    return dir.replace(path: '${dir.path}$name');
  }
}

/// 远端快照文件的列表项：名称 + 版本令牌（`etag` 优先，缺省 `lastmodified`）。
class _RemoteFile {
  const _RemoteFile({required this.name, required this.version});

  final String name;

  /// 版本令牌（空 = 服务端未提供，无法跳过拉取）。
  final String version;
}
