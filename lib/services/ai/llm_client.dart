/// LLM 客户端：OpenAI-compatible Chat Completions（用户自备 Key）。
///
/// 设计要点：
/// - `Dio` 可注入（测试用 MockDioAdapter，与 builtin transport 同模式）；
/// - 错误在边界统一为 [SourceFailure]（401/403 → unauthorized、
///   429 → rateLimited、超时 → timeout、连接失败 → network、
///   响应不可解析 → unknown），UI 只消费 kind/l10nKey/retryable；
/// - 响应形状容错：BOM、`content` 为 parts 数组、旧式 `text` 字段等兼容实现
///   都能读出正文（形状差异不该被误判成「服务不可用」）；
/// - apiKey 只进请求头，绝不出现在异常 message/日志里。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../data/http/app_dio.dart';
import '../../domain/models/ai_dj.dart';
import '../../domain/models/failure.dart';

class LlmClient {
  LlmClient({
    Dio? dio,
    this._timeout = const Duration(seconds: 30),
  })  : _dio = dio ?? createAppDio();

  final Dio _dio;
  final Duration _timeout;
  final Logger _logger = Logger('molia.llm_client');

  /// 已确认不支持 `response_format` 的 `baseUrl|model`。
  ///
  /// 不支持的服务商每次都会先吃一个 400；记住后直接走纯提示词约束，避免
  /// 每批把同一份 prompt 发两遍。只有「去掉参数后成功」才记录，避免把其它
  /// 400（模型名/参数错误）误判成不支持 JSON 模式。
  String? _jsonModeUnsupportedKey;

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
  /// 本身已要求纯 JSON，解析侧也容错），并按 `baseUrl|model` 记住该服务商，
  /// 后续不再重复发送带参数的探测请求。
  Future<String> complete({
    required LlmConfig config,
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 4096,
    bool jsonMode = false,
  }) async {
    final decoded = await _chatCompletions(
      config: config,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      temperature: temperature,
      maxTokens: maxTokens,
      jsonMode: jsonMode,
    );
    final content = extractAssistantContent(decoded);
    if (content == null || content.trim().isEmpty) {
      // 推理模型会把输出预算花在思维链上、正文留空：生成侧必须拿到正文，
      // 记下 finish_reason 以便区分「模型没答」与「解析坏了」。
      _logger.warning(
        'AI 响应无正文（finish_reason: ${finishReasonOf(decoded) ?? '未知'}）',
      );
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
  ///
  /// 判据刻意放宽为「2xx + 对话结果（`choices` 非空）」：正文是否为空不代表
  /// 连接不可用（推理模型可能只回思维链、兼容实现可能返回特殊结构），连接
  /// 测试只关心地址、凭证、模型名能否走通。
  Future<void> testConnection(
    LlmConfig config, {
    String systemPrompt = '你是连接测试助手。',
    String userPrompt = '只回复两个字：可用',
  }) async {
    final decoded = await _chatCompletions(
      config: config,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      temperature: 0,
      maxTokens: 64,
    );
    if (!hasChoices(decoded)) {
      _logger.warning(
        'AI 连接测试：响应不含对话结果（HTTP 200）：${_snippet(jsonEncode(decoded))}',
      );
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: 'AI 服务未返回对话结果',
        l10nKey: 'aiDjBadResponse',
        retryable: true,
      );
    }
  }

  /// 发一轮 Chat Completions，返回解码后的 JSON 对象。
  Future<Map<String, dynamic>> _chatCompletions({
    required LlmConfig config,
    required String systemPrompt,
    required String userPrompt,
    required double temperature,
    required int maxTokens,
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

    final configKey = '${config.baseUrl.trim()}|${config.model.trim()}';
    final tryJsonMode = jsonMode && _jsonModeUnsupportedKey != configKey;
    Response<dynamic> response;
    try {
      response = await _dio
          .postUri(uri,
              data: jsonEncode(requestBody(json: tryJsonMode)),
              options: Options(headers: headers))
          .timeout(_timeout);
      if (tryJsonMode && response.httpStatus == 400) {
        // 服务商不支持 response_format：退回一次纯提示词约束；成功才记住，
        // 下次同配置不再先发带参数的请求。
        final retry = await _dio
            .postUri(uri,
                data: jsonEncode(requestBody(json: false)),
                options: Options(headers: headers))
            .timeout(_timeout);
        if (retry.httpStatus < 400) {
          _jsonModeUnsupportedKey = configKey;
        }
        response = retry;
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

    final body = _stripBom(bodyText(response));
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('响应不是 JSON 对象');
    } catch (e) {
      // 记录一段响应片段（不含任何凭证），便于定位网关/兼容实现的形状差异。
      _logger.warning(
        'AI 响应解析失败（HTTP ${response.httpStatus}）：${_snippet(body)}',
      );
      throw SourceFailure(
        kind: FailureKind.unknown,
        message: 'AI 服务响应不可解析',
        l10nKey: 'aiDjBadResponse',
        cause: e,
      );
    }
  }

  /// 从对话响应提取正文：兼容 `choices[0].message.content` 的字符串 /
  /// content parts 数组 / 单对象，以及旧式 `choices[0].text`。
  static String? extractAssistantContent(Map<String, dynamic> decoded) {
    final choice = _firstChoice(decoded);
    if (choice == null) return null;
    final message = choice['message'];
    if (message is Map) {
      final text = _contentText(message['content']);
      if (text != null && text.isNotEmpty) return text;
    }
    final legacy = choice['text'];
    if (legacy is String && legacy.isNotEmpty) return legacy;
    return null;
  }

  /// 响应是否含对话结果（连接测试判据）。
  static bool hasChoices(Map<String, dynamic> decoded) =>
      _firstChoice(decoded) != null;

  /// 首个 choice 的 finish_reason（诊断用；未知返回 null）。
  static String? finishReasonOf(Map<String, dynamic> decoded) {
    final reason = _firstChoice(decoded)?['finish_reason'];
    return reason is String ? reason : null;
  }

  static Map? _firstChoice(Map<String, dynamic> decoded) {
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    return first is Map ? first : null;
  }

  /// content 归一：字符串原样；parts 数组 / 单对象取其中的 `text` 拼接。
  static String? _contentText(dynamic content) {
    if (content is String) return content;
    if (content is Map) {
      final text = content['text'];
      return text is String ? text : null;
    }
    if (content is List) {
      final parts = <String>[];
      for (final part in content) {
        if (part is Map) {
          final text = part['text'];
          if (text is String && text.isNotEmpty) parts.add(text);
        } else if (part is String && part.isNotEmpty) {
          parts.add(part);
        }
      }
      return parts.isEmpty ? null : parts.join();
    }
    return null;
  }

  /// 去掉 UTF-8 BOM 与首尾空白：部分网关会在 JSON 前带 BOM，jsonDecode 会拒。
  static String _stripBom(String text) {
    var value = text.trim();
    while (value.startsWith('\uFEFF')) {
      value = value.substring(1).trimLeft();
    }
    return value;
  }

  /// 日志用响应片段：压成单行并截断（只用于定位响应形状，不含凭证）。
  static String _snippet(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= 200 ? single : '${single.substring(0, 200)}…';
  }

  void dispose() => _dio.close();
}
