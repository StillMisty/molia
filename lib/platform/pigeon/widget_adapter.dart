/// Android 小组件更新适配器：Pigeon native interop（JNI）优先，旧通道兜底。
///
/// 只做平台守卫、payload 投影与失败静默；生成绑定见同目录
/// `widget.g.dart` / `widget.native_interop.g.dart` / `widget.g.jni.dart`。
/// 手写适配器刻意不与生成物同名（source_gen 会删除同名 `.g.dart`）。
///
/// 旧 `top.stillmisty.molia/widget` 通道保留到契约测试 / release 冒烟通过；
/// 非 Android 为 no-op，失败不影响播放主流程。
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel;

import 'widget.g.dart';

const MethodChannel _legacyChannel = MethodChannel(
  'top.stillmisty.molia/widget',
);

/// 当前缓存的 native interop 句柄；只在 Android 首次更新时解析。
WidgetApi? _nativeApi;

/// native interop 是否已确认不可用：不可用时后续调用直接走旧通道，避免每次
/// 切歌都重新抛 / 捕获 JNI 解析异常。
bool _nativeInteropUnavailable = false;

/// 把旧通道的 Map payload 投影成生成的 [WidgetPayload]。
///
/// 纯映射，供单测覆盖；文案由业务层决定，这里只保证类型安全（缺失 /
/// 类型不符时给空串，不用本地化文案）。
WidgetPayload widgetPayloadFromMap(Map<String, Object?> payload) {
  return WidgetPayload(
    songName: _stringOf(payload['songName']),
    artistName: _stringOf(payload['artistName']),
    albumArtUrl: _stringOf(payload['albumArtUrl']),
    isPlaying: payload['isPlaying'] == true,
  );
}

/// 更新 Android 小组件；非 Android 或全部失败时静默返回。
///
/// Pigeon native interop 在调用线程同步执行（根 isolate 即平台主线程），
/// 与旧通道的线程语义一致；widget 更新是低频单向调用，不需要后台 isolate。
Future<void> updateAndroidWidget(Map<String, Object?> payload) async {
  if (!Platform.isAndroid) return;

  if (await _updateWithNativeInterop(payload)) return;

  // fallback：旧 channel 的 method / payload 字段保持不变。
  try {
    await _legacyChannel.invokeMethod<void>('updateWidget', payload);
  } catch (_) {
    // 更新失败静默：桌面小组件不影响播放主流程。
  }
}

Future<bool> _updateWithNativeInterop(Map<String, Object?> payload) async {
  if (_nativeInteropUnavailable) return false;
  try {
    final api = _nativeApi ??= WidgetApi.createWithNativeInteropApi();
    await api.update(widgetPayloadFromMap(payload));
    return true;
  } catch (_) {
    _nativeInteropUnavailable = true;
    _nativeApi = null;
    return false;
  }
}

String _stringOf(Object? value) => value is String ? value : '';
