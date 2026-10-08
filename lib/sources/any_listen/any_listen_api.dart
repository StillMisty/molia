/// any-listen HTTP 传输层与端点常量（唯一可替换区）。
///
/// ⚠️ API 端点未经验证，接入真实服务器时按官方协议校正本文件 ⚠️
///
/// 已比对 any-listen 上游源码（`packages/web-server/src/modules/ipc/index.ts`）的
/// 握手端点，可直接用于连接探测：
/// - `GET  /api/ipc/hello` → 响应体为握手魔数 `Hello~::^-^::~v1~`（IPC_CODE.helloMsg）
/// - `GET  /api/ipc/id`    → 响应体为服务器标识（前缀 `OjppZDo6-`）
/// - `POST /api/ipc/ah`    → 鉴权（请求头 m/s，成功时响应头带 token）
///
/// 而歌曲搜索 / 取链 / 歌词 / 封面在官方实现中走 **WebSocket IPC**（加密消息），
/// 对应 action 依次为 `musicSearch` / `getMusicUrl` / `getMusicLyric` /
/// `getMusicPic`（见上游 `ipc.d.ts` / `resource_ipc.d.ts` / `music_ipc.d.ts`）。
/// 本骨架受「不引入 dart:io WebSocket、保证 Web 编译安全」约束，暂以 HTTP
/// 占位端点实现，响应字段按上游类型 MusicInfoOnline / MusicUrlInfo /
/// MusicLyricInfo 的形状解析。接入真实服务器时只需替换本类（含
/// [AnyListenEndpoints] 与响应解码），`AnyListenSource` 的解析逻辑可据此校正。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'any_listen_config.dart';
import 'any_listen_errors.dart';

/// 所有 HTTP 路径的唯一定义处。
///
/// 替换接入方式（HTTP → WebSocket IPC）时，应同步替换 [AnyListenApi] 的
/// 各方法实现，保持方法签名不变即可让上层适配器原样工作。
class AnyListenEndpoints {
  const AnyListenEndpoints._();

  static const String apiPrefix = '/api';

  // —— 已比对上游客端源码的握手端点（用于连接探测）——
  static const String hello = '$apiPrefix/ipc/hello';
  static const String serverId = '$apiPrefix/ipc/id';
  static const String auth = '$apiPrefix/ipc/ah';

  /// 握手魔数，对应上游 IPC_CODE.helloMsg。
  static const String helloMagic = 'Hello~::^-^::~v1~';

  // —— 以下为占位资源端点（TODO：真实协议为 WS IPC action）——
  /// TODO(any-listen): 对应 WS action `musicSearch`；
  /// 官方参数为 { name, page, limit, extensionId, source }。
  static const String musicSearch = '$apiPrefix/music/search';

  /// TODO(any-listen): 对应 WS action `getMusicUrl`。
  static const String musicUrl = '$apiPrefix/music/url';

  /// TODO(any-listen): 对应 WS action `getMusicLyric`。
  static const String musicLyric = '$apiPrefix/music/lyric';

  /// TODO(any-listen): 对应 WS action `getMusicPic`。
  static const String musicPic = '$apiPrefix/music/pic';
}

/// 连接探测结果（握手成功时返回服务器标识）。
class AnyListenProbeResult {
  /// `GET /api/ipc/id` 返回的服务器标识（可选信息，获取失败时为 null）。
  final String? serverId;

  const AnyListenProbeResult({this.serverId});

  bool get hasServerId => serverId != null && serverId!.isNotEmpty;
}

/// any-listen HTTP 客户端。
///
/// 职责边界：只负责「URL 拼装 / 请求头 / 超时 / 状态码归类 / JSON 解码」，
/// 不做业务字段解析；业务解析在 `AnyListenSource` 中，便于替换本类时对照。
class AnyListenApi {
  AnyListenApi({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _injectedClient = client;

  /// 外部注入的客户端（可选）；为空时在首次请求时惰性创建。
  ///
  /// 惰性创建很重要：`SourceManager` 在构造时就持有 [AnyListenSource]，
  /// 若此处立即 `http.Client()`，在 flutter_test 的 mock HttpOverrides 下
  /// 脱离 test zone 构造会抛异常，也会给未配置用户带来无谓的对象创建。
  final http.Client? _injectedClient;
  http.Client? _ownedClient;

  final Duration timeout;

  http.Client get _client => _injectedClient ?? (_ownedClient ??= http.Client());

  /// 连接探测：`GET /api/ipc/hello` 校验握手魔数，随后尽力获取 server id。
  ///
  /// 失败抛出 [AnyListenException]（connectionFailed / badResponse / ...）。
  Future<AnyListenProbeResult> probe(AnyListenConfig config) async {
    _requireConfigured(config);
    final hello = await getText(config, AnyListenEndpoints.hello);
    if (!hello.contains(AnyListenEndpoints.helloMagic)) {
      throw AnyListenException.badResponse(
        '服务器响应不是 any-listen（缺少握手标识 ${AnyListenEndpoints.helloMagic}）',
      );
    }
    String? serverId;
    try {
      final id = await getText(config, AnyListenEndpoints.serverId);
      if (id.trim().isNotEmpty) serverId = id.trim();
    } on AnyListenException {
      // serverId 只是附加信息：hello 探测已证明服务器可达，不因此判定失败。
    }
    return AnyListenProbeResult(serverId: serverId);
  }

  /// 搜索歌曲。TODO(any-listen): 替换为 WS action `musicSearch`。
  Future<dynamic> searchMusic(
    AnyListenConfig config,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) {
    _requireConfigured(config);
    return getJson(
      config,
      AnyListenEndpoints.musicSearch,
      query: {
        // 官方参数名为 name（不是 keyword），先按此探测。
        'name': keyword,
        'page': '$page',
        'limit': '$limit',
        // TODO(any-listen): extensionId / source 的选择策略待定
        // （需要先实现扩展与资源列表拉取）。
      },
    );
  }

  /// 取播放地址。TODO(any-listen): 替换为 WS action `getMusicUrl`。
  Future<dynamic> getMusicUrl(
    AnyListenConfig config,
    Map<String, dynamic> musicInfo, {
    String? quality,
  }) {
    _requireConfigured(config);
    return postJson(
      config,
      AnyListenEndpoints.musicUrl,
      body: {
        'musicInfo': musicInfo,
        // TODO(any-listen): 官方还支持 isRefresh；quality 取值参考 Music.Quality
        // （128k/192k/320k/flac/flac24bit...）。
        if (quality != null && quality.isNotEmpty) 'quality': quality,
      },
    );
  }

  /// 获取歌词。TODO(any-listen): 替换为 WS action `getMusicLyric`。
  Future<dynamic> getMusicLyric(
    AnyListenConfig config,
    Map<String, dynamic> musicInfo,
  ) {
    _requireConfigured(config);
    return postJson(
      config,
      AnyListenEndpoints.musicLyric,
      body: {'musicInfo': musicInfo},
    );
  }

  /// 获取封面。TODO(any-listen): 替换为 WS action `getMusicPic`。
  Future<dynamic> getMusicPic(
    AnyListenConfig config,
    Map<String, dynamic> musicInfo,
  ) {
    _requireConfigured(config);
    return postJson(
      config,
      AnyListenEndpoints.musicPic,
      body: {'musicInfo': musicInfo},
    );
  }

  /// GET 文本（握手探测用）。
  Future<String> getText(
    AnyListenConfig config,
    String path, {
    Map<String, String>? query,
  }) async {
    _requireConfigured(config);
    final response = await _send(
      () => _client.get(_uri(config, path, query: query), headers: _headers(config)),
    );
    return _decodeText(response);
  }

  /// GET + JSON 解码。
  Future<dynamic> getJson(
    AnyListenConfig config,
    String path, {
    Map<String, String>? query,
  }) async {
    final text = await getText(config, path, query: query);
    return _decodeJson(text);
  }

  /// POST JSON + 响应 JSON 解码。
  Future<dynamic> postJson(
    AnyListenConfig config,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    _requireConfigured(config);
    final response = await _send(
      () => _client.post(
        _uri(config, path, query: query),
        headers: _headers(config, json: true),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return _decodeJson(_decodeText(response));
  }

  /// 关闭内部创建的 HTTP 客户端（外部注入的客户端由调用方负责）。
  void close() {
    _ownedClient?.close();
    _ownedClient = null;
  }

  void _requireConfigured(AnyListenConfig config) {
    if (!config.isConfigured) throw AnyListenException.notConfigured();
  }

  Uri _uri(AnyListenConfig config, String path, {Map<String, String>? query}) {
    // serverUrl 已归一化（无尾部斜杠、带协议），直接拼接即可保留反代子路径。
    final base = Uri.parse('${config.serverUrl}$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, ...query});
  }

  Map<String, String> _headers(AnyListenConfig config, {bool json = false}) {
    return {
      'Accept': 'application/json',
      if (json) 'Content-Type': 'application/json; charset=utf-8',
      // TODO(any-listen): 官方 WebSocket 鉴权走 `POST /api/ipc/ah` 的 m/s 头 +
      // 服务端下发 token；资源请求的令牌传递方式未验证，接入时按官方协议校正。
      if (config.token.isNotEmpty) 'Authorization': 'Bearer ${config.token}',
    };
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      final response = await request().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AnyListenException.fromHttpStatus(response.statusCode);
      }
      return response;
    } on AnyListenException {
      rethrow;
    } on http.ClientException catch (error) {
      throw AnyListenException(
        AnyListenErrorKind.connectionFailed,
        '无法连接 any-listen 服务器：${error.message.isEmpty ? '网络请求失败' : error.message}',
        cause: error,
      );
    } catch (error) {
      throw AnyListenException.from(error);
    }
  }

  /// 按 UTF-8 解码响应体（http 包默认 charset 缺失时按 latin1 处理，会破坏中文）。
  String _decodeText(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  dynamic _decodeJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException catch (error) {
      throw AnyListenException.badResponse(
        'any-listen 响应不是合法 JSON',
        cause: error,
      );
    }
  }
}
