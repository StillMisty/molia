// DownloadsPublisher 域 Pigeon **channel 模式**契约，见 ADR-0038 §10。
//
// 生成（Linux 可跑，不需要 JDK 21 / Android classpath）：
//   dart run pigeon --input tool/pigeon/downloads_publisher.dart \
//     --dart_out lib/platform/pigeon/downloads_publisher.g.dart \
//     --kotlin_out android/app/src/main/kotlin/top/stillmisty/molia/pigeon/DownloadsPublisherApi.g.kt \
//     --kotlin_package top.stillmisty.molia.pigeon
//
// 方法与参数顺序和 `DownloadsPublisher` 端口一致；旧
// `top.stillmisty.molia/downloads` 通道保留为 fallback，契约测试 / Android
// 冒烟通过前不删 transport。下载发布本身是 I/O，channel 稳定且足够，不用
// native interop（`useJni`）。
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    kotlinOptions: KotlinOptions(
      // 同包还有 widget 域的 Pigeon 生成文件：每个文件默认都定义
      // `FlutterError`，同一 Kotlin 包里会重复声明。用独立的错误类名保持两份
      // 生成物互不依赖（widget 试点将来移除也不影响本文件）。
      errorClassName: 'DownloadsPublisherPigeonError',
    ),
  ),
)
@HostApi()
abstract class DownloadsPublisherApi {
  /// 公共 Downloads 的展示根（Android：`.../Download/Molia`）。
  String? publicRoot();

  /// 把应用私有文件发布到公共 Downloads，返回 content URI；失败返回 null。
  String? publish(
    String sourcePath,
    String displayName,
    String mimeType,
    String relativeDir,
  );

  /// 删除公共副本（幂等）；失败返回 false。
  bool remove(String uri);
}
