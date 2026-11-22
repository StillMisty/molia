// DownloadNotifications 域 Pigeon **channel 模式**契约，见 ADR-0038 §11。
//
// 生成（Linux 可跑，不需要 JDK 21 / Android classpath）：
//   dart run pigeon --input tool/pigeon/download_notifications.dart \
//     --dart_out lib/platform/pigeon/download_notifications.g.dart \
//     --kotlin_out android/app/src/main/kotlin/top/stillmisty/molia/pigeon/DownloadNotificationsApi.g.kt \
//     --kotlin_package top.stillmisty.molia.pigeon
//
// 方法与可空语义和 `DownloadNotifications` 端口一致：start / update 用数据类
// 传结构化字段，stop 只传 id。通知是低频单向调用，channel 足够，不用 native
// interop（`useJni`）；旧 `top.stillmisty.molia/download_notifications` 通道
// 保留为 fallback，契约测试 / Android 冒烟通过前不删 transport。
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    kotlinOptions: KotlinOptions(
      // 同包还有 widget 与 DownloadsPublisher 的 Pigeon 生成文件：
      // 每个文件默认都定义 `FlutterError`，同一 Kotlin 包里会重复声明。用独立
      // 错误类名保持各生成物互不依赖。
      errorClassName: 'DownloadNotificationsPigeonError',
    ),
  ),
)
@HostApi()
abstract class DownloadNotificationsApi {
  /// 开始 / 复用一条下载类通知（[StartRequest.id] 相同即同一条）。
  ///
  /// [StartRequest.channel] 是 `DownloadNotificationChannel.wireName`
  /// （`downloads` / `update`）；原生按 wire 值选系统通知渠道。
  void start(StartRequest request);

  /// 更新进度与文案；字段为 null 表示「不改」。
  void update(UpdateRequest request);

  /// 收尾并移除通知（完成 / 失败 / 取消同一条路径；重复调用幂等）。
  void stop(String id);
}

/// `start` 的结构化参数（对应端口 `start(...)` 的具名参数）。
class StartRequest {
  StartRequest({
    required this.id,
    required this.title,
    required this.subtitle,
    this.index,
    this.total,
    this.progress,
    this.max,
    required this.channel,
  });

  /// 任务 id（批次 / 单曲共用一个 id）。
  String id;

  /// 主标题：歌曲名 / 应用显示名。
  String title;

  /// 副标题：歌手 / 版本号；空串表示没有。
  String subtitle;

  /// 批量位置（从 1 起）；单任务与应用更新为 null。
  int? index;

  /// 批量总数；单任务与应用更新为 null。
  int? total;

  /// 已接收字节；null 表示从 0 开始。
  int? progress;

  /// 总字节；null 或 ≤ 0 表示总大小未知（不确定进度条）。
  int? max;

  /// 通知渠道 wire 值：`downloads` / `update`。
  String channel;
}

/// `update` 的结构化参数；可空字段为 null 表示「不改」。
///
/// [max] 传 0 表示回到「总大小未知」（不确定进度条），与 null 语义不同。
class UpdateRequest {
  UpdateRequest({
    required this.id,
    this.title,
    this.subtitle,
    this.index,
    this.total,
    this.progress,
    this.max,
  });

  /// 任务 id；未开始过 / 已收尾的 id 原生侧忽略。
  String id;

  String? title;

  String? subtitle;

  int? index;

  int? total;

  int? progress;

  int? max;
}
