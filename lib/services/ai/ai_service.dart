import 'package:http/http.dart' as http;

import '../../models/redraw_result.dart';
import 'ai_common.dart';
import 'ai_provider.dart';
import 'anthropic_service.dart';
import 'gemini_service.dart';
import 'openai_service.dart';

export 'ai_common.dart'
    show AiException, PreparedImage, RedrawRequest, prepareImage;

/// Common interface of every AI back-end.
abstract class AiService {
  AiService(this.config, {http.Client? client})
    : client = client ?? http.Client();

  factory AiService.create(ProviderConfig config, {http.Client? client}) =>
      switch (config.provider) {
        AiProvider.anthropic => AnthropicService(config, client: client),
        AiProvider.google => GeminiService(config, client: client),
        AiProvider.openai ||
        AiProvider.custom => OpenAiService(config, client: client),
      };

  final ProviderConfig config;
  final http.Client client;

  String get providerName => config.provider.shortLabel;

  /// Request builders from the richest variant (strict JSON schema, thinking,
  /// ...) to the most basic one. When the server rejects a variant with HTTP
  /// 400/422 - e.g. an older model or a custom server that lacks a feature -
  /// the next one is tried.
  List<http.Request Function()> requestVariants(RedrawRequest request);

  /// Streams one request and returns the generated text.
  Future<String> streamText(
    http.Request request,
    void Function(int chars)? onProgress,
  );

  /// Model IDs available to this API key.
  Future<List<String>> listModels();

  Future<RedrawResult> redraw(
    RedrawRequest request, {
    void Function(int chars)? onProgress,
  }) async {
    final problem = config.problem;
    if (problem != null) throw AiException('$problem Vào Cài đặt để cấu hình.');

    BadRequestException? lastError;
    for (final build in requestVariants(request)) {
      try {
        final text = await streamText(build(), onProgress);
        return parseRedrawJson(text);
      } on BadRequestException catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? AiException('Không gửi được yêu cầu tới $providerName.');
  }

  void close() => client.close();
}
