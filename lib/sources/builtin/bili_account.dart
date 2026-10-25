/// B 站账号 Cookie 的进程内快照。
///
/// `BiliClient` / `BiliLyric` 是静态适配器，拿不到组合根注入的服务实例；
/// 账号服务在登录、退出、同步到达时更新这里，请求侧只读。**Cookie 不写日志**。
library;

import '../../domain/models/bili_account.dart';

class BiliAccountStore {
  BiliAccountStore._();

  static final BiliAccountStore instance = BiliAccountStore._();

  String? _cookieHeader;
  BiliAccount? _account;

  /// 账号服务初始化 Future：`BiliLyric` 先 await 再判断登录态，避免首个
  /// B 站曲目在安全存储读完前误走匿名路径。
  Future<void> ready = Future<void>.value();

  String? get cookieHeader => _cookieHeader;

  BiliAccount? get account => _account;

  /// 是否存在可用的 B 站登录 Cookie。
  bool get isLoggedIn =>
      (biliCookieValue(_cookieHeader, 'SESSDATA') ?? '').isNotEmpty;

  /// 更新 Cookie 与账号信息（空 Cookie 等价于清空）。
  void update({required String cookieHeader, BiliAccount? account}) {
    final cookie = cookieHeader.trim();
    if (cookie.isEmpty) {
      clear();
      return;
    }
    _cookieHeader = cookie;
    _account = account;
  }

  /// 只更新昵称 / UID（Cookie 不变）。
  void updateAccount(BiliAccount account) {
    if (_cookieHeader == null) return;
    _account = account;
  }

  void clear() {
    _cookieHeader = null;
    _account = null;
  }

  /// 初始化 / 测试隔离：清空内存态与初始化 Future。
  void reset() {
    clear();
    ready = Future<void>.value();
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
