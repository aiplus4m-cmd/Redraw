import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../models/redraw_result.dart';

class ClaudeException implements Exception {
  ClaudeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An image prepared for the Messages API (base64 + media type).
class PreparedImage {
  PreparedImage(this.base64Data, this.mediaType);
  final String base64Data;
  final String mediaType;
}

/// Calls the Claude Messages API (raw HTTP; Dart has no official SDK) to
/// analyse a photo and return a clean, structured redraw.
class ClaudeService {
  ClaudeService({
    required this.apiKey,
    required this.model,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;

  static final _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  /// Longest edge sent to the API. Larger photos are downscaled so the request
  /// stays well under the 5 MB per-image limit while keeping handwriting legible.
  static const _maxEdge = 2400;

  static const _systemPrompt = '''
You are "Vẽ lại cho đẹp" (Redraw Beautifully), a document-cleanup assistant made by NhamStudio.
The user sends a photo of something drawn or written by hand, or a poorly formatted screenshot.
Your job is to understand its content precisely and return a clean, professional re-creation.

First decide what the image mainly is:
- "diagram": flowcharts, process flows, mind maps, org charts, block diagrams, sequence/state diagrams, network sketches, timelines.
- "table": anything organised in rows and columns (grids, schedules, price lists, comparison tables, forms laid out as tables).
- "text": handwritten or printed notes, letters, paragraphs, lists - prose content without a dominant diagram or table.

Faithfulness rules (apply to every kind):
- Keep ALL of the original content: every node, label, arrow, cell and sentence. Do not invent, drop or summarise content.
- Keep the original language and its diacritics exactly (Vietnamese text stays Vietnamese with full accents). Fix only obvious spelling slips.
- If a word is illegible, make the best guess from context and mark it with [?].

For "diagram", produce "svg": one complete, self-contained SVG 1.1 document that redraws the diagram beautifully.
- Root element: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 W H" width="W" height="H"> with W between 800 and 1800.
- Lay the diagram out cleanly: consistent spacing, aligned on a grid, no overlapping shapes, labels or crossing arrows where avoidable. Preserve the original flow direction and topology.
- Use standard flowchart shapes: rounded rectangles for steps, diamonds for decisions, ellipses/pills for start/end, parallelograms for input/output.
- Palette: primary #2272B9 (blue), accent #F28A30 (orange), soft fills like #EAF3FB and #FFF1E4, strokes 2-3 px, text #1F2937. White background rect covering the whole canvas.
- Text: font-family="Be Vietnam Pro, Arial, sans-serif", font-size 14-20, text-anchor="middle" where centred. Wrap long labels into several <tspan x=".." dy=".."> lines and size boxes so text never overflows.
- Draw every arrowhead explicitly as a small filled <polygon>. Do NOT use <marker>, <style>, CSS classes, <foreignObject>, filters, masks, external images or fonts, or JavaScript. Use only presentation attributes.
- Optionally put the title at the top of the canvas.
- Leave "table" with empty arrays and "text" empty.

For "table", fill "table": "headers" is the header row (empty array if there is none) and "rows" is the body, one array of cell strings per row, all rows with the same number of cells (use "" for empty cells, repeat merged-cell values only where that helps reading). Leave "svg" and "text" empty.

For "text", fill "text" with the full transcription. Preserve paragraphs and line breaks that carry meaning. You may use this light markup only: "# " and "## " for headings, "- " for bullet items, "1. " for numbered items. Leave "svg" empty and "table" with empty arrays.

Always set "title" to a short, descriptive title in the document's language, and "summary" to one sentence (in Vietnamese) describing what was redrawn.''';

  static const Map<String, dynamic> _outputSchema = {
    'type': 'object',
    'properties': {
      'kind': {
        'type': 'string',
        'enum': ['diagram', 'table', 'text'],
      },
      'title': {'type': 'string'},
      'summary': {'type': 'string'},
      'svg': {'type': 'string'},
      'table': {
        'type': 'object',
        'properties': {
          'headers': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'rows': {
            'type': 'array',
            'items': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
        },
        'required': ['headers', 'rows'],
        'additionalProperties': false,
      },
      'text': {'type': 'string'},
    },
    'required': ['kind', 'title', 'summary', 'svg', 'table', 'text'],
    'additionalProperties': false,
  };

  /// Downscales/re-encodes the image off the UI thread when needed.
  static Future<PreparedImage> prepareImage(Uint8List bytes) =>
      compute(_prepareImage, bytes);

  static PreparedImage _prepareImage(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw ClaudeException(
        'Không đọc được ảnh. Hãy chọn ảnh JPG, PNG hoặc WEBP.',
      );
    }
    var image = img.bakeOrientation(decoded);
    final longest = image.width > image.height ? image.width : image.height;
    if (longest > _maxEdge) {
      image = image.width >= image.height
          ? img.copyResize(
              image,
              width: _maxEdge,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              image,
              height: _maxEdge,
              interpolation: img.Interpolation.average,
            );
    }
    var quality = 90;
    var jpg = img.encodeJpg(image, quality: quality);
    while (jpg.length > 4 * 1024 * 1024 && quality > 50) {
      quality -= 10;
      jpg = img.encodeJpg(image, quality: quality);
    }
    return PreparedImage(base64Encode(jpg), 'image/jpeg');
  }

  /// Sends [image] to Claude and returns the structured redraw.
  ///
  /// [onProgress] receives the number of characters generated so far.
  /// [previous] + [refineInstruction] ask Claude to revise an earlier result.
  Future<RedrawResult> redraw({
    required PreparedImage image,
    RedrawMode mode = RedrawMode.auto,
    String extraInstructions = '',
    RedrawResult? previous,
    String refineInstruction = '',
    void Function(int chars)? onProgress,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw ClaudeException(
        'Chưa có Anthropic API key. Vào Cài đặt để nhập key.',
      );
    }

    final instructions = StringBuffer()
      ..writeln(switch (mode) {
        RedrawMode.auto =>
          'Detect the kind of this image automatically and redraw it.',
        RedrawMode.diagram =>
          'Treat this image as a "diagram" and redraw it as SVG.',
        RedrawMode.table => 'Treat this image as a "table" and extract it.',
        RedrawMode.text => 'Treat this image as "text" and transcribe it.',
      });
    if (extraInstructions.trim().isNotEmpty) {
      instructions
        ..writeln()
        ..writeln('Additional style preferences from the user:')
        ..writeln(extraInstructions.trim());
    }
    if (previous != null) {
      instructions
        ..writeln()
        ..writeln('You already produced this result for the same image:')
        ..writeln(jsonEncode(previous.toJson()))
        ..writeln()
        ..writeln(
          'Revise it according to the user\'s request below, keep everything '
          'else unchanged, and return the full updated result.',
        )
        ..writeln('User request: ${refineInstruction.trim()}');
    }

    final body = {
      'model': model,
      'max_tokens': 64000,
      'stream': true,
      'thinking': {'type': 'adaptive'},
      'output_config': {
        'effort': 'high',
        'format': {'type': 'json_schema', 'schema': _outputSchema},
      },
      // Server-side fallback: if a safety classifier declines, the API retries
      // on Anthropic's recommended fallback model instead of returning a refusal.
      'fallbacks': 'default',
      'system': _systemPrompt,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': image.mediaType,
                'data': image.base64Data,
              },
            },
            {'type': 'text', 'text': instructions.toString()},
          ],
        },
      ],
    };

    final request = http.Request('POST', _endpoint)
      ..headers.addAll({
        'content-type': 'application/json',
        'x-api-key': apiKey.trim(),
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'server-side-fallback-2026-07-01',
      })
      ..body = jsonEncode(body);

    final http.StreamedResponse response;
    try {
      response = await _client
          .send(request)
          .timeout(const Duration(minutes: 2));
    } on TimeoutException {
      throw ClaudeException('Hết thời gian chờ kết nối tới máy chủ Claude.');
    } on Exception catch (e) {
      throw ClaudeException('Không kết nối được tới máy chủ Claude: $e');
    }

    if (response.statusCode != 200) {
      final errBody = await response.stream.bytesToString();
      throw ClaudeException(_describeHttpError(response.statusCode, errBody));
    }

    final text = StringBuffer();
    String? stopReason;
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(const Duration(minutes: 5))) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      final Map<String, dynamic> event;
      try {
        event = jsonDecode(data) as Map<String, dynamic>;
      } on FormatException {
        continue;
      }
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
          throw ClaudeException(
            'Máy chủ Claude báo lỗi: ${err?['message'] ?? 'không rõ nguyên nhân'}',
          );
      }
    }

    switch (stopReason) {
      case 'refusal':
        throw ClaudeException(
          'Claude đã từ chối xử lý ảnh này. Hãy thử một ảnh khác.',
        );
      case 'max_tokens':
        throw ClaudeException(
          'Nội dung quá dài nên kết quả bị cắt. Hãy cắt ảnh thành các phần nhỏ hơn.',
        );
    }

    final raw = text.toString().trim();
    if (raw.isEmpty) {
      throw ClaudeException('Claude không trả về kết quả. Vui lòng thử lại.');
    }
    try {
      return RedrawResult.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      throw ClaudeException('Kết quả trả về không hợp lệ. Vui lòng thử lại.');
    }
  }

  static String _describeHttpError(int status, String body) {
    String? apiMessage;
    try {
      apiMessage =
          ((jsonDecode(body) as Map)['error'] as Map?)?['message'] as String?;
    } catch (_) {}
    final detail = apiMessage == null ? '' : '\n($apiMessage)';
    return switch (status) {
      400 => 'Yêu cầu không hợp lệ.$detail',
      401 =>
        'API key không đúng hoặc đã bị thu hồi. Kiểm tra lại trong Cài đặt.$detail',
      403 => 'API key không có quyền dùng mô hình này.$detail',
      404 =>
        'Không tìm thấy mô hình. Hãy chọn mô hình khác trong Cài đặt.$detail',
      413 => 'Ảnh quá lớn.$detail',
      429 =>
        'Đã vượt giới hạn tần suất / hạn mức. Đợi một chút rồi thử lại.$detail',
      529 => 'Máy chủ Claude đang quá tải. Vui lòng thử lại sau.$detail',
      _ when status >= 500 =>
        'Máy chủ Claude gặp sự cố ($status). Thử lại sau.$detail',
      _ => 'Lỗi HTTP $status.$detail',
    };
  }

  void close() => _client.close();
}
