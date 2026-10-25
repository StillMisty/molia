import 'dart:typed_data';

import 'package:molia/services/covers/cover_resolution.dart';

/// 解析模块的假索引：测试只需要键 / 默认封面 / 字节与变更信号。
class FakeCoverIndex implements CoverIndex {
  FakeCoverIndex({
    this.defaultUrl,
    Map<String, String>? customUrls,
    Map<String, Uint8List>? customBytes,
  })  : customUrls = Map<String, String>.of(customUrls ?? const {}),
        customBytes = Map<String, Uint8List>.of(customBytes ?? const {});

  String? defaultUrl;

  @override
  String? get defaultCoverUrl => defaultUrl;

  /// 规范化封面键 → `file://` 地址。
  final Map<String, String> customUrls;

  /// 规范化封面键 → 原始字节。
  final Map<String, Uint8List> customBytes;

  final List<void Function()> _listeners = <void Function()>[];

  /// 读取字节次数（断言「默认封面不参与下载 / 取色」时使用）。
  int readCount = 0;

  int get listenerCount => _listeners.length;

  @override
  String? customCoverUrlForKey(String key) => customUrls[key];

  @override
  Future<Uint8List?> readTrackCoverByKey(String key) async {
    readCount++;
    return customBytes[key];
  }

  @override
  void Function() addRevisionListener(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void notifyChanged() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
