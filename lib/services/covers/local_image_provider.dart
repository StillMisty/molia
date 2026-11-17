/// 本地文件图片（`file://`）的 ImageProvider 解析。
///
/// 本地下载封面存 `downloads/covers/`，以 `file://` URI 出现在曲目
/// artwork 上；网络图片组件与封面取色服务共用本入口，把 file URI 交给
/// `FileImage`（实现见 `local_image_provider_io.dart`），无法解析时返回 null。
library;

import 'package:flutter/widgets.dart' show ImageProvider;

import 'local_image_provider_io.dart' as platform;

/// `file://` URI → [ImageProvider]；非 file URI / 路径无法解析时返回 null。
ImageProvider? localFileImageProvider(String url) =>
    platform.localFileImageProvider(url);
