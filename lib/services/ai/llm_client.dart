/// LLM 客户端：OpenAI-compatible Chat Completions（用户自备 Key）。
///
/// 设计要点：
/// - `Dio` 可注入（测试用 MockDioAdapter，与 builtin transport 同模式）；
/// - 错误在边界统一为 [SourceFailure]（401/403 → unauthorized、
///   429 → rateLimited、超时 → timeout、连接失败 → network、
///   响应不可解析 → unknown），UI 只消费 kind/l10nKey/retryable；
/// - apiKey 只进请求头，绝不出现在异常 message/日志里。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/http/app_dio.dart';
import '../../domain/models/ai_dj.dart';
import '../../domain/models/failure.dart';

class LlmClient {
  LlmClient({
    Dio? dio,
    Duration timeout = const Duration(seconds: 30),
  })  : _dio = dio ?? createAppDio(),
        _timeout = timeout;

  final Dio _dio;
  final Duration _timeout;

  /// 请求地址归一：
  /// - 已以 `/chat/completions` 结尾 → 原样；
  /// - 已以 `/v1` 结尾 → 追加 `/chat/completions`；
  /// - 其余 → 追加 `/v1/chat/completions`（兼容 DeepSeek 等的裸域名）。
  static Uri chatCompletionsUri(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) {
      return Uri.parse(base);
    }
    if (base.endsWith('/v1') || base.endsWith('/v1beta')) {
      return Uri.parse('$base/chat/completions');
    }
    return Uri.parse('$base/v1/chat/completions');
  }

  /// 单轮补全：返回 assistant 的文本内容。
  ///
  /// [jsonMode] 为 true 时请求 `response_format: {"type":"json_object"}`；
  /// 若服务商不认该参数（HTTP 400），自动退回一次不带参数的请求（提示词
  /// 本身已要求纯 JSON，解析侧也容错）。
  Future<String> complete({
    required LlmConfig config,
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 4096,
    bool jsonMode = false,
  }) async {
    final uri = chatCompletionsUri(config.baseUrl);
    Map<String, Object?> requestBody({required bool json}) => {
          'model': config.model.trim(),
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userPrompt},
          ],
          'temperature': temperature,
          'max_tokens': maxTokens,
          'stream': false,
          if (json) 'response_format': const {'type': 'json_object'},
        };
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${config.apiKey.trim()}',
    };

    Response<dynamic> response;
    try {
      response = await _dio
          .postUri(uri,
              data: jsonEncode(requestBody(json: jsonMode)),
              options: Options(headers: headers))
          .timeout(_timeout);
      if (jsonMode && response.httpStatus == 400) {
        // 服务商不支持 response_format：退回一次纯提示词约束。
        response = await _dio
            .postUri(uri,
                data: jsonEncode(requestBody(json: false)),
                options: Options(headers: headers))
            .timeout(_timeout);
      }
    } on TimeoutException {
      throw const SourceFailure(
        kind: FailureKind.timeout,
        message: 'AI 服务响应超时',
        l10nKey: 'aiDjRequestFailed',
        retryable: true,
      );
    } catch (e) {
      throw SourceFailure(
        kind: FailureKind.network,
        message: 'AI 服务连接失败: ${e.runtimeType}',
        l10nKey: 'aiDjRequestFailed',
        cause: e,
        retryable: true,
      );
    }

    if (response.httpStatus == 401 || response.httpStatus == 403) {
      throw const SourceFailure(
        kind: FailureKind.unauthorized,
        message: 'API Key 无效或没有权限',
        l10nKey: 'aiDjUnauthorized',
        retryable: false,
      );
    }
    if (response.httpStatus == 429) {
      throw const SourceFailure(
        kind: FailureKind.rateLimited,
        message: 'AI 服务限流',
        l10nKey: 'aiDjRateLimited',
        retryable: true,
      );
    }
    if (response.httpStatus >= 400) {
      throw SourceFailure(
        kind: FailureKind.unknown,
        message: 'AI 服务返回 HTTP ${response.httpStatus}',
        l10nKey: 'aiDjRequestFailed',
        retryable: response.httpStatus >= 500,
      );
    }

    final String content;
    try {
      final decoded = jsonDecode(bodyText(response));
      content = ((decoded as Map<String, dynamic>)['choices'] as List?)
              ?.firstOrNull?['message']?['content'] as String? ??
          '';
    } catch (e) {
      throw SourceFailure(
        kind: FailureKind.unknown,
        message: 'AI 服务响应不可解析',
        l10nKey: 'aiDjBadResponse',
        cause: e,
      );
    }
    if (content.trim().isEmpty) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: 'AI 服务返回空内容',
        l10nKey: 'aiDjBadResponse',
        retryable: true,
      );
    }
    return content;
  }

  /// 连接测试：发一条极小请求验证地址/Key/模型可用。
  Future<void> testConnection(LlmConfig config) => complete(
        config: config,
        systemPrompt: '你是连接测试助手。',
        userPrompt: '只回复两个字：可用',
        temperature: 0,
        maxTokens: 16,
      );

  void dispose() => _dio.close();
}
