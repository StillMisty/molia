/// Android SAF bridge 的纯 Dart 接口：只描述能力与结构化失败。
///
/// 实际实现是应用内 Kotlin MethodChannel（`top.stillmisty.molia/saf`），
/// 不引入第三方 SAF 包；测试注入 fake bridge，不依赖 Android 运行时。
library;

import 'dart:typed_data';

/// bridge 失败的稳定分类（Dart 侧映射为扫描跳过 / 文件夹不可用）。
enum SafFailureKind { missing, permissionDenied, unsupported, io }

class SafBridgeException implements Exception {
  const SafBridgeException(this.kind, [this.message]);

  final SafFailureKind kind;
  final String? message;

  @override
  String toString() =>
      'SafBridgeException($kind)${message == null ? '' : ': $message'}';
}

/// 文档 / 树根元数据。
class SafDocument {
  const SafDocument({
    required this.uri,
    required this.displayName,
    required this.isDirectory,
    required this.sizeBytes,
    required this.mtimeMs,
  });

  final String uri;
  final String displayName;
  final bool isDirectory;
  final int sizeBytes;
  final int mtimeMs;
}

sealed class SafTreeEvent {
  const SafTreeEvent();
}

final class SafTreeEntry extends SafTreeEvent {
  const SafTreeEntry({
    required this.uri,
    required this.displayName,
    required this.relativePath,
    required this.isDirectory,
    required this.sizeBytes,
    required this.mtimeMs,
  });

  final String uri;
  final String displayName;
  final String relativePath;
  final bool isDirectory;
  final int sizeBytes;
  final int mtimeMs;
}

final class SafTreeSkipped extends SafTreeEvent {
  const SafTreeSkipped(this.reason, [this.relativePath = '']);

  /// `hidden` / `depthExceeded` / `symlinkCycle` / `unreadable`。
  final String reason;
  final String relativePath;
}

/// SAF 读取端口。
///
/// 所有调用都在平台线程之外执行；错误以 [SafBridgeException] 暴露，
/// 调用方不需要解析 `PlatformException` 字符串。
abstract interface class SafBridge {
  /// 文档 / 树根 stat；不存在返回 null，权限 / provider 不支持抛异常。
  Future<SafDocument?> stat(String uri);

  /// 流式枚举树（native 侧按目录分批，Dart 不整树读入内存）。
  /// [isCancelled] 变为 true 时尽快结束 native 遍历。
  Stream<SafTreeEvent> listTree(
    String uri, {
    required int maxDepth,
    bool Function()? isCancelled,
  });

  /// 只读文件头（标签解析）；不存在 / 不可读返回 null。
  Future<Uint8List?> readHead(String uri, int length);

  /// 读取 `[start, start + length)`；越界按实际可读字节返回。
  Future<Uint8List?> readRange(String uri, int start, int length);
}
