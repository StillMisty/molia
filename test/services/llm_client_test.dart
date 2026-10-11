import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/services/ai/llm_client.dart';

/// LLM 客户端测试：地址归一、请求形状、错误归一化、超时、key 不泄露。
void main() {
  LlmConfig config({String baseUrl = 'https://api.example.com/v1'}) =>
      LlmConfig(baseUrl: baseUrl, apiKey: 'sk-test-123456', model: 'test-model');

  String okBody(String content) =>
      jsonEncode({'choices': [{'message': {'content': content}}]});

  /// 统一走 UTF-8 字节（`http.Response(String)` 默认 latin1，中文会抛）。
  http.Response ok(String content, [int status = 200]) =>
      http.Response.bytes(utf8.encode(okBody(content)), status);

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
    late http.Request captured;
    final llm = LlmClient(
      client: MockClient((request) async {
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
    expect(captured.url.toString(), 'https://api.example.com/v1/chat/completions');
    expect(captured.headers['Authorization'], 'Bearer sk-test-123456');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['model'], 'test-model');
    expect(body['stream'], isFalse);
    final messages = body['messages'] as List;
    expect(messages, hasLength(2));
    expect(messages.first['role'], 'system');
  });

  test('401 → unauthorized，且 message 不包含 key', () async {
    final llm = LlmClient(
      client: MockClient((_) async => http.Response('nope', 401)),
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
      client: MockClient((_) async => http.Response('slow down', 429)),
    );

    final failure = await failureOf(
      () => llm.complete(config: config(), systemPrompt: 's', userPrompt: 'u'),
    );

    expect(failure.kind, FailureKind.rateLimited);
    expect(failure.retryable, isTrue);
  });

  test('503 → unknown（可重试）；400 → unknown（不重试）', () async {
    final serverError = LlmClient(
      client: MockClient((_) async => http.Response('boom', 503)),
    );
    final clientError = LlmClient(
      client: MockClient((_) async => http.Response('bad', 400)),
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
      client: MockClient((_) async => http.Response('not json', 200)),
    );
    final empty = LlmClient(
      client: MockClient((_) async => ok('  ')),
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
      client: MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 50),
    );

    final failure = await failureOf(
      () => llm.complete(config: config(), systemPrompt: 's', userPrompt: 'u'),
    );

    expect(failure.kind, FailureKind.timeout);
    expect(failure.retryable, isTrue);
  });

  test('testConnection 走同一请求路径', () async {
    var called = false;
    final llm = LlmClient(
      client: MockClient((_) async {
        called = true;
        return ok('可用');
      }),
    );

    await llm.testConnection(config());

    expect(called, isTrue);
  });
}
