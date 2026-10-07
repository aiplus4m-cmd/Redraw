import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;

import '../../models/art_style.dart';
import 'ai_common.dart';
import 'ai_provider.dart';

/// Which image-generation back-end repaints artwork.
enum ImageEngine {
  auto('Tự động (OpenAI → Gemini → Cloudflare → vector)'),
  openai('OpenAI (GPT Image)'),
  google('Google Gemini (ảnh)'),
  cloudflare('Cloudflare Workers AI (FLUX.2, miễn phí theo ngày)'),
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
const defaultCloudflareImageModel = '@cf/black-forest-labs/flux-2-klein-4b';
const cloudflareImageModels = [
  '@cf/black-forest-labs/flux-2-klein-4b',
  '@cf/black-forest-labs/flux-2-klein-9b',
  '@cf/black-forest-labs/flux-2-dev',
];
const cloudflareApiBase = 'https://api.cloudflare.com/client/v4';

enum ImageBackendKind { openai, google, cloudflare }

/// A resolved image back-end: credentials, endpoint and image model.
class ImageBackend {
  const ImageBackend({
    required this.kind,
    required this.apiKey,
    required this.model,
    this.baseUrl = '',
    this.accountId = '',
  });

  /// OpenAI / Gemini, reusing the key of the matching AI provider.
  factory ImageBackend.fromProvider(ProviderConfig config, String model) =>
      ImageBackend(
        kind: config.provider == AiProvider.google
            ? ImageBackendKind.google
            : ImageBackendKind.openai,
        apiKey: config.apiKey.trim(),
        model: model,
        baseUrl: config.normalizedBaseUrl,
      );

  final ImageBackendKind kind;
  final String apiKey;
  final String model;
  final String baseUrl;

  /// Cloudflare account ID.
  final String accountId;

  String get name => switch (kind) {
    ImageBackendKind.openai => 'OpenAI',
    ImageBackendKind.google => 'Gemini',
    ImageBackendKind.cloudflare => 'Cloudflare',
  };

  /// Cloudflare account IDs are 32 hex characters.
  static bool isValidCloudflareAccountId(String id) =>
      RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id.trim());
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
  }) => switch (backend.kind) {
    ImageBackendKind.google => _gemini(source, prompt),
    ImageBackendKind.openai => _openAi(source, prompt),
    ImageBackendKind.cloudflare => _cloudflare(source, prompt),
  };

  // ------------------------------------------------------------- OpenAI

  Future<Uint8List> _openAi(PreparedImage source, String prompt) async {
    final key = backend.apiKey;
    final uri = Uri.parse('${backend.baseUrl}/images/edits');
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
    final uri = Uri.parse('${backend.baseUrl}/models/$model:generateContent');

    http.Request build(List<String> modalities) => http.Request('POST', uri)
      ..headers.addAll({
        'content-type': 'application/json',
        'x-goog-api-key': backend.apiKey,
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

  // --------------------------------------------------------- Cloudflare

  /// Workers AI FLUX.2 models take multipart form data; reference images
  /// must be smaller than 512x512.
  Future<Uint8List> _cloudflare(PreparedImage source, String prompt) async {
    final ref = await compute(
      cloudflareReference,
      base64Decode(source.base64Data),
    );
    final uri = Uri.parse(
      '$cloudflareApiBase/accounts/${backend.accountId.trim()}/ai/run/'
      '${backend.model.trim()}',
    );

    http.MultipartRequest build(Map<String, String> fields) =>
        http.MultipartRequest('POST', uri)
          ..headers['authorization'] = 'Bearer ${backend.apiKey}'
          ..fields.addAll({'prompt': prompt, ...fields})
          ..files.add(
            http.MultipartFile.fromBytes(
              'input_image_0',
              ref.bytes,
              filename: 'input.png',
              contentType: MediaType('image', 'png'),
            ),
          );

    AiException? lastError;
    for (final fields in [
      {'width': '${ref.outWidth}', 'height': '${ref.outHeight}'},
      <String, String>{},
    ]) {
      try {
        final json = await _send(build(fields));
        final result = json['result'];
        final b64 = (result is Map ? result['image'] : null) ?? json['image'];
        if (b64 is String && b64.isNotEmpty) return base64Decode(b64);
        throw AiException('Cloudflare không trả về ảnh.');
      } on BadRequestException catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  /// Checks that the account ID and token can use Workers AI.
  static Future<String> verifyCloudflare(
    String accountId,
    String token, {
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    try {
      final json = await getJson(
        c,
        Uri.parse(
          '$cloudflareApiBase/accounts/${accountId.trim()}/ai/models/search'
          '?per_page=1',
        ),
        {'authorization': 'Bearer ${token.trim()}'},
        providerName: 'Cloudflare',
      );
      if (json['success'] == false) {
        throw AiException('Cloudflare từ chối token hoặc Account ID.');
      }
      return 'Kết nối Cloudflare Workers AI thành công.';
    } finally {
      if (client == null) c.close();
    }
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

/// Reference image for Cloudflare FLUX.2 plus the output size to request.
class CloudflareReference {
  CloudflareReference(this.bytes, this.outWidth, this.outHeight);
  final Uint8List bytes;
  final int outWidth;
  final int outHeight;
}

/// Downscales [jpeg] below 512x512 (PNG) and picks an output size with the
/// same aspect ratio: longest edge 1024, multiples of 16, within 256-1920.
CloudflareReference cloudflareReference(Uint8List jpeg) {
  final decoded = img.decodeImage(jpeg);
  if (decoded == null) {
    throw AiException('Không đọc được ảnh để gửi tới Cloudflare.');
  }
  final w = decoded.width, h = decoded.height;
  final small = w >= h
      ? img.copyResize(decoded, width: w > 511 ? 511 : w)
      : img.copyResize(decoded, height: h > 511 ? 511 : h);

  int snap(double v) => ((v / 16).round() * 16).clamp(256, 1920);
  final ratio = w / h;
  final outW = ratio >= 1 ? 1024 : snap(1024 * ratio);
  final outH = ratio >= 1 ? snap(1024 / ratio) : 1024;
  return CloudflareReference(img.encodePng(small), outW, outH);
}
