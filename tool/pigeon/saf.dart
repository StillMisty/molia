// SAF 域 Pigeon **channel 模式**契约，见 ADR-0038 §12。
//
// 生成（Linux 可跑，不需要 JDK 21 / Android classpath）：
//   dart run pigeon --input tool/pigeon/saf.dart \
//     --dart_out lib/platform/pigeon/saf.g.dart \
//     --kotlin_out android/app/src/main/kotlin/top/stillmisty/molia/pigeon/SafApi.g.kt \
//     --kotlin_package top.stillmisty.molia.pigeon
//
// 方法是 `@asyncCallback`：Kotlin host 在后台 task queue 回调，文件 /
// ContentResolver I/O 仍由 `SafHost` 的 executor 执行，不阻塞平台主线程。
// 语义与 `SafBridge` 端口一致：stat / read 返回 null 表示不存在或不可读；
// listTree 走 begin / next / close 分批拉取，Dart 不整树读入内存。
// 旧 `top.stillmisty.molia/saf` 通道保留为 fallback，契约测试 / Android
// 冒烟通过前不删 transport。
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    kotlinOptions: KotlinOptions(
      // 同包还有 widget、DownloadsPublisher 与 DownloadNotifications 的
      // Pigeon 生成文件：每个文件默认都定义
      // `FlutterError`，同一 Kotlin 包里会重复声明。用独立错误类名保持各
      // 生成物互不依赖。
      errorClassName: 'SafPigeonError',
    ),
  ),
)
@HostApi()
abstract class SafApi {
  /// 文档 / 树根元数据；不存在（cursor 空）返回 null。
  @asyncCallback
  SafDocumentMessage? stat(String uri);

  /// 开始一次树枚举，返回会话 token；URI 不是树 / 根文档时抛错。
  @asyncCallback
  String? listTreeBegin(String uri, int maxDepth);

  /// 拉取下一批条目；[SafTreeBatchMessage.done] 为 true 表示遍历结束。
  @asyncCallback
  SafTreeBatchMessage? listTreeNext(String token, int maxEntries);

  /// 关闭会话并回收游标（幂等；未知 token 静默忽略）。
  @asyncCallback
  void listTreeClose(String token);

  /// 只读文件头（标签解析）；不存在 / 不可读返回 null。
  @asyncCallback
  Uint8List? readHead(String uri, int length);

  /// 读取 `[start, start + length)`；越界按实际可读字节返回。
  @asyncCallback
  Uint8List? readRange(String uri, int start, int length);
}

/// `stat` 的结构化结果（字段与旧通道 map 对齐；`mime` 不参与 Dart 端口）。
class SafDocumentMessage {
  SafDocumentMessage({
    required this.uri,
    required this.displayName,
    required this.isDirectory,
    required this.sizeBytes,
    required this.mtimeMs,
  });

  /// 调用方传入的文档 / 树根 URI（原样回传）。
  String uri;

  /// 展示名（provider 可能为空串）。
  String displayName;

  bool isDirectory;

  /// 字节数；provider 不提供时为 0。
  int sizeBytes;

  /// 最后修改时间（毫秒）；provider 不提供时为 0。
  int mtimeMs;
}

/// 树枚举的一条结果；[skip] 非空时表示被跳过的目录 / 文件，
/// 其余字段为空串 / false / 0。
class SafTreeEntryMessage {
  SafTreeEntryMessage({
    required this.uri,
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.sizeBytes,
    required this.mtimeMs,
    required this.skip,
  });

  /// 文件文档 URI；跳过项为空串。
  String uri;

  /// 展示名；跳过项为空串。
  String name;

  /// 相对树根的路径（`/` 分隔）。
  String relativePath;

  bool isDirectory;

  int sizeBytes;

  int mtimeMs;

  /// `hidden` / `depthExceeded` / `symlinkCycle` / `unreadable`；null 表示真实条目。
  String? skip;
}

/// `listTreeNext` 的一页结果。[done] 为 true 时 native 会话已无更多条目。
class SafTreeBatchMessage {
  SafTreeBatchMessage({required this.entries, required this.done});

  List<SafTreeEntryMessage> entries;

  bool done;
}
