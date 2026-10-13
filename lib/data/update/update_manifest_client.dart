import 'dart:convert';

import 'package:dio/dio.dart';

import '../../domain/models/app_release.dart';
import '../http/app_dio.dart';
import 'update_manifest_endpoints.dart';
import 'update_repository.dart';

/// 更新清单（latest.json）客户端：拉取 + 结构校验 + 镜像地址重写。
///
/// 清单来源（约定见 docs/release.md）：
/// - 稳定版 `releases/latest/download/latest.json`（GitHub 的 latest 排除
///   prerelease）；
/// - 测试版 `releases/download/beta/latest.json`（发布流水线维护的滚动标签）。
///
/// 用 Release 资产而不是 GitHub API：匿名 API 限流 60 次/小时/IP，
/// 资产走 CDN 且无额外限制。清单里带 sha256，下载侧强制校验。
class UpdateManifestClient {
  UpdateManifestClient({
    Dio? dio,
    String Function()? manifestUrlOverride,
    String Function()? downloadPrefix,
  })  : _dio = dio ?? createAppDio(),
        _manifestUrlOverride = manifestUrlOverride,
        _downloadPrefix = downloadPrefix;

  /// 官方仓库（下载地址与文档同源；改这里要同步 release.yml 的发布目标）。
  static const String repository = kUpdateRepository;

  static const int _supportedSchema = 1;

  final Dio _dio;
  final String Function()? _manifestUrlOverride;
  final String Function()? _downloadPrefix;

  /// 拉取并校验清单；失败抛 [UpdateFailureException]。
  Future<AppRelease> fetch(UpdateChannel channel) async {
    final uri = _manifestUri(channel);
    final Response<dynamic> response;
    try {
      response = await _dio.getUri<dynamic>(uri);
    } on DioException catch (e) {
      throw UpdateFailureException(
        UpdateFailureKind.network,
        '拉取更新清单失败: ${e.type} ${e.message}',
      );
    }
    if (response.httpStatus != 200) {
      throw UpdateFailureException(
        UpdateFailureKind.network,
        '更新清单返回 HTTP ${response.httpStatus}',
      );
    }
    return _parse(bodyText(response), expected: channel);
  }

  /// 资产地址经镜像前缀重写；前缀为空或配置非法时原样返回（不阻断下载）。
  Uri resolveAssetUri(Uri url) => _applyMirror(url);

  Uri _manifestUri(UpdateChannel channel) {
    final override = (_manifestUrlOverride?.call() ?? '').trim();
    if (override.isEmpty) {
      return _applyMirror(defaultUpdateManifestUri(channel));
    }
    final parsed = Uri.tryParse(override);
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      throw UpdateFailureException(
        UpdateFailureKind.manifestInvalid,
        '自定义更新清单地址非法: $override',
      );
    }
    return _applyMirror(parsed);
  }

  /// 镜像前缀（如 `https://gh-proxy.com/`）拼在完整 GitHub 地址之前。
  Uri _applyMirror(Uri url) {
    final prefix = (_downloadPrefix?.call() ?? '').trim();
    if (prefix.isEmpty) return url;
    if (url.toString().startsWith(prefix)) return url; // 已镜像，避免叠加
    final normalized = prefix.endsWith('/') ? prefix : '$prefix/';
    try {
      return Uri.parse('$normalized$url');
    } catch (_) {
      return url;
    }
  }

  AppRelease _parse(String body, {required UpdateChannel expected}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw UpdateFailureException(
        UpdateFailureKind.manifestInvalid,
        '更新清单不是合法 JSON: $e',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw UpdateFailureException(
        UpdateFailureKind.manifestInvalid,
        '更新清单顶层结构非法',
      );
    }

    if ((decoded['schema'] as num?)?.toInt() != _supportedSchema) {
      throw UpdateFailureException(
        UpdateFailureKind.manifestInvalid,
        '不支持的清单 schema: ${decoded['schema']}',
      );
    }

    final channel = UpdateChannel.fromWire(decoded['channel'] as String? ?? '');
    if (channel != expected) {
      // 渠道不符说明取到了另一条渠道的清单（如镜像配置错误），拒绝使用。
      throw UpdateFailureException(
        UpdateFailureKind.manifestInvalid,
        '清单渠道 ${channel.wireName} 与请求渠道 ${expected.wireName} 不符',
      );
    }

    final version = (decoded['version'] as String? ?? '').trim();
    if (!_semverPattern.hasMatch(version)) {
      throw UpdateFailureException(
        UpdateFailureKind.manifestInvalid,
        '清单版本号非法: $version',
      );
    }

    final build = (decoded['build'] as num?)?.toInt();
    if (build == null || build < 0) {
      throw UpdateFailureException(
        UpdateFailureKind.manifestInvalid,
        '清单缺少构建号',
      );
    }

    final assets = <ReleaseAsset>[];
    final rawAssets = decoded['assets'];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        final asset = _parseAsset(raw);
        if (asset != null) assets.add(asset);
      }
    }
    if (assets.isEmpty) {
      throw UpdateFailureException(
        UpdateFailureKind.manifestInvalid,
        '清单没有任何可解析的产物',
      );
    }

    final notesUrl = Uri.tryParse(decoded['notesUrl'] as String? ?? '');
    return AppRelease(
      schema: _supportedSchema,
      channel: channel,
      version: version,
      build: build,
      assets: assets,
      notes: (decoded['notes'] as String? ?? '').trim(),
      notesUrl: notesUrl != null && notesUrl.hasScheme ? notesUrl : null,
      releasedAt: DateTime.tryParse(decoded['releasedAt'] as String? ?? ''),
    );
  }

  /// 单个产物宽容解析：字段缺失/地址非法就跳过，不因一个坏条目丢掉整份清单。
  ReleaseAsset? _parseAsset(Object? raw) {
    if (raw is! Map) return null;
    final platform = (raw['platform'] as String? ?? '').trim();
    final kind = (raw['kind'] as String? ?? '').trim();
    final arch = ((raw['arch'] as String?) ?? 'any').trim();
    final url = Uri.tryParse(raw['url'] as String? ?? '');
    if (platform.isEmpty || kind.isEmpty) return null;
    if (url == null || !url.hasScheme || !url.hasAuthority) return null;
    if (url.scheme != 'http' && url.scheme != 'https') return null;

    final size = (raw['size'] as num?)?.toInt();
    final sha = (raw['sha256'] as String? ?? '').trim();
    return ReleaseAsset(
      platform: platform,
      arch: arch.isEmpty ? 'any' : arch,
      kind: kind,
      url: url,
      file: (raw['file'] as String? ?? '').trim().isEmpty
          ? null
          : (raw['file'] as String).trim(),
      size: size != null && size >= 0 ? size : null,
      sha256: sha.isEmpty ? null : sha,
    );
  }

  static final RegExp _semverPattern = RegExp(r'^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$');
}
