/// B 站账号会话服务：扫码登录 → 凭据持久化 / 同步 → 账号资料 → 退出。
///
/// 凭据登记在 `kBiliAccountCookie`（凭证类别 + secure 盒）：
/// - 开启跨设备同步后随快照 AES-256-GCM 加密同步；
/// - 完整备份默认包含全部类别与凭证（换机状态一致，见 ADR-0016）；
/// - 只用于 B 站字幕 / 账号资料，播放 / 搜索 / 评论 / 字幕 CDN 继续匿名。
///
/// 页面只消费 [BiliAccountStatus] / [BiliAccount] / 二维码轮询结果；Cookie
/// 不进入 domain 展示面，也不写日志。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../domain/models/bili_account.dart';
import '../sources/builtin/bili_account.dart';
import '../sources/builtin/bili_login.dart';

class BiliAccountService extends ChangeNotifier {
  BiliAccountService({required this._settings, BiliQrLogin? login})
    : _login = login ?? BiliQrLogin();

  final SettingsAccess _settings;
  final BiliQrLogin _login;
  final Logger _logger = Logger('molia.bili_account');

  BiliAccountStatus _status = BiliAccountStatus.unknown;
  BiliAccount? _account;
  bool _sessionExpired = false;
  bool _lastLoginPersisted = true;

  Future<void>? _initFuture;
  String? _pendingQrKey;
  int _qrGeneration = 0;
  DateTime? _lastProfileFetch;

  /// 本地扫码登录成功或同步到达新登录态时触发（组合根接线：清 B 站取词
  /// 缓存并刷新当前歌词）。
  VoidCallback? onLoggedIn;

  BiliAccountStatus get status => _status;

  BiliAccount? get account => _account;

  /// 资料校验发现登录已失效（供页面显示「登录已过期」）。
  bool get sessionExpired => _sessionExpired;

  /// 最近一次扫码登录是否成功写入设置存储（false = 本次会话可用，重启失效）。
  bool get lastLoginPersisted => _lastLoginPersisted;

  /// 读取本地 / 同步到达的凭据；幂等。`BiliAccountStore.ready` 会等它完成。
  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    BiliAccountStore.instance.reset();
    final future = _loadFromSettings();
    _initFuture = future;
    BiliAccountStore.instance.ready = future;
    return future;
  }

  Future<void> _loadFromSettings() async {
    final cookie = await _readCookie();
    _applyCookie(cookie);
    notifyListeners();
  }

  /// 同步应用远端凭据后的重载入口（`SettingsRegistry.bindReload`）。
  Future<void> reloadFromSettings() async {
    await init();
    final cookie = await _readCookie();
    final changed = _applyCookie(cookie);
    if (!changed) return;
    notifyListeners();
    if (cookie.isNotEmpty) {
      onLoggedIn?.call();
      unawaited(refreshProfile(force: true));
    }
  }

  /// 校验 / 刷新账号资料；null 资料视为登录失效并清掉同步凭据。
  Future<void> refreshProfile({bool force = false}) async {
    await init();
    if (_status != BiliAccountStatus.loggedIn) return;
    final cookie = BiliAccountStore.instance.cookieHeader;
    if (cookie == null || cookie.isEmpty) return;
    final now = DateTime.now();
    final last = _lastProfileFetch;
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _lastProfileFetch = now;
    try {
      final profile = await _login.fetchProfile();
      if (BiliAccountStore.instance.cookieHeader != cookie) return;
      if (profile == null) {
        _logger.info('B 站登录已失效，清除账号凭据');
        await _clearCookie();
        BiliAccountStore.instance.clear();
        _account = null;
        _status = BiliAccountStatus.loggedOut;
        _sessionExpired = true;
        notifyListeners();
        return;
      }
      final merged = BiliAccount(
        userId: profile.userId.isNotEmpty
            ? profile.userId
            : (_account?.userId ?? ''),
        userName: profile.userName ?? _account?.userName,
      );
      _account = merged;
      BiliAccountStore.instance.updateAccount(merged);
      notifyListeners();
    } catch (e) {
      // 网络失败不判失效：保留登录态，下次打开账号页再试。
      _logger.warning('B 站账号资料获取失败: ${e.runtimeType}');
    }
  }

  /// 生成二维码；返回只含 URL 的会话，轮询 key 留在服务里。
  Future<BiliQrLoginSession> startQrLogin() async {
    await init();
    _qrGeneration++;
    _pendingQrKey = null;
    final code = await _login.generate();
    _pendingQrKey = code.key;
    return BiliQrLoginSession(url: code.url);
  }

  /// 轮询当前二维码。页面按 2s 节拍调用；网络失败返回 retryable，不丢 key。
  Future<BiliQrPollResult> pollQrLogin() async {
    final key = _pendingQrKey;
    if (key == null) {
      return const BiliQrPollResult(
        status: BiliQrPollStatus.failed,
        retryable: true,
      );
    }
    final generation = _qrGeneration;
    try {
      final outcome = await _login.poll(key);
      if (generation != _qrGeneration) {
        return const BiliQrPollResult(
          status: BiliQrPollStatus.failed,
          retryable: true,
        );
      }
      switch (outcome.status) {
        case BiliQrPollStatus.confirmed:
          final credentials = outcome.credentials;
          _pendingQrKey = null;
          if (credentials == null) {
            return const BiliQrPollResult(status: BiliQrPollStatus.failed);
          }
          _applyCookie(credentials.cookieHeader);
          final persisted = await _persistCookie(credentials.cookieHeader);
          _lastLoginPersisted = persisted;
          _sessionExpired = false;
          notifyListeners();
          onLoggedIn?.call();
          unawaited(refreshProfile(force: true));
          return BiliQrPollResult(
            status: BiliQrPollStatus.confirmed,
            account: _account,
            persisted: persisted,
          );
        case BiliQrPollStatus.expired:
        case BiliQrPollStatus.failed:
          _pendingQrKey = null;
          return BiliQrPollResult(
            status: outcome.status,
            retryable: outcome.retryable,
          );
        case BiliQrPollStatus.waiting:
        case BiliQrPollStatus.scanned:
          return BiliQrPollResult(status: outcome.status);
      }
    } catch (e) {
      // 网络 / 风控失败：保留 key，页面可原地重试。
      _logger.warning('B 站扫码轮询失败: ${e.runtimeType}');
      return const BiliQrPollResult(
        status: BiliQrPollStatus.failed,
        retryable: true,
      );
    }
  }

  /// 页面关闭 / 重新生成二维码时丢弃当前轮询 key。
  void cancelQrLogin() {
    _qrGeneration++;
    _pendingQrKey = null;
  }

  /// 退出登录：清空同步凭据（会传播到其它设备）并清内存态。
  ///
  /// 删除失败时保持登录态并向上抛，由页面提示重试，避免「界面退了、磁盘上
  /// 还留着凭据」的假退出。
  Future<void> logout() async {
    await init();
    await _settings.clear(kBiliAccountCookie);
    _qrGeneration++;
    _pendingQrKey = null;
    BiliAccountStore.instance.clear();
    _account = null;
    _status = BiliAccountStatus.loggedOut;
    _sessionExpired = false;
    _lastLoginPersisted = true;
    _lastProfileFetch = null;
    notifyListeners();
  }

  Future<String> _readCookie() async {
    try {
      final raw = await _settings
          .read(kBiliAccountCookie)
          .timeout(const Duration(seconds: 2));
      return raw.trim();
    } catch (_) {
      return '';
    }
  }

  Future<bool> _persistCookie(String cookie) async {
    try {
      await _settings.write(kBiliAccountCookie, cookie);
      return true;
    } catch (e) {
      _logger.warning('B 站登录信息保存失败: ${e.runtimeType}');
      return false;
    }
  }

  Future<void> _clearCookie() async {
    try {
      await _settings.clear(kBiliAccountCookie);
    } catch (e) {
      _logger.warning('B 站登录信息清除失败: ${e.runtimeType}');
    }
  }

  /// 应用 Cookie；返回登录态是否发生变化。
  bool _applyCookie(String cookie) {
    final trimmed = cookie.trim();
    final previous = BiliAccountStore.instance.cookieHeader;
    if (trimmed.isEmpty) {
      final changed =
          _status != BiliAccountStatus.loggedOut || previous != null;
      BiliAccountStore.instance.clear();
      _account = null;
      _status = BiliAccountStatus.loggedOut;
      _sessionExpired = false;
      _lastProfileFetch = null;
      return changed;
    }
    final same = previous == trimmed && _status == BiliAccountStatus.loggedIn;
    if (same) return false;
    final account = BiliAccount(
      userId: biliCookieValue(trimmed, 'DedeUserID') ?? '',
    );
    BiliAccountStore.instance.update(cookieHeader: trimmed, account: account);
    _account = account;
    _status = BiliAccountStatus.loggedIn;
    _sessionExpired = false;
    _lastLoginPersisted = true;
    _lastProfileFetch = null;
    return true;
  }
}
