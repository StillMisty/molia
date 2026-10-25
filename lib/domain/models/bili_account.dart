/// B 站账号的展示信息与扫码登录状态（不含 Cookie 本体）。
library;

/// 当前登录的 B 站账号（Cookie 只在 sources / services 层流转）。
class BiliAccount {
  const BiliAccount({required this.userId, this.userName});

  /// B 站 UID（Cookie 里的 `DedeUserID` / nav 的 `mid`）。
  final String userId;

  /// 昵称；资料尚未拉到或拉取失败时为 null。
  final String? userName;

  BiliAccount copyWith({String? userId, String? userName}) => BiliAccount(
    userId: userId ?? this.userId,
    userName: userName ?? this.userName,
  );

  @override
  bool operator ==(Object other) =>
      other is BiliAccount &&
      other.userId == userId &&
      other.userName == userName;

  @override
  int get hashCode => Object.hash(userId, userName);
}

/// 账号会话状态。
enum BiliAccountStatus {
  /// 还在读本地登录信息（设置页据此显示加载态）。
  unknown,
  loggedOut,
  loggedIn,
}

/// 一次扫码登录会话的展示信息：只暴露二维码内容，轮询 key 留在服务内。
class BiliQrLoginSession {
  const BiliQrLoginSession({required this.url});

  /// 二维码内容（B 站 App 扫码用）。
  final String url;
}

/// 单次扫码轮询的结果状态。
enum BiliQrPollStatus { waiting, scanned, confirmed, expired, failed }

/// 二维码轮询结果（页面只消费这个类型，不接触 Cookie）。
class BiliQrPollResult {
  const BiliQrPollResult({
    required this.status,
    this.account,
    this.persisted = true,
    this.retryable = false,
  });

  final BiliQrPollStatus status;

  /// 登录成功后的账号展示信息。
  final BiliAccount? account;

  /// 登录信息是否已成功写入设置存储（false = 本次会话可用，重启需重登）。
  final bool persisted;

  /// 失败是否值得原二维码重试（网络抖动）；过期 / 无效则为 false。
  final bool retryable;
}
