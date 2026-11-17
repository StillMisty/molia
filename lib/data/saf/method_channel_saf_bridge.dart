/// SAF bridge 的 MethodChannel 实现。
///
/// 通道名：`top.stillmisty.molia/saf`。遍历用「begin / next / close」拉取
/// 分批结果：每次只带一页到 Dart，取消时关闭 native 会话；读字节走
/// readHead / readRange，不整文件读入。
library;

import 'package:flutter/services.dart';

import 'saf_bridge.dart';

class MethodChannelSafBridge implements SafBridge {
  MethodChannelSafBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'top.stillmisty.molia/saf';

  /// 每页条目数；本地 provider 一次目录查询通常远小于这个量级。
  static const int batchSize = 100;

  final MethodChannel _channel;

  @override
  Future<SafDocument?> stat(String uri) async {
    final raw = await _invoke<Map<Object?, Object?>>('stat', {'uri': uri});
    if (raw == null) return null;
    return SafDocument(
      uri: uri,
      displayName: (raw['displayName'] as String?)?.trim() ?? '',
      isDirectory: raw['isDirectory'] == true,
      sizeBytes: (raw['size'] as num?)?.toInt() ?? 0,
      mtimeMs: (raw['mtime'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Stream<SafTreeEvent> listTree(
    String uri, {
    required int maxDepth,
    bool Function()? isCancelled,
  }) async* {
    final token = await _invoke<String>('listTreeBegin', {
      'uri': uri,
      'maxDepth': maxDepth,
    });
    if (token == null) {
      throw const SafBridgeException(
        SafFailureKind.unsupported,
        'listTreeBegin returned no token',
      );
    }
    try {
      while (isCancelled?.call() != true) {
        final raw = await _invoke<Map<Object?, Object?>>('listTreeNext', {
          'token': token,
          'maxEntries': batchSize,
        });
        if (raw == null) break;
        final entries = raw['entries'];
        if (entries is List) {
          for (final item in entries) {
            if (item is! Map) continue;
            final skip = item['skip'];
            if (skip is String && skip.isNotEmpty) {
              yield SafTreeSkipped(
                skip,
                (item['relativePath'] as String?) ?? '',
              );
              continue;
            }
            yield SafTreeEntry(
              uri: (item['uri'] as String?) ?? '',
              displayName: (item['name'] as String?) ?? '',
              relativePath: (item['relativePath'] as String?) ?? '',
              isDirectory: item['isDirectory'] == true,
              sizeBytes: (item['size'] as num?)?.toInt() ?? 0,
              mtimeMs: (item['mtime'] as num?)?.toInt() ?? 0,
            );
          }
        }
        if (raw['done'] == true) break;
      }
    } finally {
      await _close(token);
    }
  }

  @override
  Future<Uint8List?> readHead(String uri, int length) async {
    if (length <= 0) return Uint8List(0);
    final raw = await _invoke<Uint8List>('readHead', {
      'uri': uri,
      'length': length,
    });
    return raw;
  }

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) async {
    if (start < 0 || length < 0) return null;
    final raw = await _invoke<Uint8List>('readRange', {
      'uri': uri,
      'start': start,
      'length': length,
    });
    return raw;
  }

  Future<void> _close(String token) async {
    try {
      await _channel.invokeMethod<void>('listTreeClose', {'token': token});
    } catch (_) {
      // 关闭失败只影响 native 会话回收；扫描结果已经拿到。
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const SafBridgeException(SafFailureKind.unsupported);
    } on PlatformException catch (e) {
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
