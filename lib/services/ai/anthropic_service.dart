import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_common.dart';
import 'ai_service.dart';

/// Anthropic Claude via the Messages API (raw HTTP; Dart has no official SDK).
class AnthropicService extends AiService {
  AnthropicService(super.config, {super.client});

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'x-api-key': config.apiKey.trim(),
    'anthropic-version': '2023-06-01',
  };

  @override
  List<http.Request Function()> requestVariants(RedrawRequest request) {
    List<Map<String, dynamic>> messages(String text) => [
      {
        'role': 'user',
        'content': [
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': request.image.mediaType,
              'data': request.image.base64Data,
            },
          },
          {'type': 'text', 'text': text},
        ],
      },
    ];

    http.Request build(
      Map<String, dynamic> body, {
      List<String> betas = const [],
    }) {
      final req =
          http.Request(
              'POST',
              Uri.parse('${config.normalizedBaseUrl}/messages'),
            )
            ..headers.addAll(_headers)
            ..body = jsonEncode(body);
      if (betas.isNotEmpty) req.headers['anthropic-beta'] = betas.join(',');
      return req;
    }

    final model = config.model.trim();
    return [
      // Current models: adaptive thinking, strict JSON output and server-side
      // fallback (a declined request is retried on the recommended model).
      () => build(
        {
          'model': model,
          'max_tokens': 64000,
          'stream': true,
          'thinking': {'type': 'adaptive'},
          'output_config': {
            'effort': 'high',
            'format': {'type': 'json_schema', 'schema': redrawOutputSchema},
          },
          'fallbacks': 'default',
          'system': redrawSystemPrompt,
          'messages': messages(request.userText),
        },
        betas: ['server-side-fallback-2026-07-01'],
      ),
      // Models without adaptive thinking / effort / fallbacks.
      () => build({
        'model': model,
        'max_tokens': 32000,
        'stream': true,
        'output_config': {
          'format': {'type': 'json_schema', 'schema': redrawOutputSchema},
        },
        'system': redrawSystemPrompt,
        'messages': messages(request.userText),
      }),
      // Oldest models: plain prompt asking for JSON.
      () => build({
        'model': model,
        'max_tokens': 8192,
        'stream': true,
        'system': redrawSystemPrompt,
        'messages': messages(request.userText),
      }),
    ];
  }

  @override
  Future<String> streamText(
    http.Request request,
    void Function(int chars)? onProgress,
  ) async {
    final text = StringBuffer();
    String? stopReason;
    await for (final event in sendSse(
      client,
      request,
      providerName: providerName,
    )) {
      switch (event['type']) {
        case 'content_block_delta':
          final delta = event['delta'] as Map<String, dynamic>;
          if (delta['type'] == 'text_delta') {
            text.write(delta['text'] as String);
            onProgress?.call(text.length);
          }
        case 'message_delta':
          final delta = event['delta'] as Map<String, dynamic>?;
          stopReason = delta?['stop_reason'] as String? ?? stopReason;
        case 'error':
          final err = event['error'] as Map<String, dynamic>?;
          throw AiException(
            'Claude báo lỗi: ${err?['message'] ?? 'không rõ nguyên nhân'}',
          );
      }
    }
    switch (stopReason) {
      case 'refusal':
        throw AiException(
          'Claude đã từ chối xử lý ảnh này. Hãy thử một ảnh khác.',
        );
      case 'max_tokens':
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
      Uri.parse('${config.normalizedBaseUrl}/models?limit=100'),
      _headers,
      providerName: providerName,
    );
    return [
      for (final m in (json['data'] as List? ?? const []))
        if (m is Map && m['id'] != null) m['id'].toString(),
    ];
  }
}
