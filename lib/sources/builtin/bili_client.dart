/// B 站请求生命周期：URL / WBI 签名 / 请求头 / 业务码 / 刷新口径只在这里决定。
///
/// 业务文件（搜索 / 取链 / 评论 / 榜单 / 收藏夹 / UP / 字幕）只负责拼参数与
/// 解析 `data`。否则每个端点都要重复一遍「带不带 buvid Cookie、业务码怎么
/// 映射、-403 是会话风控还是收藏夹不可见、空 body / 非 JSON 算哪种失败」，
/// 同一份策略很快会漂移成几份。
///
/// [BiliApi] 仍是匿名会话（buvid + WBI 密钥）的唯一来源；这里只消费它的快照。
library;

import '../../domain/models/failure.dart';
import 'bili_api.dart';
import 'bili_session.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';

/// 请求鉴权口径：决定请求头、是否 WBI 签名，以及风控后是否刷新会话。
enum BiliAuth {
  /// 匿名：UA + Referer，不带 buvid Cookie，也不拉 nav 会话。
  anonymous,

  /// 会话 + WBI：buvid Cookie + 签名参数；刷新口径由
  /// [BiliRefreshPolicy] 决定（默认只对风控刷新一次）。
  session,

  /// 账号 Cookie（无 WBI）：账号资料等普通端点；**不用于播放 / 搜索 / 评论**。
  account,

  /// 账号 Cookie + buvid + WBI 签名：B 站字幕等需要登录态的 WBI 端点。
  accountSession,
}

/// 会话失败后的刷新口径（对 [BiliAuth.session] / [BiliAuth.accountSession] 有意义）。
enum BiliRefreshPolicy {
  /// 只有风控响应（`-403/-412/-352` / `v_voucher`）才刷新一次：
  /// 取链 / UP / 评论 / 榜单等端点的默认口径。
  riskOnly,

  /// 任何失败（业务码非 0、传输异常、空响应 / 非 JSON）都刷新一次再重试：
  /// ADR-0014 的搜索语义——网络抖动与会话失效都可能表现为 failed，
  /// 多一次请求换可用性。第二次失败原样上抛，刷新本身失败时报第一次失败。
  anyFailure,
}

/// 业务码口径：由端点显式声明，调用方不再自己解释 `code`。
enum BiliCodePolicy {
  /// 标准：`-404` → notFound（不可重试），其余非 0 → unknown（可重试）。
  standard,

  /// 收藏夹：`-403` / `-404` → notFound（私密 / 失效 / 无权限），其余非 0 →
  /// unknown。收藏夹的 `-403` 不是会话风控，不能触发刷新。
  favorites,

  /// 无业务码的静态 JSON（字幕文件等）：不校验 code。
  none,
}

/// B 站端点客户端（可在测试里注入独立传输 / 账号会话）。
class BiliClient {
  const BiliClient({this._transport, this._session});

  /// 生产 / 业务文件共用实例：传输走 [BuiltinSearch.transport]，账号会话走
  /// [BiliSession.shared]；测试替换全局传输或注入自己的客户端即可覆盖。
  /// 自身不持有可变状态，因此不需要 reset。
  static const BiliClient shared = BiliClient();

  final BuiltinTransport? _transport;
  final BiliSession? _session;

  /// 显式注入优先；否则跟随全局传输（组合根与既有测试的注入点）。
  BuiltinTransport get transport => _transport ?? BuiltinSearch.transport;

  /// 账号 Cookie 来源：显式注入优先，否则是生产共享会话。
  BiliSession get session => _session ?? BiliSession.shared;

  /// 发起一次 GET 并校验响应。
  ///
  /// [path] 可以是以 `/` 开头的 B 站路径（自动补 [BiliApi.baseUrl]），也可以
  /// 是完整 URL（字幕等 CDN 资源）。成功返回完整响应，失败抛
  /// [SourceFailure]；空 body / 非 JSON 由传输层抛错后在这里统一归一。
  Future<dynamic> get(
    String path, {
    Map<String, Object?>? query,
    BiliAuth auth = BiliAuth.anonymous,
    BiliCodePolicy codePolicy = BiliCodePolicy.standard,
    BiliRefreshPolicy refreshPolicy = BiliRefreshPolicy.riskOnly,
    int retries = 1,
  }) async {
    try {
      switch (auth) {
        case BiliAuth.anonymous:
          // 匿名端点没有会话可刷新，refreshPolicy 不适用。
          final response = await _getAnonymous(path, query, retries);
          _ensureAccepted(response, codePolicy);
          return response;
        case BiliAuth.session:
          return await _getWithSession(
            path,
            query,
            retries,
            codePolicy,
            refreshPolicy,
          );
        case BiliAuth.account:
          final response = await _getWithAccount(path, query, retries);
          _ensureAccepted(response, codePolicy);
          return response;
        case BiliAuth.accountSession:
          return await _getWithSession(
            path,
            query,
            retries,
            codePolicy,
            refreshPolicy,
            withAccount: true,
          );
      }
    } on SourceFailure {
      rethrow;
    } catch (error) {
      throw SourceFailure.from(error);
    }
  }

  /// 与内置平台共用的结果缓存（整表端点，如榜单）。
  Future<T> cached<T>(String key, Future<T> Function() create) =>
      transport.cached(key, create);

  /// 跟随短链跳转（b23.tv → 收藏夹链接）；只读 Location，不解析 body。
  Future<Uri?> resolveRedirect(Uri uri) =>
      transport.resolveRedirect(uri, headers: BiliApi.anonymousHeaders);

  Future<dynamic> _getAnonymous(
    String path,
    Map<String, Object?>? query,
    int retries,
  ) {
    return transport.getJson(
      _urlOf(path, query),
      headers: BiliApi.anonymousHeaders,
      retries: retries,
    );
  }

  /// 账号 Cookie、无 WBI：仅账号资料等普通端点。
  Future<dynamic> _getWithAccount(
    String path,
    Map<String, Object?>? query,
    int retries,
  ) {
    final cookie = session.cookieHeader;
    return transport.getJson(
      _urlOf(path, query),
      headers: cookie == null || cookie.isEmpty
          ? BiliApi.anonymousHeaders
          : BiliApi.accountHeaders(cookie),
      retries: retries,
    );
  }

  Future<dynamic> _getWithSession(
    String path,
    Map<String, Object?>? query,
    int retries,
    BiliCodePolicy codePolicy,
    BiliRefreshPolicy refreshPolicy, {
    bool withAccount = false,
  }) {
    return switch (refreshPolicy) {
      BiliRefreshPolicy.riskOnly => _getRiskOnly(
        path,
        query,
        retries,
        codePolicy,
        withAccount: withAccount,
      ),
      BiliRefreshPolicy.anyFailure => _getAnyFailure(
        path,
        query,
        retries,
        codePolicy,
        withAccount: withAccount,
      ),
    };
  }

  /// 只有风控响应才刷新（取链 / UP 等端点的既有语义）。
  Future<dynamic> _getRiskOnly(
    String path,
    Map<String, Object?>? query,
    int retries,
    BiliCodePolicy codePolicy, {
    required bool withAccount,
  }) async {
    final session = await BiliApi.session(transport: transport);
    final response = await _sendWithSession(
      session,
      path,
      query,
      retries,
      withAccount: withAccount,
    );
    if (!_isRiskResponse(response)) {
      _ensureAccepted(response, codePolicy);
      return response;
    }

    // 刷新只发生一次；刷新本身失败时仍报端点原始失败，不把业务失败
    // 伪装成获取会话的网络错误。
    final original = _riskFailure(response, codePolicy);
    final refreshed = await _refreshOrThrow(original);
    final retried = await _sendWithSession(
      refreshed,
      path,
      query,
      retries,
      withAccount: withAccount,
    );
    _ensureAccepted(retried, codePolicy);
    return retried;
  }

  /// ADR-0014 搜索口径：任何失败都刷新一次再重试。
  ///
  /// 会话获取也在第一次尝试内：会话接口网络抖动同样是「本次失败」，刷新
  /// 后仍值得再试。重试只有一次，第二次失败原样上抛，绝不循环。
  Future<dynamic> _getAnyFailure(
    String path,
    Map<String, Object?>? query,
    int retries,
    BiliCodePolicy codePolicy, {
    required bool withAccount,
  }) async {
    late final SourceFailure original;
    try {
      final session = await BiliApi.session(transport: transport);
      final response = await _sendWithSession(
        session,
        path,
        query,
        retries,
        withAccount: withAccount,
      );
      _ensureAccepted(response, codePolicy);
      return response;
    } on SourceFailure catch (error) {
      original = error;
    } catch (error) {
      original = SourceFailure.from(error);
    }

    // 刷新失败时报第一次的失败（旧搜索行为：refresh 异常不覆盖结果）。
    final refreshed = await _refreshOrThrow(original);
    final retried = await _sendWithSession(
      refreshed,
      path,
      query,
      retries,
      withAccount: withAccount,
    );
    _ensureAccepted(retried, codePolicy);
    return retried;
  }

  Future<BiliAnonSession> _refreshOrThrow(SourceFailure original) async {
    try {
      return await BiliApi.refresh(transport: transport);
    } catch (_) {
      // 刷新本身失败不应该盖掉原始失败：调用方要看到端点为什么失败。
      throw original;
    }
  }

  Future<dynamic> _sendWithSession(
    BiliAnonSession anonSession,
    String path,
    Map<String, Object?>? query,
    int retries, {
    required bool withAccount,
  }) {
    final headers = Map<String, String>.from(anonSession.apiHeaders);
    if (withAccount) {
      // 参数名不能叫 session：那会盖住账号会话 getter，把 buvid 当成账号
      // Cookie（或直接编译失败）。
      final accountCookie = session.cookieHeader;
      if (accountCookie != null && accountCookie.isNotEmpty) {
        headers['Cookie'] = '${headers['Cookie']}; $accountCookie';
      }
    }
    return transport.getJson(
      anonSession.signUrl(_absolute(path), query ?? const {}),
      headers: headers,
      retries: retries,
    );
  }

  /// 拼匿名请求 URL：query 值统一转字符串，null 字段不落 URL。
  String _urlOf(String path, Map<String, Object?>? query) {
    final base = _absolute(path);
    if (query == null || query.isEmpty) return base;
    return Uri.parse(base)
        .replace(
          queryParameters: <String, String>{
            for (final entry in query.entries)
              if (entry.value != null) entry.key: '${entry.value}',
          },
        )
        .toString();
  }

  String _absolute(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return '${BiliApi.baseUrl}$path';
  }

  /// 风控响应：会话端点刷新后重试一次。
  bool _isRiskResponse(dynamic response) {
    final code = _codeOf(response);
    if (code == -403 || code == -412 || code == -352) return true;
    // UP 空间接口有时 code=0 但带 v_voucher，仍按风控处理。
    final data = response is Map ? response['data'] : null;
    return data is Map && data['v_voucher'] != null;
  }

  void _ensureAccepted(dynamic response, BiliCodePolicy codePolicy) {
    if (codePolicy == BiliCodePolicy.none) return;
    final code = _codeOf(response);
    if (code == 0) return;
    throw _failureFor(code, codePolicy);
  }

  /// 风控响应对应的原始失败（刷新失败时原样抛给调用方）。
  SourceFailure _riskFailure(dynamic response, BiliCodePolicy codePolicy) {
    final code = _codeOf(response);
    // `v_voucher` 型风控的 code 可能仍是 0，没有业务码可映射。
    if (code == null || code == 0) {
      return BiliApiException(
        kind: FailureKind.unknown,
        message: 'bili: 风控校验未通过（v_voucher）',
        retryable: true,
      );
    }
    return _failureFor(code, codePolicy);
  }

  /// 业务码 → [SourceFailure]。唯一映射点，端点只选口径。
  SourceFailure _failureFor(int? code, BiliCodePolicy codePolicy) {
    final notFound =
        code == -404 ||
        (codePolicy == BiliCodePolicy.favorites && code == -403);
    if (notFound) {
      return BiliApiException(
        kind: FailureKind.notFound,
        message: codePolicy == BiliCodePolicy.favorites
            ? 'bili: 收藏夹不存在或不可见（code=${code ?? '非 JSON'}）'
            : 'bili: 内容不存在（code=${code ?? '非 JSON'}）',
        retryable: false,
      );
    }
    return BiliApiException(
      kind: FailureKind.unknown,
      message: 'bili: 接口拒绝（code=${code ?? '非 JSON'}）',
      retryable: true,
    );
  }

  static int? _codeOf(dynamic response) {
    if (response is! Map) return null;
    final code = response['code'];
    if (code is int) return code;
    if (code is num) return code.toInt();
    return int.tryParse('$code');
  }
}
