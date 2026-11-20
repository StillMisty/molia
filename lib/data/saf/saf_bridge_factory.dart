/// SAF bridge 的装配入口：Android 优先 Pigeon channel，旧通道兜底。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import '../../platform/pigeon/saf_adapter.dart';
import 'method_channel_saf_bridge.dart';
import 'pigeon_saf_bridge.dart';
import 'saf_bridge.dart';

/// 创建当前平台的 SAF 端口。
///
/// - Android：Pigeon 优先，连接层失败（原生未注册 / 引擎未就绪）回退旧
///   `top.stillmisty.molia/saf` 通道；
/// - 其它平台：没有 SAF，返回 null（调用方继续走 dart:io 文件树）。
SafBridge? createSafBridge({
  SafPigeonTransport? pigeon,
  SafBridge? fallback,
  bool? isAndroid,
}) {
  final android = isAndroid ?? defaultTargetPlatform == TargetPlatform.android;
  if (!android) return null;
  return PigeonFirstSafBridge(
    pigeon: pigeon ?? PigeonSafAdapter(),
    fallback: fallback ?? MethodChannelSafBridge(),
  );
}
