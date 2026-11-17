/// 下载存储的 SAF 装饰器：只把 `content://` locator 路由到 bridge。
///
/// 下载 / 封面 / 歌词 / journal 仍然全部落在应用目录（`dart:io`），
/// 装饰器不改写这些路径；SAF 曲目是只读就地引用，不复制用户文件。
library;

import 'dart:async';
import 'dart:typed_data';

import '../files/local_locator.dart';
import '../saf/saf_bridge.dart';
import 'download_storage_types.dart';

class SafDownloadStorage implements DownloadStorage {
  SafDownloadStorage(this._inner, this._bridge);

  final DownloadStorage _inner;
  final SafBridge _bridge;

  static const int _streamChunkSize = 64 * 1024;

  @override
  Future<String?> downloadsRoot() => _inner.downloadsRoot();

  @override
  Future<String?> journalRoot() => _inner.journalRoot();

  @override
  Future<bool> fileExists(String path) async {
    if (!isContentLocator(path)) return _inner.fileExists(path);
    final stat = await _stat(path);
    return stat != null;
  }

  @override
  Future<bool> directoryExists(String path) async {
    if (!isContentLocator(path)) return _inner.directoryExists(path);
    final stat = await _stat(path);
    return stat?.isDirectory == true;
  }

  @override
  Future<bool> locatorReachable(String path) async {
    if (!isContentLocator(path)) return _inner.locatorReachable(path);
    final tree = contentTreeUriOf(path);
    if (tree == null) return false;
    // 树根还能 stat 说明授权仍在；文件自身缺失交给 fileExists 判定。
    final stat = await _stat(tree);
    return stat != null;
  }

  @override
  Future<int> fileSize(String path) async {
    if (!isContentLocator(path)) return _inner.fileSize(path);
    return (await _stat(path))?.sizeBytes ?? 0;
  }

  @override
  Future<int?> fileMtime(String path) async {
    if (!isContentLocator(path)) return _inner.fileMtime(path);
    return (await _stat(path))?.mtimeMs;
  }

  @override
  Future<void> copyFile(String from, String to) async {
    if (!isContentLocator(from)) return _inner.copyFile(from, to);
    final stream = await readStream(from);
    await _inner.writeStream(to, stream, total: await fileSize(from));
  }

  @override
  Future<List<String>> listFiles(String dirPath) {
    if (isContentLocator(dirPath)) return Future.value(const []);
    return _inner.listFiles(dirPath);
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    if (!isContentLocator(path)) return _inner.readBytes(path);
    final size = await fileSize(path);
    if (size <= 0) return null;
    return readRange(path, 0, size);
  }

  @override
  Future<Uint8List?> readHead(String path, int length) async {
    if (!isContentLocator(path)) return _inner.readHead(path, length);
    if (length <= 0) return Uint8List(0);
    try {
      return await _bridge.readHead(path, length);
    } on SafBridgeException {
      return null;
    }
  }

  @override
  Future<Uint8List?> readRange(String path, int start, int length) async {
    if (!isContentLocator(path)) return _inner.readRange(path, start, length);
    if (start < 0 || length < 0) return null;
    try {
      return await _bridge.readRange(path, start, length);
    } on SafBridgeException {
      return null;
    }
  }

  @override
  Future<Stream<List<int>>> readStream(String path, {int start = 0}) async {
    if (!isContentLocator(path)) return _inner.readStream(path, start: start);
    final size = await fileSize(path);
    if (size <= 0) return const Stream<List<int>>.empty();
    final offset = start.clamp(0, size);
    return _readContent(path, offset, size);
  }

  Stream<List<int>> _readContent(String path, int offset, int size) async* {
    while (offset < size) {
      final length = size - offset < _streamChunkSize
          ? size - offset
          : _streamChunkSize;
      final chunk = await readRange(path, offset, length);
      if (chunk == null || chunk.isEmpty) return;
      yield chunk;
      offset += chunk.length;
    }
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<List<int>> stream, {
    int? total,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (isContentLocator(path)) {
      throw UnsupportedError('SAF locators are read-only');
    }
    await _inner.writeStream(
      path,
      stream,
      total: total,
      onProgress: onProgress,
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    if (isContentLocator(path)) {
      throw UnsupportedError('SAF locators are read-only');
    }
    await _inner.writeBytes(path, bytes);
  }

  @override
  Future<void> writeString(String path, String content) async {
    if (isContentLocator(path)) {
      throw UnsupportedError('SAF locators are read-only');
    }
    await _inner.writeString(path, content);
  }

  @override
  Future<String?> readString(String path) {
    if (isContentLocator(path)) return Future.value(null);
    return _inner.readString(path);
  }

  @override
  Future<void> rename(String from, String to) {
    if (isContentLocator(from) || isContentLocator(to)) {
      return Future.value();
    }
    return _inner.rename(from, to);
  }

  @override
  Future<void> deleteQuietly(String path) {
    // 只删除应用自己的文件；用户文件 / provider 文档一律不碰。
    if (isContentLocator(path)) return Future.value();
    return _inner.deleteQuietly(path);
  }

  Future<SafDocument?> _stat(String uri) async {
    try {
      return await _bridge.stat(uri);
    } on SafBridgeException {
      return null;
    }
  }
}
