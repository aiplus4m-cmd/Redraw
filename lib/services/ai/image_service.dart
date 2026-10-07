import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../models/art_style.dart';
import 'ai_common.dart';
import 'ai_provider.dart';

/// Which image-generation back-end repaints artwork.
enum ImageEngine {
  auto('Tự động (OpenAI → Gemini → vector)'),
  openai('OpenAI (GPT Image)'),
  google('Google Gemini (ảnh)'),
  vector('Chỉ vẽ vector (không tạo ảnh AI)');

  const ImageEngine(this.label);
  final String label;

  static ImageEngine parse(String? name) => ImageEngine.values.firstWhere(
    (e) => e.name == name,
    orElse: () => ImageEngine.auto,
  );
}

const defaultOpenAiImageModel = 'gpt-image-2';
const defaultGeminiImageModel = 'gemini-3.1-flash-image-preview';

/// A resolved image back-end: provider connection + image model.
class ImageBackend {
  const ImageBackend(this.config, this.model);

  final ProviderConfig config;
  final String model;

  String get name => config.provider.shortLabel;
}

/// Repaints a picture with an image-generation model, using the original
/// photo as reference so the composition is preserved.
class ImageService {
  ImageService(this.backend, {http.Client? client})
    : client = client ?? http.Client();

  final ImageBackend backend;
  final http.Client client;

  static String buildPrompt({
    required String description,
    required ArtStyle style,
    String refineInstruction = '',
  }) {
    final b = StringBuffer(
      'Redraw the attached picture so it looks beautiful and professionally '
      'made. Keep exactly the same subjects, characters, objects, their '
      'number, poses and positions, the same composition, framing and '
      'overall colour intent as the attached image; improve line quality, '
      'proportions, colouring, shading, lighting and detail. ',
    );
    b.write(
      style.prompt.isEmpty
          ? 'Keep the original art style, but make it polished. '
          : 'Render it as ${style.prompt}. ',
    );
    b.write(
      'Do not add any text, letters, signature or watermark unless the '
      'original picture contains text. ',
    );
    if (description.trim().isNotEmpty) {
      b.write('\n\nDescription of the picture: ${description.trim()}');
    }
    if (refineInstruction.trim().isNotEmpty) {
      b.write(
        '\n\nAdditional request from the user: ${refineInstruction.trim()}',
      );
    }
    return b.toString();
  }

  Future<Uint8List> repaint({
    required PreparedImage source,
    required String prompt,
  }) => switch (backend.config.provider) {
    AiProvider.google => _gemini(source, prompt),
    _ => _openAi(source, prompt),
  };

  // ------------------------------------------------------------- OpenAI

  Future<Uint8List> _openAi(PreparedImage source, String prompt) async {
    final key = backend.config.apiKey.trim();
    final uri = Uri.parse('${backend.config.normalizedBaseUrl}/images/edits');
    final imageBytes = base64Decode(source.base64Data);

    http.MultipartRequest build(Map<String, String> fields) =>
        http.MultipartRequest('POST', uri)
          ..headers['authorization'] = 'Bearer $key'
          ..fields.addAll({'model': backend.model, 'prompt': prompt, ...fields})
          ..files.add(
            http.MultipartFile.fromBytes(
              'image',
              imageBytes,
              filename: 'input.jpg',
              contentType: MediaType.parse(source.mediaType),
            ),
          );

    // Richest request first; older models reject some fields with HTTP 400.
    final variants = <Map<String, String>>[
      {'size': 'auto', 'quality': 'high', 'input_fidelity': 'high'},
      {'size': 'auto', 'quality': 'high'},
      {},
    ];
    AiException? lastError;
    for (final fields in variants) {
      try {
        final json = await _send(build(fields));
        final data = json['data'] as List?;
        final first = (data == null || data.isEmpty) ? null : data.first as Map;
        final b64 = first?['b64_json'] as String?;
        if (b64 != null && b64.isNotEmpty) return base64Decode(b64);
        final url = first?['url'] as String?;
        if (url != null) return await _download(url);
        throw AiException('OpenAI không trả về ảnh.');
      } on BadRequestException catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  // ------------------------------------------------------------- Gemini

  Future<Uint8List> _gemini(PreparedImage source, String prompt) async {
    var model = backend.model.trim();
    if (model.startsWith('models/')) model = model.substring(7);
    final uri = Uri.parse(
      '${backend.config.normalizedBaseUrl}/models/$model:generateContent',
    );

    http.Request build(List<String> modalities) => http.Request('POST', uri)
      ..headers.addAll({
        'content-type': 'application/json',
        'x-goog-api-key': backend.config.apiKey.trim(),
      })
      ..body = jsonEncode({
        'contents': [
          {
            'role': 'user',
            'parts': [
              {
                'inline_data': {
                  'mime_type': source.mediaType,
                  'data': source.base64Data,
                },
              },
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {'responseModalities': modalities},
      });

    AiException? lastError;
    for (final modalities in const [
      ['IMAGE'],
      ['TEXT', 'IMAGE'],
    ]) {
      try {
        final json = await _send(build(modalities));
        final blockReason = (json['promptFeedback'] as Map?)?['blockReason'];
        if (blockReason != null) {
          throw AiException('Gemini đã chặn yêu cầu tạo ảnh ($blockReason).');
        }
        final candidates = json['candidates'] as List? ?? const [];
        for (final c in candidates) {
          final parts = ((c as Map)['content'] as Map?)?['parts'] as List?;
          for (final part in parts ?? const []) {
            final inline = (part as Map)['inlineData'] ?? part['inline_data'];
            if (inline is Map && inline['data'] is String) {
              return base64Decode(inline['data'] as String);
            }
          }
        }
        final reason = candidates.isEmpty
            ? ''
            : ' (${(candidates.first as Map)['finishReason'] ?? ''})';
        throw AiException('Gemini không trả về ảnh$reason.');
      } on BadRequestException catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  // ------------------------------------------------------------- helpers

  Future<Map<String, dynamic>> _send(http.BaseRequest request) async {
    final name = backend.name;
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(minutes: 5)),
      );
    } on TimeoutException {
      throw AiException('Hết thời gian chờ $name tạo ảnh.');
    } on AiException {
      rethrow;
    } on Exception catch (e) {
      throw AiException('Không kết nối được tới $name: $e');
    }
    final body = utf8.decode(res.bodyBytes);
    if (res.statusCode != 200) {
      final message = describeHttpError(res.statusCode, body, name);
      if (res.statusCode == 400 || res.statusCode == 422) {
        throw BadRequestException(message);
      }
      throw AiException(message);
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw AiException('Phản hồi tạo ảnh từ $name không hợp lệ.');
  }

  Future<Uint8List> _download(String url) async {
    final res = await client.get(Uri.parse(url));
    if (res.statusCode != 200) {
      throw AiException('Không tải được ảnh từ ${backend.name}.');
    }
    return res.bodyBytes;
  }

  void close() => client.close();
}
