/// 下载通知端口的公共类型。
///
/// 独立成文件，避免工厂（`download_notifications.dart`）与平台实现
/// （`download_notifications_io.dart` / `download_notifications_stub.dart`）
/// 循环依赖，同时保证 Web 编译不引入 `dart:io` / MethodChannel
/// （与 `downloads_publisher_types.dart` 同构）。
library;

/// 下载任务通知端口（Android 前台服务 + 进度通知）。
///
/// **端口只表达一条通知的生命周期**：开始 / 更新 / 收尾移除；「批量共享一条
/// N/N 通知」由调用方（`DownloadService`）用同一个 [id] 表达，原生侧按
/// id 合并更新。
///
/// 文案分工：通知由系统渲染、通道必须在原生侧创建，所以曲目名 / 歌手 / 批量
/// 位置 / 进度以结构化数据传入，静态文案（通道名、「正在下载」、
/// 「批量下载 N/N」）在原生用 Android 资源（en / zh）组装——Dart 侧不拼通知
/// 字符串，也不经 `AppLocalizations`（服务层拿不到界面语言）。
///
/// **失败一律 best-effort**：实现吞掉所有平台异常（只记日志），绝不抛给调用方；
/// 无原生实现（Web / 桌面 / 测试）时 [supported] 为 false，全部方法 no-op。
abstract interface class DownloadNotifications {
  /// 当前平台是否支持系统下载通知（仅 Android；UI 据此显隐设置开关）。
  bool get supported;

  /// 开始 / 复用一条下载通知（[id] 相同即同一条，批量任务共享一个 id）。
  ///
  /// [title] 曲目名；[subtitle] 歌手（可为空）；[index] / [total] 为批量位置
  /// （从 1 起；单任务传 null）；[progress] / [max] 为已接收 / 总字节，
  /// [max] 为 null 或 ≤ 0 表示总大小未知（不确定进度条）。
  Future<void> start({
    required String id,
    required String title,
    String subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
  });

  /// 更新进度与文案；字段传 null 表示不改（[max] 传 0 表示回到「未知总大小」）。
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

/// 空实现：Web / 桌面 / iOS / 单测（通知能力整体关闭）。
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
