import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/sync_transport.dart';
import '../../http/app_dio.dart';
import '../peer_journal_protocol.dart';
import '../sync_codec_port.dart';
import '../sync_crypto.dart';
import '../sync_state_store.dart';

/// WebDAV 请求返回了非预期状态码（调用方按「本轮失败、下轮重试」处理）。
class WebDavHttpException implements Exception {
  WebDavHttpException(this.message);

  final String message;

  @override
  String toString() => 'WebDavHttpException($message)';
}

/// WebDAV 传输：用户自备 WebDAV，每台设备写自己的三类文件、读其余设备的。
///
/// 文件布局（都在 `<baseUrl>/<remoteDir>/` 下，v3）：
/// - `<deviceId>.acks.msync`：**回执**（本机游标 / ack / 日志头部 / 基线下标），
///   固定名、可变、几百字节，每次推送顺手重写；对端按 `etag` 门控读取；
/// - `<deviceId>.<start>-<end>.chunk.msync`：**增量块**，写一次不再改
///   （名字自带 seq 区间）；
/// - `<deviceId>.<coverage>.snapshot.msync`：**全量快照**，按需发布（首次引导 /
///   日志超硬上限），写一次不再改。
///
/// 为什么分块：单文件写「整个窗口」时，对端长期离线会让窗口涨到硬上限，
/// 之后**每改一条记录都要重传整个窗口**（MB 量级）；分块后每次变更只写一个
/// 新块（体积 ∝ 本次变更），对端按名字取自己缺的块。块的裁剪由本机日志的
/// `baseSeq` 驱动——它只在所有对端 ack 之后前移，删掉的块不会再被需要
/// （更落后的对端走 bootstrap 快照）。
///
/// - 目录不存在时 MKCOL 自动创建；列表用 PROPFIND（Depth: 1）并请求
///   `getetag` / `getlastmodified`：回执文件按版本门控，块不可变、靠游标过滤；
/// - 非本协议文件名（其它命名的残留、被改名 / 拷贝的幽灵文件）不参与合并；
///   解密后的载荷 `deviceId` 与文件名不符时同样跳过；
/// - 数据在离开设备前已用同步口令加密，服务端只见密文；
/// - 失败容忍与局域网一致：单个文件读取/解密失败只跳过该文件。
class WebDavSyncTransport implements SyncTransport {
  WebDavSyncTransport({
    required this.deviceId,
    required SyncCodecPort codec,
    required Future<String?> Function() passphraseProvider,
    required WebDavConfig Function() configProvider,
    required Future<String?> Function() passwordProvider,
    bool Function(String deviceId)? ignoredPeersProvider,
    Future<int> Function()? journalBaseSeqProvider,
    Dio? dio,
    Duration requestTimeout = const Duration(seconds: 15),
  })  : _codec = codec,
        _journalBaseSeqProvider = journalBaseSeqProvider,
        _passphraseProvider = passphraseProvider,
        _configProvider = configProvider,
        _passwordProvider = passwordProvider,
        _ignoredPeersProvider = ignoredPeersProvider,
        _dio = dio,
        _ownsDio = dio == null,
        _requestTimeout = requestTimeout;

  /// 回执文件后缀（固定名，可变）：`<deviceId>.acks.msync`。
  static const String acksSuffix = PeerJournalNames.acksSuffix;

  /// 增量块后缀（不可变）：`<deviceId>.<start>-<end>.chunk.msync`。
  static const String chunkSuffix = PeerJournalNames.chunkSuffix;

  /// 全量快照后缀（不可变）：`<deviceId>.<coverage>.snapshot.msync`。
  static const String snapshotSuffix = PeerJournalNames.snapshotSuffix;

  /// v3 之前的增量文件命名（只清理不读）。
  static const String legacyJournalSuffix =
      PeerJournalNames.legacyJournalSuffix;

  static const int maxSnapshotBytes = 32 * 1024 * 1024;

  final String deviceId;
  final SyncCodecPort _codec;
  final Future<String?> Function() _passphraseProvider;
  final WebDavConfig Function() _configProvider;
  final Future<String?> Function() _passwordProvider;

  /// 本机日志已裁剪到的位置（块的裁剪边界）：只在所有对端 ack 之后前移，
  /// 因此 `end <= baseSeq` 的块可以安全删除；未注入时不裁剪自己的旧块。
  final Future<int> Function()? _journalBaseSeqProvider;

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

  /// WebDAV 没有本机发现端口（局域网才有 UDP 探测）。
  @override
  ({int v4, int v6}) get discoveryPorts => (v4: 0, v6: 0);

  /// 快照是远端文件（异步读取）：日志裁剪必须留在已发布的覆盖内。
  @override
  bool get servesLiveSnapshot => false;

  @override
  String? get unavailableReason => _configProvider().isConfigured
      ? null
      : SyncUnavailableReason.notConfigured;

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
  Future<SyncPullResult> pull(
      [SyncPullRequest request = SyncPullRequest.none]) async {
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
      files = await _listFiles(config);
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

    final devices = _groupDevices(files);
    final envelopes = <SyncEnvelope>[];
    final seenDevices = <String>{};
    var failed = 0;
    var skipped = 0;
    var bytesIn = 0;
    SyncIssue? firstError;
    for (final entry in devices.entries) {
      final device = entry.key;
      final deviceFiles = entry.value;
      final cursor = request.cursorFor(device);
      final forceFull = request.fullPeers.contains(device);

      // 1) 回执（可变文件，按版本门控）：对端的头部 / ack / 基线下标。
      var peerHead = _peerHeads[device] ?? SyncPullRequest.noCursor;
      SyncEnvelope? acksEnvelope;
      var delivered = false;
      var skipCounted = false;
      final acksFile = deviceFiles.acks;
      if (acksFile != null) {
        final outcome = await _readEnvelope(
          config,
          acksFile,
          device,
          passphrase,
          useVersionCache: true,
        );
        if (outcome.error != null) {
          failed++;
          firstError ??= outcome.error;
        } else if (outcome.ghost) {
          _logger.warning('远端文件 ${acksFile.name} 身份不符，跳过');
        } else if (outcome.skipped) {
          seenDevices.add(device);
          skipped++;
          skipCounted = true;
        } else if (outcome.envelope != null) {
          bytesIn += outcome.bytes;
          seenDevices.add(device);
          // 数据载荷自带同一轮写下的 ack：只有「本轮读不到任何数据」时
          // 才把回执单独交付（否则每轮多一份空载荷、引擎多跑一次消费）。
          acksEnvelope = outcome.envelope;
          peerHead = outcome.envelope!.journalHead;
          _peerHeads[device] = peerHead;
        }
      }

      // 2) 数据：游标之后必须有**连续**的块（块名自带区间）；缺口 / 落后
      //    超出窗口 / 对端日志重置 / 引擎显式要求全量 → 读最新快照 bootstrap。
      final headKnown = peerHead != SyncPullRequest.noCursor;
      if (!forceFull &&
          headKnown &&
          isPeerUpToDate(cursor: cursor, headSeq: peerHead)) {
        // 已到对端头部：不读块，只把回执带回去。
        seenDevices.add(device);
        if (!skipCounted) skipped++;
        if (acksEnvelope != null) envelopes.add(acksEnvelope);
        continue;
      }
      // 衔接判定（首块可以是 1 的全新对端 / 块间不能有空隙）由协议模块统一
      // 给出；不连续时下面的快照兜底是唯一正确出路。
      final selection = selectJournalChunks(
        cursor: cursor,
        chunks: deviceFiles.chunks,
      );
      if (!forceFull && selection.contiguous) {
        for (final chunk in selection.needed) {
          final outcome = await _readEnvelope(
            config,
            chunk.file,
            device,
            passphrase,
          );
          if (outcome.error != null) {
            failed++;
            firstError ??= outcome.error;
            break;
          }
          if (outcome.ghost) {
            _logger.warning('远端文件 ${chunk.file.name} 身份不符，跳过');
            continue;
          }
          if (outcome.envelope == null) continue;
          bytesIn += outcome.bytes;
          delivered = true;
          seenDevices.add(device);
          _peerHeads[device] = outcome.envelope!.journalHead;
          envelopes.add(outcome.envelope!);
        }
        if (!delivered && acksEnvelope != null) envelopes.add(acksEnvelope);
        continue;
      }
      final snapshot = deviceFiles.snapshot;
      if (snapshot == null) {
        // 需要全量但没有可读的快照文件（对端还没发布）：计失败，下轮重试。
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.webdavReadFailed,
          args: {'peer': device},
        );
        if (acksEnvelope != null) envelopes.add(acksEnvelope);
        continue;
      }
      final outcome = await _readEnvelope(
        config,
        snapshot.file,
        device,
        passphrase,
      );
      if (outcome.error != null) {
        failed++;
        firstError ??= outcome.error;
        continue;
      }
      if (outcome.ghost) {
        _logger.warning('远端文件 ${snapshot.file.name} 身份不符，跳过');
        continue;
      }
      if (outcome.envelope != null) {
        seenDevices.add(device);
        bytesIn += outcome.bytes;
        delivered = true;
        _peerHeads[device] = outcome.envelope!.journalHead;
        envelopes.add(outcome.envelope!);
      }
      if (!delivered && acksEnvelope != null) envelopes.add(acksEnvelope);
    }

    // 3) 裁剪自己的旧块 / 旧快照（best effort）。
    await _pruneOwnFiles(config, files);

    return SyncPullResult(
      envelopes: envelopes,
      peersSeen: seenDevices.length,
      seenIds: seenDevices.toList(),
      skippedUnchanged: skipped,
      failedPeers: failed,
      bytesIn: bytesIn,
      // 目录可读 = 远端可达：零快照也算接触成功（首台设备的推送失败
      // 因此是部分失败而不是「所有对端都不可达」）。
      contacted: true,
      error: firstError,
    );
  }

  /// 读一个远端文件并解密（版本缓存只对可变文件——回执——有意义）。
  Future<_ReadOutcome> _readEnvelope(
    WebDavConfig config,
    _RemoteFile file,
    String device,
    String passphrase, {
    bool useVersionCache = false,
  }) async {
    if (useVersionCache &&
        file.version.isNotEmpty &&
        _fileVersions[file.name] == file.version) {
      return const _ReadOutcome(skipped: true);
    }
    final bytes = await _getFile(config, file.name);
    if (bytes == null) {
      return _ReadOutcome(
        error: SyncIssue(
          code: SyncIssueCode.webdavReadFailed,
          args: {'peer': file.name},
        ),
      );
    }
    final SyncEnvelope envelope;
    try {
      envelope = await _codec.decrypt(bytes, passphrase);
    } on SyncCryptoException {
      // 口令不同或文件损坏：跳过（不记版本，下轮重试）。
      return _ReadOutcome(
        error: SyncIssue(
          code: SyncIssueCode.webdavDecryptFailed,
          args: {'peer': file.name},
        ),
      );
    }
    if (envelope.deviceId != device) {
      return const _ReadOutcome(ghost: true);
    }
    if (file.version.isNotEmpty) _fileVersions[file.name] = file.version;
    return _ReadOutcome(envelope: envelope, bytes: bytes.length);
  }

  /// 把远端文件按设备归并（非本协议文件名忽略：幽灵文件不参与合并）。
  ///
  /// 本机文件在这里被跳过（只参与 [_pruneOwnFiles] 的裁剪判定）。
  Map<String, _DeviceFiles> _groupDevices(List<_RemoteFile> files) {
    final grouped = <String, _DeviceFiles>{};
    for (final file in files) {
      final parsed = PeerJournalNames.parse(file.name);
      if (parsed == null) continue;
      final device = parsed.deviceId;
      if (device.isEmpty || device == deviceId) continue;
      if (_ignoredPeersProvider?.call(device) ?? false) continue;
      if (parsed.kind == PeerJournalFileKind.legacy) continue;
      final entry = grouped.putIfAbsent(device, _DeviceFiles.new);
      switch (parsed.kind) {
        case PeerJournalFileKind.acks:
          entry.acks = file;
        case PeerJournalFileKind.chunk:
          final range = parsed.range!;
          entry.chunks.add(
            _ChunkFile(
              file: file,
              startSeq: range.startSeq,
              endSeq: range.endSeq,
            ),
          );
        case PeerJournalFileKind.snapshot:
          final current = entry.snapshot;
          if (current == null || parsed.coverage > current.coverage) {
            entry.snapshot =
                _SnapshotFile(file: file, coverage: parsed.coverage);
          }
        case PeerJournalFileKind.legacy:
          break;
      }
    }
    for (final entry in grouped.values) {
      entry.chunks.sort((a, b) => a.startSeq.compareTo(b.startSeq));
    }
    return grouped;
  }

  /// 裁剪自己的旧文件（best effort；DELETE 失败只记日志，不影响本轮结果）：
  /// - 块：`endSeq <= baseSeq`（baseSeq 只在所有对端 ack 之后前移）；
  /// - 快照：只留覆盖位置最大的那一份；
  /// - v3 之前的旧命名：只清理不读。
  ///
  /// 同名块在日志重置后可能被覆盖（seq 从 1 重新开始）：对端在重置后走
  /// 「游标超前头部 → bootstrap 快照」，不会读到被覆盖的块。
  Future<void> _pruneOwnFiles(
      WebDavConfig config, List<_RemoteFile> files) async {
    final baseSeq = await _journalBaseSeqProvider?.call();
    final stale = <String>[];
    final snapshots = <_SnapshotFile>[];
    for (final file in files) {
      final parsed = PeerJournalNames.parse(file.name);
      if (parsed == null || parsed.deviceId != deviceId) continue;
      switch (parsed.kind) {
        case PeerJournalFileKind.acks:
          break;
        case PeerJournalFileKind.chunk:
          if (baseSeq != null && parsed.range!.endSeq <= baseSeq) {
            stale.add(file.name);
          }
        case PeerJournalFileKind.snapshot:
          snapshots.add(
            _SnapshotFile(file: file, coverage: parsed.coverage),
          );
        case PeerJournalFileKind.legacy:
          stale.add(file.name);
      }
    }
    if (snapshots.length > 1) {
      snapshots.sort((a, b) => b.coverage.compareTo(a.coverage));
      for (final older in snapshots.skip(1)) {
        stale.add(older.file.name);
      }
    }
    for (final name in stale) {
      try {
        await _deleteFile(config, name);
        _fileVersions.remove(name);
      } catch (e) {
        _logger.warning('WebDAV 裁剪自身旧文件失败（$name）', e);
      }
    }
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
      // 回执（固定名、几百字节）每次推送顺手更新：对端据此裁剪自己的日志
      // 窗口，不必读数据块；空窗口的轮次（只有 ack 变化）只写它。
      final acksPayload =
          await _codec.encrypt(_acksEnvelope(envelope), passphrase);
      await _putFile(config, PeerJournalNames.acks(deviceId), acksPayload);
      var bytesOut = acksPayload.length;
      // 数据：快照按覆盖位置命名、增量块按窗口区间命名——都写一次不再改。
      final String? name;
      if (envelope.isDelta) {
        name = envelope.windowEnd > 0
            ? PeerJournalNames.chunk(
                deviceId,
                JournalSeqRange(
                  startSeq: envelope.windowStart,
                  endSeq: envelope.windowEnd,
                ),
              )
            : null;
      } else {
        name = PeerJournalNames.snapshot(deviceId, envelope.journalHead);
      }
      if (name != null) {
        final payload = await _codec.encrypt(envelope, passphrase);
        await _putFile(config, name, payload);
        bytesOut += payload.length;
      }
      return SyncPushResult(succeededPeers: 1, bytesOut: bytesOut);
    } catch (e) {
      _logger.warning('WebDAV 上传失败', e);
      return SyncPushResult(
        failedPeers: 1,
        error: SyncIssue(code: SyncIssueCode.webdavUploadFailed, detail: '$e'),
      );
    }
  }

  /// 回执载荷：只带游标 / ack / 头部（保持「增量 + 空窗口」形态，对端按
  /// 同一套游标语义消费它）。
  SyncEnvelope _acksEnvelope(SyncEnvelope envelope) => SyncEnvelope(
        deviceId: envelope.deviceId,
        deviceName: envelope.deviceName,
        producedAt: envelope.producedAt,
        snapshotId: envelope.snapshotId,
        journalHead: envelope.journalHead,
        baseSeq: envelope.baseSeq,
        journal: const [],
        acks: envelope.acks,
        categories: envelope.categories,
      );

  /// 显式清理某台对端的远端文件（用户动作；**不做自动删除**）。
  ///
  /// 删除该设备的日志 / 快照文件（含其它命名的残留）。服务端拒绝或网络故障
  /// 会抛 [WebDavHttpException] / 原异常：由引擎转成 `delete_remote_failed`
  /// 失败原因（UI 不能把 403 / 500 显示成「没有可清理的文件」）。
  /// 404（本来就没有这份文件）不算失败。
  @override
  Future<bool> deleteRemote(String deviceId) async {
    if (!_running) return false;
    final config = _configProvider();
    if (!config.isConfigured) return false;
    final files = await _listFiles(config);
    if (files == null) {
      throw WebDavHttpException('目录列表失败（无法确认待清理文件）');
    }
    final targets = <String>[
      for (final file in files)
        if (PeerJournalNames.parse(file.name)?.deviceId == deviceId) file.name,
      // 更早版本的残留命名（无区间 / 无覆盖位置）。
      '$deviceId.msync',
      if ('$deviceId${PeerJournalNames.legacyJournalSuffix}' !=
          '$deviceId.msync')
        '$deviceId${PeerJournalNames.legacyJournalSuffix}',
    ];
    var removed = false;
    String? failure;
    for (final name in targets) {
      try {
        final deleted = await _deleteFile(config, name);
        if (deleted) {
          removed = true;
          _fileVersions.remove(name);
        }
      } on WebDavHttpException catch (e) {
        failure ??= e.message;
      } catch (e) {
        _logger.warning('WebDAV 清理远端文件失败（$name）', e);
        failure ??= 'DELETE $name 异常: $e';
      }
    }
    if (failure != null) throw WebDavHttpException(failure);
    return removed;
  }

  /// DELETE 单个文件；404（本来就没有）不算失败。
  Future<bool> _deleteFile(WebDavConfig config, String name) async {
    final response = await _send(
      'DELETE',
      _fileUri(config, name),
      headers: await _authHeaders(config),
    );
    if (response.httpStatus >= 200 && response.httpStatus < 300) return true;
    if (response.httpStatus == 404) return false;
    throw WebDavHttpException('DELETE $name 失败: ${response.httpStatus}');
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

  /// 列出目录里的本协议文件（含 `getetag` / `getlastmodified` 版本）；
  /// 服务端返回错误状态码时返回 null（由调用方计为失败）。
  Future<List<_RemoteFile>?> _listFiles(WebDavConfig config) async {
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
    final files = <_RemoteFile>[];
    for (final entry in _parsePropfind(body)) {
      final segments =
          entry.name.split('/').where((segment) => segment.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      final name = segments.last;
      // 本机文件也列出（裁剪自身旧块要看到它们）；幽灵文件按命名解析排除。
      if (PeerJournalNames.parse(name) == null) continue;
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
      final token =
          base64Encode(utf8.encode('${config.username}:${password ?? ''}'));
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

/// 一台对端的文件集合（回执 / 块 / 最新快照）。
class _DeviceFiles {
  _RemoteFile? acks;
  final List<_ChunkFile> chunks = [];
  _SnapshotFile? snapshot;
}

/// 增量块（名字自带 seq 区间，不可变）。
///
/// 直接实现 [JournalSeqRange]，分块衔接判定可以把原对象交给协议模块，
/// 不需要再把区间拆出来映射回文件。
class _ChunkFile implements JournalSeqRange {
  const _ChunkFile({
    required this.file,
    required this.startSeq,
    required this.endSeq,
  });

  final _RemoteFile file;

  @override
  final int startSeq;

  @override
  final int endSeq;
}

/// 全量快照（名字自带覆盖位置，不可变）。
class _SnapshotFile {
  const _SnapshotFile({required this.file, required this.coverage});

  final _RemoteFile file;
  final int coverage;
}

/// 单文件读取结果（三态：读到 / 跳过 / 失败；ghost = 身份不符的幽灵文件）。
class _ReadOutcome {
  const _ReadOutcome({
    this.envelope,
    this.bytes = 0,
    this.skipped = false,
    this.ghost = false,
    this.error,
  });

  final SyncEnvelope? envelope;
  final int bytes;
  final bool skipped;
  final bool ghost;
  final SyncIssue? error;
}

/// 远端快照文件的列表项：名称 + 版本令牌（`etag` 优先，缺省 `lastmodified`）。
class _RemoteFile {
  const _RemoteFile({required this.name, required this.version});

  final String name;

  /// 版本令牌（空 = 服务端未提供，无法跳过拉取）。
  final String version;
}
