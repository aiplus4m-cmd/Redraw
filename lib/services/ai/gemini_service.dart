import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_common.dart';
import 'ai_service.dart';

/// Google Gemini via the Generative Language REST API.
class GeminiService extends AiService {
  GeminiService(super.config, {super.client});

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'x-goog-api-key': config.apiKey.trim(),
  };

  String get _model {
    final m = config.model.trim();
    return m.startsWith('models/') ? m.substring(7) : m;
  }

  @override
  List<http.Request Function()> requestVariants(RedrawRequest request) {
    http.Request build(Map<String, dynamic> generationConfig) {
      final uri = Uri.parse(
        '${config.normalizedBaseUrl}/models/$_model:streamGenerateContent?alt=sse',
      );
      return http.Request('POST', uri)
        ..headers.addAll(_headers)
        ..body = jsonEncode({
          'systemInstruction': {
            'parts': [
              {'text': redrawSystemPrompt},
            ],
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {
                  'inline_data': {
                    'mime_type': request.image.mediaType,
                    'data': request.image.base64Data,
                  },
                },
                {'text': request.userText},
              ],
            },
          ],
          'generationConfig': generationConfig,
        });
    }

    return [
      () => build({
        'responseMimeType': 'application/json',
        'responseJsonSchema': redrawOutputSchema,
        'maxOutputTokens': 65536,
      }),
      () => build({
        'responseMimeType': 'application/json',
        'maxOutputTokens': 65536,
      }),
      () => build({'responseMimeType': 'application/json'}),
    ];
  }

  @override
  Future<String> streamText(
    http.Request request,
    void Function(int chars)? onProgress,
  ) async {
    final text = StringBuffer();
    String? finishReason;
    await for (final event in sendSse(
      client,
      request,
      providerName: providerName,
    )) {
      final error = event['error'];
      if (error is Map) {
        throw AiException('Gemini báo lỗi: ${error['message'] ?? error}');
      }
      final blockReason = (event['promptFeedback'] as Map?)?['blockReason'];
      if (blockReason != null) {
        throw AiException(
          'Gemini đã chặn yêu cầu này ($blockReason). Hãy thử ảnh khác.',
        );
      }
      final candidates = event['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) continue;
      final candidate = candidates.first as Map<String, dynamic>;
      finishReason = candidate['finishReason'] as String? ?? finishReason;
      final parts =
          (candidate['content'] as Map?)?['parts'] as List? ?? const [];
      for (final part in parts) {
        if (part is Map && part['thought'] != true && part['text'] is String) {
          text.write(part['text'] as String);
          onProgress?.call(text.length);
        }
      }
    }
    switch (finishReason) {
      case null || 'STOP' || 'FINISH_REASON_UNSPECIFIED':
        break;
      case 'MAX_TOKENS':
        throw AiException(
          'Nội dung quá dài nên kết quả bị cắt. Hãy cắt ảnh thành các phần nhỏ hơn.',
        );
      default:
        throw AiException(
          'Gemini dừng giữa chừng ($finishReason). Hãy thử lại hoặc dùng ảnh khác.',
        );
    }
    return text.toString();
  }

  @override
  Future<List<String>> listModels() async {
    final json = await getJson(
      client,
      Uri.parse('${config.normalizedBaseUrl}/models?pageSize=1000'),
      _headers,
      providerName: providerName,
    );
    return [
      for (final m in (json['models'] as List? ?? const []))
        if (m is Map &&
            ((m['supportedGenerationMethods'] as List?) ?? const []).contains(
              'generateContent',
            ))
          m['name'].toString().replaceFirst('models/', ''),
    ];
  }
}
