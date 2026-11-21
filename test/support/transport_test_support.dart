import 'package:dio/dio.dart';

import 'package:molia/sources/builtin/builtin_transport.dart';

/// 测试用内置传输：默认重试退避为 no-op，断言只关心次数 / 结果，
/// 不让指数退避拖慢用例；需要验证退避的用例仍可显式传 [retryDelay]。
BuiltinTransport testTransport({
  Dio? dio,
  Future<void> Function(int attempt)? retryDelay,
}) => BuiltinTransport(dio: dio, retryDelay: retryDelay ?? (_) async {});
