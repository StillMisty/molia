/// 内置检索 runner（[runBuiltinSearch]）的契约。
///
/// 请求构造、响应级重试与非法响应判定收进 [BuiltinSearchCall]；骨架只写一次
/// 策略。这里分别钉住三条语义——平台返回空 / 业务拒绝 / 传输失败——以及
/// 重试预算与分页推断的归属。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_search_runner.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/kg_search.dart';
import 'package:molia/sources/source_track.dart';
import 'support/mock_dio.dart';

void main() {
  late BuiltinTransport original;

  setUp(() => original = BuiltinSearch.transport);
  tearDown(() => BuiltinSearch.transport = original);

  BuiltinSearchCall callOf({
    required bool Function(dynamic response) isInvalid,
    List<SourceTrack>? Function(dynamic response)? parseItems,
    int? Function(dynamic response)? totalOf,
    bool Function(dynamic response)? retryIf,
    int retries = 1,
  }) {
    return BuiltinSearchCall(
      platform: 'test',
      method: BuiltinSearchMethod.get,
      url: 'https://example.com/search',
      retries: retries,
      retryIf: retryIf ?? (response) => false,
      isInvalid: isInvalid,
      parseItems: parseItems ?? (response) => const [],
      totalOf: totalOf,
    );
  }

  test('平台返回空：正常结果（无 failure、无 total、无下一页）', () async {
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async => textResponse('{}', statusCode: 200)),
    );
    final result = await runBuiltinSearch(
      callOf(isInvalid: (_) => false, parseItems: (_) => null),
      page: 1,
      limit: 30,
    );
    expect(result.tracks, isEmpty);
    expect(result.failure, isNull);
    expect(result.total, isNull);
    expect(result.hasMore, isFalse);
  });

  test('响应非法（平台业务拒绝）：失败结果，不抛异常', () async {
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async => textResponse('{"code":7}', statusCode: 200)),
    );
    final result = await runBuiltinSearch(
      callOf(isInvalid: (response) => response['code'] != 0),
      page: 1,
      limit: 30,
    );
    expect(result.tracks, isEmpty);
    final failure = result.failure;
    expect(failure, isNotNull);
    expect(failure!.retryable, isTrue);
    expect(failure.message, contains('test'));
  });

  test('传输失败（重试耗尽）：归一为失败结果（network/retryable）', () async {
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async => throw const SocketExceptionStub()),
    );
    final result = await runBuiltinSearch(
      callOf(isInvalid: (_) => false),
      page: 1,
      limit: 30,
    );
    expect(result.failure, isNotNull);
    expect(result.failure!.retryable, isTrue);
  });

  test('重试预算由 call 持有：retryIf 命中即按预算重试', () async {
    var calls = 0;
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async {
        calls++;
        return textResponse(jsonEncode({'ready': calls >= 3}), statusCode: 200);
      }),
    );
    final result = await runBuiltinSearch(
      callOf(
        retries: 3,
        retryIf: (response) => response['ready'] != true,
        isInvalid: (response) => response['ready'] != true,
        parseItems: (_) => const [],
      ),
      page: 1,
      limit: 30,
    );
    expect(calls, 3);
    expect(result.failure, isNull, reason: '最后一次尝试已成功');
  });

  test('分页推断：total 与 limit 决定 hasMore', () async {
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async => textResponse('{}', statusCode: 200)),
    );
    final result = await runBuiltinSearch(
      callOf(isInvalid: (_) => false, totalOf: (_) => 100),
      page: 1,
      limit: 30,
    );
    expect(result.total, 100);
    expect(result.hasMore, isTrue);
  });

  test('真平台端到端：酷狗搜索走 runner（含列表路径与结构缺失两条分支）', () async {
    var body = jsonEncode({
      'error_code': 0,
      'data': {
        'total': 2,
        'lists': [
          {
            'Audioid': 1,
            'FileHash': 'hash1',
            'OriSongName': 'Hello',
            'Singers': [
              {'name': 'Tester'}
            ],
            'Duration': 30,
            'FileSize': 1024,
          },
        ],
      },
    });
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async => textResponse(body, statusCode: 200)),
    );

    final result = await KgSearch.searchWithMeta('hello', page: 1, limit: 30);
    expect(result.failure, isNull);
    expect(result.tracks, hasLength(1));
    expect(result.tracks.single.title, 'Hello');
    expect(result.total, 2);

    // 结构缺失（无 lists）：按「平台返回空」处理，不带 total。
    body = jsonEncode({
      'error_code': 0,
      'data': {'total': 2},
    });
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async => textResponse(body, statusCode: 200)),
    );
    final empty = await KgSearch.searchWithMeta('hello', page: 1, limit: 30);
    expect(empty.tracks, isEmpty);
    expect(empty.failure, isNull);
    expect(empty.total, isNull);

    // 业务码异常：失败结果（重试预算耗尽后不抛异常）。
    body = jsonEncode({'error_code': 20001});
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async => textResponse(body, statusCode: 200)),
    );
    final failed = await KgSearch.searchWithMeta('hello', page: 1, limit: 30);
    expect(failed.failure, isNotNull);
    expect(failed.failure!.kind, FailureKind.unknown);
  });
}

/// 制造一次传输层异常（只伪造 toString，不引入 dart:io）。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketException: stub';
}
