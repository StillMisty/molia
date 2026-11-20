/// SAF 的 Pigeon **channel 模式**适配器（issue #85）。
///
/// 只做平台守卫、错误分类与生成消息的透传；生成绑定见同目录
/// `saf.g.dart`。手写适配器刻意不与生成物同名（source_gen 会删除同名
/// `.g.dart`）。
///
/// 旧 `top.stillmisty.molia/saf` 通道保留为 fallback：本层只负责 Pigeon
/// transport，fallback 组合在 `lib/data/saf/pigeon_saf_bridge.dart` 完成
/// （平台层不得反向依赖 data 层，ADR-0038）。非 Android 不调用生成 API。
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'saf.g.dart';

/// Pigeon transport 不可用（原生未注册 / 引擎未就绪 / 连接中断）。
///
/// 只有这一类失败允许调用方回退旧 MethodChannel；原生返回的业务错误
/// （权限 / 文件缺失）走 [SafPigeonException]，不能靠换 transport 解决。
class SafTransportUnavailable implements Exception {
  const SafTransportUnavailable([this.message]);

  final String? message;

  @override
  String toString() =>
      'SafTransportUnavailable'
      '${message == null ? '' : ': $message'}';
}

/// 原生返回的稳定失败码：MISSING / PERMISSION_DENIED / UNSUPPORTED / IO。
///
/// 未知 code（含 INVALID_ARGUMENT / 原生异常类名）由 data 层归入 IO。
class SafPigeonException implements Exception {
  const SafPigeonException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() =>
      'SafPigeonException($code)${message == null ? '' : ': $message'}';
}

/// 生成 host API 的最小接口：便于单测注入假 host，也隔离生成类的构造细节。
abstract interface class SafHostApi {
  Future<SafDocumentMessage?> stat(String uri);

  Future<String?> listTreeBegin(String uri, int maxDepth);

  Future<SafTreeBatchMessage?> listTreeNext(String token, int maxEntries);

  Future<void> listTreeClose(String token);

  Future<Uint8List?> readHead(String uri, int length);

  Future<Uint8List?> readRange(String uri, int start, int length);
}

/// 把生成的 [SafApi] 投影成 [SafHostApi]。
class GeneratedSafHostApi implements SafHostApi {
  GeneratedSafHostApi({SafApi? api}) : _api = api ?? SafApi();

  final SafApi _api;

  @override
  Future<SafDocumentMessage?> stat(String uri) => _api.stat(uri);

  @override
  Future<String?> listTreeBegin(String uri, int maxDepth) =>
      _api.listTreeBegin(uri, maxDepth);

  @override
  Future<SafTreeBatchMessage?> listTreeNext(String token, int maxEntries) =>
      _api.listTreeNext(token, maxEntries);

  @override
  Future<void> listTreeClose(String token) => _api.listTreeClose(token);

  @override
  Future<Uint8List?> readHead(String uri, int length) =>
      _api.readHead(uri, length);

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) =>
      _api.readRange(uri, start, length);
}

/// Pigeon transport 的窄接口，供 fallback 组合与单测注入。
abstract interface class SafPigeonTransport {
  /// 当前平台是否支持 SAF 访问（仅 Android）。
  bool get supported;

  /// Pigeon transport 是否仍可用；连接失败后置 false，后续调用直接走 fallback。
  bool get transportAvailable;

  Future<SafDocumentMessage?> stat(String uri);

  Future<String?> listTreeBegin(String uri, int maxDepth);

  Future<SafTreeBatchMessage?> listTreeNext(String token, int maxEntries);

  Future<void> listTreeClose(String token);

  Future<Uint8List?> readHead(String uri, int length);

  Future<Uint8List?> readRange(String uri, int start, int length);
}

/// Pigeon 优先的 SAF transport：Android 调生成 API，其余平台不调用。
///
/// 生成契约是 `@asyncCallback`：Kotlin host 在后台 task queue 回调，文件
/// I/O 由 `SafHost` 的 executor 执行，平台主线程不阻塞。
class PigeonSafAdapter implements SafPigeonTransport {
  PigeonSafAdapter({SafHostApi? api, bool? isAndroid})
    : _api = api ?? GeneratedSafHostApi(),
      _isAndroid = isAndroid ?? Platform.isAndroid;

  final SafHostApi _api;
  final bool _isAndroid;

  /// 首次 transport 失败即视为 Pigeon 缺失（旧版原生未注册 / 引擎未就绪），
  /// 后续调用直接走 fallback，避免每次多一次失败往返。
  bool _unavailable = false;

  @override
  bool get supported => _isAndroid;

  @override
  bool get transportAvailable => _isAndroid && !_unavailable;

  @override
  Future<SafDocumentMessage?> stat(String uri) => _call(() => _api.stat(uri));

  @override
  Future<String?> listTreeBegin(String uri, int maxDepth) =>
      _call(() => _api.listTreeBegin(uri, maxDepth));

  @override
  Future<SafTreeBatchMessage?> listTreeNext(String token, int maxEntries) =>
      _call(() => _api.listTreeNext(token, maxEntries));

  @override
  Future<void> listTreeClose(String token) =>
      _call(() => _api.listTreeClose(token));

  @override
  Future<Uint8List?> readHead(String uri, int length) =>
      _call(() => _api.readHead(uri, length));

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) =>
      _call(() => _api.readRange(uri, start, length));

  /// 统一错误分类：只有连接层失败才是 [SafTransportUnavailable]。
  Future<T> _call<T>(Future<T> Function() call) async {
    if (!transportAvailable) {
      throw const SafTransportUnavailable();
    }
    try {
      return await call();
    } on PlatformException catch (e) {
      // Pigeon 未注册时 BasicMessageChannel 返回 null reply，生成代码抛
      // `channel-error`；这是唯一可回退的连接层错误。
      if (e.code == 'channel-error') {
        _unavailable = true;
        throw SafTransportUnavailable(e.message);
      }
      throw SafPigeonException(e.code, e.message);
    } on MissingPluginException catch (e) {
      _unavailable = true;
      throw SafTransportUnavailable(e.message);
    } catch (e) {
      // 编解码失败 / 生成代码结构不匹配：视为 transport 不可用，交由旧通道。
      _unavailable = true;
      throw SafTransportUnavailable(e.toString());
    }
  }
}
