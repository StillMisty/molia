/// B 站账号会话：Cookie、账号资料与初始化就绪状态的唯一进程内快照。
///
/// 静态内置适配器（`BiliClient.shared` / `BiliLyric.shared` /
/// `LyricsSourceRegistry.standard`）拿不到组合根注入的服务实例，因此
/// [BiliSession.shared] 承担生产环境的默认绑定；任何消费者都允许注入自己的
/// 会话，测试与多实例接线不需要再改全局单例。
///
/// 写入口只有账号服务（登录 / 退出 / 同步到达）；请求侧只读。**Cookie 不写日志**。
library;

import '../../domain/models/bili_account.dart';

class BiliSession {
  BiliSession();

  /// 生产默认绑定：账号服务与静态内置适配器共用这一份。
  static final BiliSession shared = BiliSession();

  /// 注入优先；null 时落到生产共享会话。所有适配器用同一处解析。
  static BiliSession resolve(BiliSession? session) => session ?? shared;

  String? _cookieHeader;
  BiliAccount? _account;
  bool _expired = false;

  /// 账号服务初始化 Future：`BiliLyric` / 账号请求先 await 再判断登录态，
  /// 避免首个 B 站曲目在安全存储读完前误走匿名路径。
  Future<void> _ready = Future<void>.value();

  String? get cookieHeader => _cookieHeader;

  BiliAccount? get account => _account;

  /// 资料校验发现登录已失效（服务在失败时标记，成功登录 / 清除时复位）。
  bool get expired => _expired;

  /// 账号服务初始化 / 凭据装载完成的 Future（[bindReady] 绑定）。
  Future<void> get ready => _ready;

  /// 是否存在可用的 B 站登录 Cookie。
  bool get isLoggedIn =>
      (biliCookieValue(_cookieHeader, 'SESSDATA') ?? '').isNotEmpty;

  void markExpired() => _expired = true;

  void clearExpired() => _expired = false;

  /// 绑定账号服务的初始化 Future：这里是唯一就绪来源，消费者不另建。
  void bindReady(Future<void> ready) {
    _ready = ready;
  }

  /// 更新 Cookie 与账号信息（空 Cookie 等价于清空）。
  void apply({required String cookieHeader, BiliAccount? account}) {
    final cookie = cookieHeader.trim();
    if (cookie.isEmpty) {
      clear();
      return;
    }
    _cookieHeader = cookie;
    _account = account;
    _expired = false;
  }

  /// 只更新昵称 / UID（Cookie 不变）。
  void updateAccount(BiliAccount account) {
    if (_cookieHeader == null) return;
    _account = account;
  }

  void clear() {
    _cookieHeader = null;
    _account = null;
    _expired = false;
  }

  /// 初始化 / 测试隔离：清空内存态与初始化 Future。
  void reset() {
    clear();
    _ready = Future<void>.value();
  }
}

/// 从 `SESSDATA=...; bili_jct=...` 形式的 Cookie header 取一个键。
String? biliCookieValue(String? cookieHeader, String name) {
  final header = cookieHeader?.trim() ?? '';
  if (header.isEmpty) return null;
  for (final part in header.split(';')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final equals = trimmed.indexOf('=');
    if (equals <= 0) continue;
    if (trimmed.substring(0, equals).trim() != name) continue;
    final value = trimmed.substring(equals + 1).trim();
    return value.isEmpty ? null : value;
  }
  return null;
}
