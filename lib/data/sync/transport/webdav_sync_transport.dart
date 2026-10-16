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

/// 用户自备 WebDAV 的传输：每台设备上传自己的**增量日志**与**全量快照**，
/// 读取其余设备的文件。
///
/// - 文件布局（都在 `<baseUrl>/<remoteDir>/` 下）：
///   - `<deviceId>.journal.msync`：增量窗口（每次变更后重写，体积 ∝ 变更量）；
///   - `<deviceId>.snapshot.msync`：全量快照（**按需重写**：首次引导 /
///     日志超硬上限时发布，对端落后超出日志窗口时读它做 bootstrap）；
/// - 目录不存在时 MKCOL 自动创建；列表用 PROPFIND（Depth: 1）并请求
///   `getetag` / `getlastmodified`：文件版本与上次拉到的一致且本机游标已到
///   上次读到位置时跳过 GET + 解密 + 合并；
/// - 非本协议文件名（其它命名的残留、被改名 / 拷贝的幽灵文件）不参与合并；
///   解密后的载荷 `deviceId` 与文件名不符时同样跳过；
/// - 数据在离开设备前已用同步口令加密，服务端只见密文；
/// - 失败容忍与局域网一致：单个文件读取/解密失败只跳过该文件。
class WebDavSyncTransport implements SyncTransport {
  WebDavSyncTransport({
    required this.deviceId,
    required SyncCodec codec,
    required Future<String?> Function() passphraseProvider,
    required WebDavConfig Function() configProvider,
    required Future<String?> Function() passwordProvider,
    bool Function(String deviceId)? ignoredPeersProvider,
    Dio? dio,
    Duration requestTimeout = const Duration(seconds: 15),
  })  : _codec = codec,
        _passphraseProvider = passphraseProvider,
        _configProvider = configProvider,
        _passwordProvider = passwordProvider,
        _ignoredPeersProvider = ignoredPeersProvider,
        _dio = dio,
        _ownsDio = dio == null,
        _requestTimeout = requestTimeout;

  /// 全量快照文件后缀（按需重写：首次引导 / 日志超硬上限时发布）。
  static const String snapshotSuffix = '.snapshot.msync';

  /// 增量窗口文件后缀（每次变更后重写，体积 ∝ 变更量）。
  static const String journalSuffix = '.journal.msync';

  static const int maxSnapshotBytes = 32 * 1024 * 1024;

  final String deviceId;
  final SyncCodec _codec;
  final Future<String?> Function() _passphraseProvider;
  final WebDavConfig Function() _configProvider;
  final Future<String?> Function() _passwordProvider;

  /// 本地忽略的设备（不读它们的远端文件）。
  final bool Function(String deviceId)? _ignoredPeersProvider;
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

  /// 上次从各设备载荷里读到的 journal 头部：文件版本未变但本机游标落后于
  /// 它时仍需重读（上一轮落地失败的条目要能重试）。
  final Map<String, int> _peerHeads = {};
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
  Future<SyncPullResult> pull([SyncPullRequest request = SyncPullRequest.none]) async {
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
    // 按设备归并两类文件：优先读增量日志；游标落后于窗口起点（或引擎显式
    // 要求全量）时改读全量快照做 bootstrap。
    final devices = _groupFiles(files);
    for (final entry in devices.entries) {
      final device = entry.key;
      final journalFile = entry.value.journal;
      final snapshotFile = entry.value.snapshot;
      final cursor = request.cursorFor(device);
      final forceFull = request.fullPeers.contains(device);
      var file = forceFull || journalFile == null ? snapshotFile : journalFile;
      if (file == null) continue;
      // 文件版本未变且本机游标已到上次读到的头部：跳过 GET + 解密 + 合并。
      final cached = _fileVersions[file.name];
      final upToDate = cursor >= (_peerHeads[device] ?? SyncPullRequest.noCursor);
      if (!forceFull &&
          file.version.isNotEmpty &&
          cached == file.version &&
          upToDate) {
        skipped++;
        continue;
      }
      var bytes = await _getFile(config, file.name);
      if (bytes == null) {
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.webdavReadFailed,
          args: {'peer': file.name},
        );
        continue;
      }
      bytesIn += bytes.length;
      SyncEnvelope envelope;
      try {
        envelope = _codec.decrypt(bytes, passphrase);
      } on SyncCryptoException {
        // 口令不同或文件损坏：跳过（不记版本，下轮重试）。
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.webdavDecryptFailed,
          args: {'peer': file.name},
        );
        continue;
      }
      // 幽灵 / 被改名文件：载荷身份与文件名不符，不参与合并。
      if (envelope.deviceId != device) {
        _logger.warning('远端文件 ${file.name} 的身份不符（载荷 ${envelope.deviceId}），跳过');
        continue;
      }
      if (file.version.isNotEmpty) _fileVersions[file.name] = file.version;
      _peerHeads[device] = envelope.journalHead;
      // 增量窗口的起点超出本机游标（条目已被对端裁剪）：改读全量快照。
      if (!forceFull &&
          envelope.isDelta &&
          cursor < envelope.baseSeq &&
          snapshotFile != null &&
          snapshotFile.name != file.name) {
        final fallback = await _getFile(config, snapshotFile.name);
        if (fallback != null) {
          try {
            final full = _codec.decrypt(fallback, passphrase);
            if (full.deviceId == device) {
              bytesIn += fallback.length;
              if (snapshotFile.version.isNotEmpty) {
                _fileVersions[snapshotFile.name] = snapshotFile.version;
              }
              _peerHeads[device] = full.journalHead;
              envelopes.add(full);
              continue;
            }
          } on SyncCryptoException {
            // 快照文件不可用：保留增量窗口（引擎会标记缺口并在下轮重试）。
          }
        }
      }
      envelopes.add(envelope);
    }
    return SyncPullResult(
      envelopes: envelopes,
      peersSeen: devices.length,
      skippedUnchanged: skipped,
      failedPeers: failed,
      bytesIn: bytesIn,
      // 目录可读 = 远端可达：零快照也算接触成功（首台设备的推送失败
      // 因此是部分失败而不是「所有对端都不可达」）。
      contacted: true,
      error: firstError,
    );
  }

  /// 把远端文件按设备归并（非本协议文件名忽略：幽灵文件不参与合并）。
  Map<String, ({_RemoteFile? journal, _RemoteFile? snapshot})> _groupFiles(
    List<_RemoteFile> files,
  ) {
    final grouped = <String, ({_RemoteFile? journal, _RemoteFile? snapshot})>{};
    for (final file in files) {
      final String device;
      final bool isJournal;
      if (file.name.endsWith(journalSuffix)) {
        device = file.name.substring(0, file.name.length - journalSuffix.length);
        isJournal = true;
      } else if (file.name.endsWith(snapshotSuffix)) {
        device = file.name.substring(0, file.name.length - snapshotSuffix.length);
        isJournal = false;
      } else {
        continue;
      }
      if (device.isEmpty || device == deviceId) continue;
      if (_ignoredPeersProvider?.call(device) ?? false) continue;
      final existing = grouped[device] ??
          (journal: null, snapshot: null) as ({_RemoteFile? journal, _RemoteFile? snapshot});
      grouped[device] = isJournal
          ? (journal: file, snapshot: existing.snapshot)
          : (journal: existing.journal, snapshot: file);
    }
    return grouped;
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
      // 增量窗口与全量快照分开文件：日常只重写增量（体积 ∝ 变更量），
      // 全量快照按需发布（首次引导 / 日志超硬上限）。
      final name = envelope.isDelta
          ? '$deviceId$journalSuffix'
          : '$deviceId$snapshotSuffix';
      await _putFile(config, name, payload);
      return SyncPushResult(succeededPeers: 1, bytesOut: payload.length);
    } catch (e) {
      _logger.warning('WebDAV 快照上传失败', e);
      return SyncPushResult(
        failedPeers: 1,
        error: SyncIssue(code: SyncIssueCode.webdavUploadFailed, detail: '$e'),
      );
    }
  }

  /// 显式清理某台对端的远端文件（用户动作；**不做自动删除**）。
  ///
  /// 删除该设备的日志 / 快照文件（含其它命名的残留）。
  @override
  Future<bool> deleteRemote(String deviceId) async {
    if (!_running) return false;
    final config = _configProvider();
    if (!config.isConfigured) return false;
    var removed = false;
    for (final name in [
      '$deviceId$journalSuffix',
      '$deviceId$snapshotSuffix',
      '$deviceId.msync',
    ]) {
      try {
        final response = await _send(
          'DELETE',
          _fileUri(config, name),
          headers: await _authHeaders(config),
        );
        if (response.httpStatus >= 200 && response.httpStatus < 300) {
          removed = true;
          _fileVersions.remove(name);
        }
        // 404 = 本来就没有这份文件：不算失败。
      } catch (e) {
        _logger.warning('WebDAV 清理远端文件失败（$name）', e);
      }
    }
    return removed;
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
