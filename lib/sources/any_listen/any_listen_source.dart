/// any-listen 音源适配器：把远程服务器能力适配为 SourceManager 需要的形式
/// （搜索 / 取链 / 歌词 / 封面 / 连接测试）。
///
/// ⚠️ API 端点未经验证，接入真实服务器时按官方协议校正：替换
/// [AnyListenApi]（`any_listen_api.dart`，含端点常量与文件头协议说明）后，
/// 本文件的解析逻辑按上游类型 MusicInfoOnline / MusicUrlInfo / MusicLyricInfo
/// 的形状实现，可据此校正；`raw` 始终原样透传服务器返回的曲目对象，
/// 取链/歌词/封面请求会把该对象整体回传（与 LX 脚本 `musicInfo` 的约定一致）。
library;

import '../../domain/models/any_listen.dart';
import '../source_search_result.dart';
import '../source_track.dart';
import 'any_listen_api.dart';
import 'any_listen_config.dart';
import 'any_listen_errors.dart';

/// [AnyListenTestResult] 已迁入 domain；这里 export 保持既有
/// `any_listen_source.dart` import 的下游零改动。
export '../../domain/models/any_listen.dart' show AnyListenTestResult;

/// any-listen 歌词结果（对齐上游 Music.LyricInfo 的字段子集）。
class AnyListenLyric {
  final String lyric;
  final String? tlyric;
  final String? rlyric;

  /// 逐字歌词（上游字段名 awlyric）。
  final String? awlyric;

  const AnyListenLyric({
    required this.lyric,
    this.tlyric,
    this.rlyric,
    this.awlyric,
  });
}

/// any-listen 音源。
///
/// 生命周期：构造后调用 [init] 从本地加载配置（不发起网络请求）；
/// 只有 [isUsable]（已配置且启用）为 true 时才参与搜索/播放。
class AnyListenSource {
  /// 在 SourceManager / SourceTrack 中标识本音源的 key。
  static const String sourceKey = 'any_listen';

  /// SourceTrack.origin 标记。
  static const String origin = 'any_listen';

  /// 搜索页展示名。
  static const String displayName = 'any-listen';

  final AnyListenApi _api;
  final AnyListenConfigStore _configStore;
  AnyListenConfig _config = AnyListenConfig.empty;

  AnyListenSource({
    AnyListenApi? api,
    AnyListenConfigStore? configStore,
  })  : _api = api ?? AnyListenApi(),
        _configStore = configStore ?? AnyListenConfigStore();

  AnyListenConfig get config => _config;

  bool get isConfigured => _config.isConfigured;

  /// 已配置且启用；只有此时才允许出现在 SourceManager.searchableSources。
  bool get isUsable => _config.isUsable;

  /// 判断曲目是否来自 any-listen（按 sourceKey，兼容按 origin 标记的旧数据）。
  static bool isAnyListenTrack(SourceTrack track) =>
      track.sourceKey == sourceKey || track.origin == origin;

  /// 从 shared_preferences 加载配置；只读本地，不发起网络请求。
  Future<void> init() async {
    _config = await _configStore.load();
  }

  /// 更新并持久化配置；返回是否写入成功。
  ///
  /// 地址会先归一化（去尾斜杠、缺协议补 http://），保证内存与持久化一致。
  Future<bool> updateConfig(AnyListenConfig config) async {
    _config = config.normalizedCopy();
    return _configStore.save(_config);
  }

  /// 搜索歌曲。
  ///
  /// 失败抛出 [AnyListenException]（未配置 / 连接失败 / 响应格式错误）。
  Future<SourceSearchResult> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    _ensureUsable();
    final data = await _api.searchMusic(_config, keyword, page: page, limit: limit);
    return _parseSearch(data, page: page, limit: limit);
  }

  /// 取播放地址。失败抛出 [AnyListenException]。
  Future<String> resolveUrl(
    SourceTrack track, {
    String? requestedQuality,
  }) async {
    _ensureUsable();
    if (!isAnyListenTrack(track)) {
      throw AnyListenException.badResponse(
        '曲目不属于 any-listen 音源：${track.sourceKey}',
      );
    }
    // raw 原样回传：服务端按曲目对象中的 meta.source / id 识别扩展与资源。
    final data = await _api.getMusicUrl(
      _config,
      track.raw,
      quality: requestedQuality,
    );
    final url = _extractUrl(data);
    if (url == null || url.isEmpty) {
      throw AnyListenException.badResponse('取链响应缺少 url 字段');
    }
    return url;
  }

  /// 获取歌词。无歌词返回 null（上层回退现有歌词源）；格式错误抛异常。
  Future<AnyListenLyric?> fetchLyric(SourceTrack track) async {
    _ensureUsable();
    final data = await _api.getMusicLyric(_config, track.raw);
    return _parseLyric(data);
  }

  /// 获取封面。无封面返回 null；格式错误抛异常。
  Future<String?> fetchPic(SourceTrack track) async {
    _ensureUsable();
    final data = await _api.getMusicPic(_config, track.raw);
    return _extractUrl(data);
  }

  /// 连接测试（HTTP 探测，绝不抛异常）。
  ///
  /// [overrideConfig] 允许用页面上尚未保存的表单值直接探测。
  Future<AnyListenTestResult> testConnection({
    AnyListenConfig? overrideConfig,
  }) async {
    final config = overrideConfig ?? _config;
    try {
      final probe = await _api.probe(config);
      final id = probe.serverId;
      return AnyListenTestResult(
        ok: true,
        serverId: id,
        message: (id == null || id.isEmpty)
            ? '连接成功，服务器已响应握手'
            : '连接成功，服务器标识：$id',
      );
    } on AnyListenException catch (error) {
      return AnyListenTestResult(
        ok: false,
        message: error.message,
        errorKind: error.kind,
      );
    } catch (error) {
      return AnyListenTestResult(
        ok: false,
        message: '连接失败：$error',
        errorKind: AnyListenErrorKind.unknown,
      );
    }
  }

  /// 释放资源（内部 HTTP 客户端）。
  void dispose() {
    _api.close();
  }

  void _ensureUsable() {
    if (!isUsable) throw AnyListenException.notConfigured();
  }

  // —————————————————————— 响应解析 ——————————————————————

  /// 解析搜索响应。
  ///
  /// 上游 `musicSearch` 返回 `{ list: MusicInfoOnline[], total, limit, page }`；
  /// 这里容忍 `{ data: { list } }` 包裹与若干社区常见字段名。
  SourceSearchResult _parseSearch(
    dynamic data, {
    required int page,
    required int limit,
  }) {
    if (data is! Map) {
      throw AnyListenException.badResponse('搜索响应不是 JSON 对象');
    }
    final container = data['data'] is Map ? data['data'] as Map : data;
    final rawList = container['list'] ??
        container['data'] ??
        container['songs'] ??
        container['result'];
    if (rawList is! List) {
      throw AnyListenException.badResponse('搜索响应缺少歌曲列表（list）');
    }

    final tracks = <SourceTrack>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final raw = item.map((key, value) => MapEntry(key.toString(), value));
      final title = _asText(raw['name'] ?? raw['title'] ?? raw['songName']);
      if (title == null) continue;

      final meta = raw['meta'] is Map ? raw['meta'] as Map : const {};
      tracks.add(SourceTrack(
        sourceKey: sourceKey,
        origin: origin,
        title: title,
        artist: _asText(raw['singer'] ?? raw['artist'] ?? meta['singer']) ?? '',
        album: _asText(meta['albumName'] ?? raw['albumName'] ?? raw['album']) ?? '',
        coverUrl: _asText(meta['picUrl'] ?? raw['picUrl'] ?? raw['pic'] ?? raw['img']),
        duration: _parseDuration(raw['interval'] ?? raw['duration']),
        qualities: _parseQualities(meta['qualitys'] ?? raw['qualitys']),
        // 原样透传服务器返回对象：取链/歌词/封面请求会把它整体回传。
        raw: raw,
      ));
    }
    return SourceSearchResult.fromPage(
      tracks: tracks,
      page: page,
      limit: limit,
      total: parseSourceCount(container['total'] ?? data['total']),
    );
  }

  /// 解析歌词响应，兼容 `{ info: {...} }` 与平铺两种形态。
  AnyListenLyric? _parseLyric(dynamic data) {
    if (data is! Map) {
      throw AnyListenException.badResponse('歌词响应不是 JSON 对象');
    }
    final info = data['info'] is Map ? data['info'] as Map : data;
    final lyric = _asText(info['lyric']);
    // 有响应但无歌词：返回 null，让上层回退到现有 QQ/网易/LRCLIB 歌词源。
    if (lyric == null) return null;
    return AnyListenLyric(
      lyric: lyric,
      tlyric: _asText(info['tlyric']),
      rlyric: _asText(info['rlyric']),
      awlyric: _asText(info['awlyric']),
    );
  }

  /// 从响应中提取 URL；缺失返回 null，响应类型不对则抛格式错误。
  String? _extractUrl(dynamic data) {
    if (data is String) return _asText(data);
    if (data is Map) {
      return _asText(data['url'] ?? data['data'] ?? data['link']);
    }
    throw AnyListenException.badResponse('响应格式错误：不是字符串或 JSON 对象');
  }

  String? _asText(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 解析时长：上游 interval 为 `03:55` 形式的字符串；数值按「秒」兼容。
  Duration? _parseDuration(dynamic value) {
    if (value is num) {
      final seconds = value.toInt();
      return seconds > 0 ? Duration(seconds: seconds) : null;
    }
    if (value is String) {
      final text = value.trim();
      final parts = text.split(':');
      if (parts.length >= 2) {
        final seconds = int.tryParse(parts.last.split('.').first);
        final minutes = int.tryParse(parts[parts.length - 2]);
        if (seconds != null && minutes != null) {
          final hours = parts.length >= 3 ? int.tryParse(parts[0]) ?? 0 : 0;
          return Duration(hours: hours, minutes: minutes, seconds: seconds);
        }
      }
      final seconds = int.tryParse(text);
      if (seconds != null && seconds > 0) return Duration(seconds: seconds);
    }
    return null;
  }

  /// 解析上游 meta.qualitys：`{ '320k': { sizeStr: '8.5MB' }, ... }`。
  List<SourceQuality> _parseQualities(dynamic value) {
    if (value is! Map) return const [];
    final qualities = <SourceQuality>[];
    value.forEach((key, item) {
      final type = key.toString();
      if (type.isEmpty) return;
      qualities.add(SourceQuality(
        type: type,
        size: item is Map ? _asText(item['sizeStr'] ?? item['size']) : null,
      ));
    });
    return qualities;
  }
}
