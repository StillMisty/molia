import 'dart:convert';

import 'package:molia/data/downloads/download_storage.dart';

/// 内存下载存储（下载服务测试用）：文件内容存内存 map，路径即键。
class FakeDownloadStorage implements DownloadStorage {
  FakeDownloadStorage({this.root = '/downloads', this.available = true});

  /// [downloadsRoot] 返回值；[available] 为 false 时返回 null（Web 语义）。
  String? root;
  bool available;

  /// 路径 → 文件内容。
  final Map<String, List<int>> files = {};

  /// 已删除过的路径（含重复删除尝试）。
  final List<String> deleted = [];

  @override
  Future<String?> downloadsRoot() async => available ? root : null;

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<int> fileSize(String path) async => files[path]?.length ?? 0;

  @override
  Future<void> writeStream(
    String path,
    Stream<List<int>> stream, {
    int? total,
    void Function(int received, int? total)? onProgress,
  }) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      onProgress?.call(bytes.length, total);
    }
    files[path] = bytes;
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    files[path] = List<int>.of(bytes);
  }

  @override
  Future<void> writeString(String path, String content) async {
    files[path] = utf8.encode(content);
  }

  @override
  Future<String?> readString(String path) async {
    final bytes = files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  Future<void> rename(String from, String to) async {
    final bytes = files.remove(from);
    if (bytes != null) files[to] = bytes;
  }

  @override
  Future<void> deleteQuietly(String path) async {
    deleted.add(path);
    files.remove(path);
  }
}
