import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/services/ai/llm_client.dart';
import '../support/mock_dio.dart';

/// LLM 客户端测试：地址归一、请求形状、错误归一化、超时、key 不泄露。
void main() {
  LlmConfig config({String baseUrl = 'https://api.example.com/v1'}) =>
      LlmConfig(
          baseUrl: baseUrl, apiKey: 'sk-test-123456', model: 'test-model');

  String okBody(String content) => jsonEncode({
        'choices': [
          {
            'message': {'content': content}
          }
        ]
      });

  /// 统一走 UTF-8 字节（响应体自行解码，不受响应头 charset 影响）。
  ResponseBody ok(String content, [int status = 200]) =>
      bytesResponse(utf8.encode(okBody(content)), statusCode: status);

  Future<SourceFailure> failureOf(Future<void> Function() action) async {
    try {
      await action();
    } on SourceFailure catch (e) {
      return e;
    }
    fail('预期抛出 SourceFailure');
  }

  group('chatCompletionsUri 归一', () {
    test('裸域名补 /v1/chat/completions', () {
      expect(
        LlmClient.chatCompletionsUri('https://api.deepseek.com').toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
    });

    test('尾部斜杠与 /v1 归一', () {
      expect(
        LlmClient.chatCompletionsUri('https://api.openai.com/v1/').toString(),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('完整地址原样保留', () {
      expect(
        LlmClient.chatCompletionsUri('https://x.example/v1/chat/completions')
            .toString(),
        'https://x.example/v1/chat/completions',
      );
    });
  });

  test('成功：携带 Bearer 头与消息体，返回内容', () async {
    late RequestOptions captured;
    final llm = LlmClient(
      dio: mockDio((request) async {
        captured = request;
        return ok('推荐结果');
      }),
    );

    final content = await llm.complete(
      config: config(),
      systemPrompt: 'sys',
      userPrompt: 'user',
    );

    expect(content, '推荐结果');
    expect(
        captured.uri.toString(), 'https://api.example.com/v1/chat/completions');
    expect(captured.headers['Authorization'], 'Bearer sk-test-123456');
    final body = jsonDecode(requestBodyText(captured)) as Map<String, dynamic>;
    expect(body['model'], 'test-model');
    expect(body['stream'], isFalse);
    final messages = body['messages'] as List;
    expect(messages, hasLength(2));
    expect(messages.first['role'], 'system');
  });

  test('response_format 400 后记住不支持，下次不再先发带参请求', () async {
    final bodies = <Map<String, dynamic>>[];
    final llm = LlmClient(
      dio: mockDio((request) async {
        final body =
            jsonDecode(requestBodyText(request)) as Map<String, dynamic>;
        bodies.add(body);
        if (body.containsKey('response_format')) {
          return textResponse('unsupported', statusCode: 400);
        }
        return ok('{"songs":[]}');
      }),
    );

    await llm.complete(
      config: config(),
      systemPrompt: 's',
      userPrompt: 'u',
      jsonMode: true,
    );
    await llm.complete(
      config: config(),
      systemPrompt: 's',
      userPrompt: 'u',
      jsonMode: true,
    );

    expect(bodies, hasLength(3));
    expect(bodies[0].containsKey('response_format'), isTrue);
    expect(bodies[1].containsKey('response_format'), isFalse);
    expect(bodies[2].containsKey('response_format'), isFalse);
  });

  test('400 且退回请求也失败时不记住不支持（避免误判其它 400）', () async {
    final bodies = <Map<String, dynamic>>[];
    final llm = LlmClient(
      dio: mockDio((request) async {
        bodies.add(
          jsonDecode(requestBodyText(request)) as Map<String, dynamic>,
        );
        return textResponse('bad', statusCode: 400);
      }),
    );

    for (var i = 0; i < 2; i++) {
      await expectLater(
        llm.complete(
          config: config(),
          systemPrompt: 's',
          userPrompt: 'u',
          jsonMode: true,
        ),
        throwsA(isA<SourceFailure>()),
      );
    }

    expect(bodies, hasLength(4));
    expect(
      bodies.where((body) => body.containsKey('response_format')),
      hasLength(2),
      reason: '每次都先尝试 JSON 模式；失败不缓存',
    );
  });

  test('401 → unauthorized，且 message 不包含 key', () async {
    final llm = LlmClient(
      dio: mockDio((_) async => textResponse('nope', statusCode: 401)),
    );

    final failure = await failureOf(
      () => llm.complete(config: config(), systemPrompt: 's', userPrompt: 'u'),
    );

    expect(failure.kind, FailureKind.unauthorized);
    expect(failure.retryable, isFalse);
    expect(failure.message.contains('sk-test'), isFalse);
  });

  test('429 → rateLimited（可重试）', () async {
    final llm = LlmClient(
      dio: mockDio((_) async => textResponse('slow down', statusCode: 429)),
    );

    final failure = await failureOf(
      () => llm.complete(config: config(), systemPrompt: 's', userPrompt: 'u'),
    );

    expect(failure.kind, FailureKind.rateLimited);
    expect(failure.retryable, isTrue);
  });

  test('503 → unknown（可重试）；400 → unknown（不重试）', () async {
    final serverError = LlmClient(
      dio: mockDio((_) async => textResponse('boom', statusCode: 503)),
    );
    final clientError = LlmClient(
      dio: mockDio((_) async => textResponse('bad', statusCode: 400)),
    );

    expect(
      (await failureOf(() => serverError.complete(
                config: config(),
                systemPrompt: 's',
                userPrompt: 'u',
              )))
          .retryable,
      isTrue,
    );
    expect(
      (await failureOf(() => clientError.complete(
                config: config(),
                systemPrompt: 's',
                userPrompt: 'u',
              )))
          .retryable,
      isFalse,
    );
  });

  test('响应不是 OpenAI 形状 / 内容为空 → unknown', () async {
    final malformed = LlmClient(
      dio: mockDio((_) async => textResponse('not json', statusCode: 200)),
    );
    final empty = LlmClient(
      dio: mockDio((_) async => ok('  ')),
    );

    expect(
      (await failureOf(() => malformed.complete(
                config: config(),
                systemPrompt: 's',
                userPrompt: 'u',
              )))
          .kind,
      FailureKind.unknown,
    );
    expect(
      (await failureOf(() => empty.complete(
                config: config(),
                systemPrompt: 's',
                userPrompt: 'u',
              )))
          .kind,
      FailureKind.unknown,
    );
  });

  test('超时 → timeout（可重试）', () async {
    final llm = LlmClient(
      dio: mockDio((_) => Completer<ResponseBody>().future),
      timeout: const Duration(milliseconds: 50),
    );

    final failure = await failureOf(
      () => llm.complete(config: config(), systemPrompt: 's', userPrompt: 'u'),
    );

    expect(failure.kind, FailureKind.timeout);
    expect(failure.retryable, isTrue);
  });

  test('testConnection 走同一请求路径：2xx + choices 即通过（正文为空也算通）', () async {
    late RequestOptions captured;
    final llm = LlmClient(
      dio: mockDio((request) async {
        captured = request;
        return ok('可用');
      }),
    );

    await expectLater(llm.testConnection(config()), completes);
    expect(
        captured.uri.toString(), 'https://api.example.com/v1/chat/completions');
    expect(captured.headers['Authorization'], 'Bearer sk-test-123456');

    // 推理模型只回思维链、正文为空：2xx 且带 choices 即视为连通。
    final reasoningOnly = LlmClient(
      dio: mockDio(
        (_) async => bytesResponse(
          utf8.encode(jsonEncode({
            'choices': [
              {
                'message': {
                  'content': '',
                  'reasoning_content': '推理模型只回了思维链',
                },
              },
            ],
          })),
        ),
      ),
    );
    await expectLater(reasoningOnly.testConnection(config()), completes);
  });

  group('响应形状容错（换服务商后「无法解析」误报的回归）', () {
    ResponseBody raw(String body, [int status = 200]) =>
        bytesResponse(utf8.encode(body), statusCode: status);

    test('响应体带 BOM：剥掉后正常解析', () async {
      final llm = LlmClient(
        dio: mockDio((_) async => raw('\uFEFF${okBody('带 BOM 的正文')}')),
      );

      final content = await llm.complete(
        config: config(),
        systemPrompt: 's',
        userPrompt: 'u',
      );

      expect(content, '带 BOM 的正文');
    });

    test('content 为 parts 数组：拼接 text 片段', () async {
      final llm = LlmClient(
        dio: mockDio(
          (_) async => raw(jsonEncode({
            'choices': [
              {
                'message': {
                  'content': [
                    {'type': 'text', 'text': '分'},
                    {'type': 'text', 'text': '片'},
                  ],
                },
              },
            ],
          })),
        ),
      );

      final content = await llm.complete(
        config: config(),
        systemPrompt: 's',
        userPrompt: 'u',
      );

      expect(content, '分片');
    });

    test('旧式 choices[0].text：兼容读取', () async {
      final llm = LlmClient(
        dio: mockDio(
          (_) async => raw(jsonEncode({
            'choices': [
              {'text': '旧式正文'},
            ],
          })),
        ),
      );

      final content = await llm.complete(
        config: config(),
        systemPrompt: 's',
        userPrompt: 'u',
      );

      expect(content, '旧式正文');
    });

    test('testConnection：响应不含对话结果 → unknown', () async {
      final llm = LlmClient(
        dio: mockDio(
          (_) async => raw(jsonEncode({
            'error': {'message': 'nope'}
          })),
        ),
      );

      final failure = await failureOf(() => llm.testConnection(config()));

      expect(failure.kind, FailureKind.unknown);
      expect(failure.l10nKey, 'aiDjBadResponse');
    });
  });
}
