import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_common.dart';
import 'ai_provider.dart';
import 'ai_service.dart';

/// OpenAI, and any OpenAI-compatible server (OpenRouter, Groq, DeepSeek,
/// Ollama, LM Studio, vLLM, ...), via the Chat Completions API.
class OpenAiService extends AiService {
  OpenAiService(super.config, {super.client});

  bool get _isOpenAi => config.provider == AiProvider.openai;

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    if (config.apiKey.trim().isNotEmpty)
      'authorization': 'Bearer ${config.apiKey.trim()}',
  };

  @override
  List<http.Request Function()> requestVariants(RedrawRequest request) {
    final imagePart = {
      'type': 'image_url',
      'image_url': {
        'url': request.image.dataUrl,
        if (_isOpenAi) 'detail': 'high',
      },
    };

    List<Map<String, dynamic>> messages({required bool systemRole}) =>
        systemRole
        ? [
            {'role': 'system', 'content': redrawSystemPrompt},
            {
              'role': 'user',
              'content': [
                imagePart,
                {'type': 'text', 'text': request.userText},
              ],
            },
          ]
        : [
            // Some models/servers reject the system role: inline the prompt.
            {
              'role': 'user',
              'content': [
                imagePart,
                {
                  'type': 'text',
                  'text': '$redrawSystemPrompt\n\n${request.userText}',
                },
              ],
            },
          ];

    const jsonSchemaFormat = {
      'type': 'json_schema',
      'json_schema': {
        'name': 'redraw_result',
        'strict': true,
        'schema': redrawOutputSchema,
      },
    };
    const jsonObjectFormat = {'type': 'json_object'};

    http.Request build(Map<String, dynamic> extra, {bool systemRole = true}) =>
        http.Request(
            'POST',
            Uri.parse('${config.normalizedBaseUrl}/chat/completions'),
          )
          ..headers.addAll(_headers)
          ..body = jsonEncode({
            'model': config.model.trim(),
            'stream': true,
            'messages': messages(systemRole: systemRole),
            ...extra,
          });

    return [
      if (_isOpenAi)
        () => build({
          'response_format': jsonSchemaFormat,
          'max_completion_tokens': 32000,
        }),
      () => build({'response_format': jsonSchemaFormat}),
      () => build({'response_format': jsonObjectFormat}),
      () => build({}),
      () => build({}, systemRole: false),
    ];
  }

  @override
  Future<String> streamText(
    http.Request request,
    void Function(int chars)? onProgress,
  ) async {
    final text = StringBuffer();
    final refusal = StringBuffer();
    String? finishReason;
    await for (final event in sendSse(
      client,
      request,
      providerName: providerName,
    )) {
      final error = event['error'];
      if (error != null) {
        throw AiException(
          '$providerName báo lỗi: ${error is Map ? error['message'] ?? error : error}',
        );
      }
      final choices = event['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;
      finishReason = choice['finish_reason'] as String? ?? finishReason;
      final delta = choice['delta'] as Map<String, dynamic>?;
      if (delta == null) continue;
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        text.write(content);
        onProgress?.call(text.length);
      }
      if (delta['refusal'] is String) refusal.write(delta['refusal'] as String);
    }
    if (refusal.isNotEmpty || finishReason == 'content_filter') {
      throw AiException(
        '$providerName đã từ chối xử lý ảnh này. '
                '${refusal.toString().trim()}'
            .trim(),
      );
    }
    if (finishReason == 'length') {
      throw AiException(
        'Nội dung quá dài nên kết quả bị cắt. Hãy cắt ảnh thành các phần nhỏ hơn.',
      );
    }
    return text.toString();
  }

  @override
  Future<List<String>> listModels() async {
    final json = await getJson(
      client,
      Uri.parse('${config.normalizedBaseUrl}/models'),
      _headers,
      providerName: providerName,
    );
    final ids = [
      for (final m in (json['data'] as List? ?? const []))
        if (m is Map && m['id'] != null) m['id'].toString(),
    ]..sort();
    return ids;
  }
}
