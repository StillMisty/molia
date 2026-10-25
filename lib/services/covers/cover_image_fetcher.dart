/// 封面原图读取：本地文件 / data URL / 网络直取。
///
/// 网络封面**不读封面缓存**：`flutter_cache_manager` 的缩略图路径会把原
/// URL 缓存键覆盖成缩小图，拿它当「原图」会保存成缩略图。这里按用户主动
/// 保存的语义直连原 URL（统一 UA / Referer，8MB 上限）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../data/http/app_dio.dart';
import '../../managers/artwork_cache.dart';
import '../download/download_file_layout.dart';
import 'cover_bytes_downloader.dart';

/// 封面字节读取（测试可注入）。
typedef CoverBytesReader = Future<Uint8List?> Function(String url);

/// 原图读取端口：查看器只依赖这个接口，测试注入假字节即可。
abstract interface class CoverOriginalSource {
  Future<Uint8List?> read(String url, {bool allowNetwork = true});
}

/// 生产实现：本地 / data URL 直读，网络直连原 URL。
class CoverImageFetcher implements CoverOriginalSource {
  CoverImageFetcher({this.downloadBytes, this.maxBytes = defaultCoverMaxBytes});

  /// 网络下载实现（测试注入；null = 直连原 URL）。
  final CoverBytesReader? downloadBytes;
  final int maxBytes;
  final Logger _logger = Logger('molia.cover_image_fetcher');

  Dio? _dio;

  @override
  Future<Uint8List?> read(String url, {bool allowNetwork = true}) async {
    if (url.isEmpty) return null;
    try {
      if (url.startsWith('data:')) {
        return _bounded(_decodeDataUrl(url));
      }
      final uri = Uri.tryParse(url);
      if (uri != null && uri.scheme == 'file') {
        return _bounded(await _readFile(uri));
      }
      if (!allowNetwork) return null;
      final download = downloadBytes ?? _downloadOriginal;
      return _bounded(await download(url));
    } catch (e) {
      _logger.fine('封面原图读取失败: $e');
      return null;
    }
  }

  Future<Uint8List?> _downloadOriginal(String url) => downloadCoverBytes(
    _dio ??= createAppDio(),
    url,
    cache: ArtworkCache.instance,
    maxBytes: maxBytes,
  );

  Uint8List? _bounded(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    if (bytes.length > maxBytes) return null;
    return bytes;
  }

  Future<Uint8List?> _readFile(Uri uri) async {
    final file = File(uri.toFilePath());
    if (!await file.exists()) return null;
    if (await file.length() > maxBytes) return null;
    return file.readAsBytes();
  }

  Uint8List? _decodeDataUrl(String url) {
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    final meta = url.substring(5, comma);
    if (!meta.contains(';base64')) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  /// 文件扩展名：先按字节魔数嗅探，再回退 URL 后缀（未知按 jpg）。
  static String extensionFor({required String url, required Uint8List bytes}) {
    final sniffed = _sniffExtension(bytes);
    if (sniffed != null) return sniffed;
    return DownloadFileLayout.coverExtension(url);
  }

  static String mimeTypeFor(String extension) =>
      switch (extension.toLowerCase()) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        'bmp' => 'image/bmp',
        _ => 'image/jpeg',
      };

  /// 保存文件名：标题清洗 + 扩展名（空标题回退 cover）。
  static String fileNameFor({required String base, required String extension}) {
    final trimmed = base.trim();
    final safe = DownloadFileLayout.sanitizeFileName(
      trimmed.isEmpty ? 'cover' : trimmed,
    );
    final ext = extension.trim().isEmpty ? 'jpg' : extension.trim();
    return '$safe.$ext';
  }

  static String? _sniffExtension(Uint8List bytes) {
    if (_startsWith(bytes, const [0xFF, 0xD8, 0xFF])) return 'jpg';
    if (_startsWith(bytes, const [0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (_startsWith(bytes, const [0x47, 0x49, 0x46])) return 'gif';
    if (_startsWith(bytes, const [0x42, 0x4D])) return 'bmp';
    if (bytes.length >= 12 &&
        _startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return null;
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }
}
