/// 下载类任务通知端口的公共类型（歌曲下载 / 应用更新）。
///
/// 独立成文件：工厂（`download_notifications.dart`）与实现
/// （`download_notifications_io.dart`）各自只依赖本文件的类型，
/// `dart:io` / MethodChannel 不会泄漏给调用方
/// （与 `downloads_publisher_types.dart` 同构）。
library;

/// 系统通知渠道：歌曲下载与应用更新分开，用户可在系统设置里分别开关。
///
/// 两者共用同一个 dataSync 前台服务与通知端口，仅渠道 id / 静态文案不同。
/// [wireName] 与原生 `DownloadNotificationService.kt` 的 `channel` 参数对齐。
enum DownloadNotificationChannel {
  downloads('downloads'),
  update('update');

  const DownloadNotificationChannel(this.wireName);

  /// MethodChannel 上传递的渠道值。
  final String wireName;
}

/// 下载类任务通知端口（Android 前台服务 + 进度通知）。
///
/// 当前有两类使用者：歌曲下载（批量任务共享一条 `N/N` 通知）与应用更新
/// （固定一条通知、走独立的 `update` 渠道）。**端口只表达一条通知的生命
/// 周期**：开始 / 更新 / 收尾移除；[id] 相同即同一条，原生侧按 id 合并更新。
///
/// 文案分工：通知由系统渲染、通道必须在原生侧创建，所以结构化数据以参数
/// 传入——歌曲下载是曲目名 / 歌手 / 批量位置，应用更新是应用显示名 / 版本号；
/// 静态文案（通道名、「正在下载」、应用更新的「正在下载更新」、
/// 「批量下载 N/N」）在原生用 Android 资源（en / zh）组装——Dart 侧不拼
/// 通知字符串，也不经 `AppLocalizations`（服务层拿不到界面语言）。
///
/// **失败一律 best-effort**：实现吞掉所有平台异常（只记日志），绝不抛给调用方；
/// 无原生实现（桌面 / iOS / 测试）时 [supported] 为 false，全部方法 no-op。
abstract interface class DownloadNotifications {
  /// 当前平台是否支持系统下载 / 更新通知（仅 Android；UI 据此显隐设置开关）。
  bool get supported;

  /// 开始 / 复用一条下载类通知（[id] 相同即同一条；批量歌曲共享一个 id）。
  ///
  /// [title] 主标题（歌曲名 / 应用显示名）；[subtitle] 副标题
  /// （歌手 / 版本号，可为空）；[index] / [total] 为批量位置（从 1 起；
  /// 单任务与应用更新传 null）；[progress] / [max] 为已接收 / 总字节，
  /// [max] 为 null 或 ≤ 0 表示总大小未知（不确定进度条）。
  /// [channel] 选择系统通知渠道：歌曲下载用 `downloads`（默认，旧调用保持
  /// 原行为），应用更新用 `update`。
  Future<void> start({
    required String id,
    required String title,
    String subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
    DownloadNotificationChannel channel = DownloadNotificationChannel.downloads,
  });

  /// 更新进度与文案（歌曲下载 / 应用更新通用）；字段传 null 表示不改
  /// （[max] 传 0 表示回到「未知总大小」）。
  ///
  /// 未开始过 / 已收尾的 [id] 忽略（收尾后迟到的进度不复活通知）。
  Future<void> update({
    required String id,
    String? title,
    String? subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
  });

  /// 收尾并移除通知（完成 / 失败 / 取消同一条路径；重复调用幂等）。
  Future<void> stop(String id);
}

/// 空实现：桌面 / iOS / 单测（通知能力整体关闭）。
class NoopDownloadNotifications implements DownloadNotifications {
  const NoopDownloadNotifications();

  @override
  bool get supported => false;

  @override
  Future<void> start({
    required String id,
    required String title,
    String subtitle = '',
    int? index,
    int? total,
    int? progress,
    int? max,
    DownloadNotificationChannel channel = DownloadNotificationChannel.downloads,
  }) async {}

  @override
  Future<void> update({
    required String id,
    String? title,
    String? subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
  }) async {}

  @override
  Future<void> stop(String id) async {}
}
