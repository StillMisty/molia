import 'package:molia/data/downloads/downloads_publisher.dart';

/// 内存公共目录发布器（下载服务测试用）：记录调用、可控制失败。
class FakeDownloadsPublisher implements DownloadsPublisher {
  FakeDownloadsPublisher({this.supported = true, this.failPublish = false});

  /// [supported] 为 false 时模拟非 Android 平台（发布整体 no-op）。
  @override
  bool supported;

  /// true 时 [publish] 返回 null（模拟原生失败）。
  bool failPublish;

  /// 发布过的源路径（按调用顺序）。
  final List<String> published = [];

  /// 发布时的显示名 / MIME 类型 / 子目录（与 [published] 同序）。
  final List<String> displayNames = [];
  final List<String> mimeTypes = [];
  final List<String> relativeDirs = [];

  /// `publicRoot` 返回值（模拟 Android 展示路径）。
  String? publicRootValue;

  /// 已删除的公共 URI（按调用顺序）。
  final List<String> removed = [];

  /// 下一个 publish 返回的 URI（默认按序号生成）。
  String Function(String displayName)? uriFactory;

  @override
  Future<String?> publicRoot() async => supported
      ? (publicRootValue ?? '/storage/emulated/0/Download/Molia')
      : null;

  @override
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String relativeDir = '',
  }) async {
    if (!supported || failPublish) return null;
    published.add(sourcePath);
    displayNames.add(displayName);
    mimeTypes.add(mimeType);
    relativeDirs.add(relativeDir);
    return uriFactory?.call(displayName) ??
        'content://media/external/downloads/${published.length}';
  }

  @override
  Future<bool> remove(String uri) async {
    if (!supported) return false;
    removed.add(uri);
    return true;
  }
}
