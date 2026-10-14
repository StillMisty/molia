/// 本地文件图片（`file://`）的 ImageProvider 解析（Web 编译安全）。
///
/// 本地下载封面存 `downloads/covers/`，以 `file://` URI 出现在曲目
/// artwork 上；网络图片组件与封面取色服务共用本入口，把 file URI 交给
/// `FileImage`（IO 平台）或按不支持处理（Web 恒为 null）。
library;

import 'package:flutter/widgets.dart' show ImageProvider;

import 'local_image_provider_stub.dart'
    if (dart.library.io) 'local_image_provider_io.dart' as platform;

/// `file://` URI → [ImageProvider]；非 file URI 或平台不支持返回 null。
ImageProvider? localFileImageProvider(String url) =>
    platform.localFileImageProvider(url);
