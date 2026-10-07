import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../../models/art_style.dart';
import '../../models/redraw_result.dart';

/// User-facing error from any AI provider.
class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown internally when the server rejects a request shape (HTTP 400/422),
/// so the caller can retry with a simpler variant.
class BadRequestException extends AiException {
  BadRequestException(super.message);
}

/// An image prepared for upload (base64 JPEG).
class PreparedImage {
  PreparedImage(this.base64Data, this.mediaType);
  final String base64Data;
  final String mediaType;

  String get dataUrl => 'data:$mediaType;base64,$base64Data';
}

/// Longest edge sent to the providers. Larger photos are downscaled so the
/// request stays well under typical 5-20 MB image limits while keeping
/// handwriting legible.
const _maxEdge = 2400;

/// Downscales/re-encodes the image off the UI thread.
Future<PreparedImage> prepareImage(Uint8List bytes) =>
    compute(_prepareImage, bytes);

PreparedImage _prepareImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw AiException('Không đọc được ảnh. Hãy chọn ảnh JPG, PNG hoặc WEBP.');
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

/// System prompt shared by every provider.
const redrawSystemPrompt =
    '''You are "Vẽ lại cho đẹp" (Redraw Beautifully), a document-cleanup assistant made by NhamStudio.
The user sends a photo of something drawn or written by hand, or a poorly formatted screenshot.
It can also be a drawing or painting that looks unpolished.
Your job is to understand its content precisely and return a clean, professional re-creation.

First decide what the image mainly is:
- "diagram": flowcharts, process flows, mind maps, org charts, block diagrams, sequence/state diagrams, network sketches, timelines.
- "table": anything organised in rows and columns (grids, schedules, price lists, comparison tables, forms laid out as tables).
- "text": handwritten or printed notes, letters, paragraphs, lists - prose content without a dominant diagram or table.
- "artwork": a picture made to be looked at rather than read - drawings, sketches, doodles, children's drawings, paintings, cartoons, illustrations, scenes, portraits, animals, landscapes - including clumsy or ugly ones. A picture with a few words in it is still "artwork".

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

For "artwork", redraw the picture so it looks beautiful while staying recognisably the same picture:
- Keep the same subject(s), characters, objects, their count, poses, positions, composition, orientation and overall colour intent. Fix proportions, wobbly lines and messy colouring; add clean outlines, pleasant shading and a tidy background that matches the original scene.
- "svg": a polished vector illustration of the picture as one self-contained SVG 1.1 document. Root <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 W H" width="W" height="H"> with W between 800 and 1600 and the same aspect ratio as the input. Paint the full background first. Use smooth <path> curves, layered shapes and <linearGradient>/<radialGradient> defined in <defs> for depth. Do NOT use <style>, CSS classes, <marker>, <foreignObject>, filters, masks, <image>, external resources or JavaScript. Keep it under about 40,000 characters.
- "image_prompt": a detailed English prompt (80-200 words) for an image-generation model that will repaint the same picture: describe every subject and object with its position, pose, size, colours and the background, then the requested art style (if the user gave none, an attractive, polished version of the original style). Say that the composition must match the input image and that no text, signature or watermark should be added unless the original has text.
- Leave "table" with empty arrays and "text" empty.
For every kind other than "artwork", set "image_prompt" to "".

Always set "title" to a short, descriptive title in the document's language, and "summary" to one sentence (in Vietnamese) describing what was redrawn.
Return ONLY a single JSON object (no markdown fences, no commentary) with exactly these keys:
{"kind": "diagram"|"table"|"text"|"artwork", "title": string, "summary": string, "svg": string, "table": {"headers": [string], "rows": [[string]]}, "text": string, "image_prompt": string}''';

/// JSON schema of the structured result (strict-mode compatible).
const Map<String, dynamic> redrawOutputSchema = {
  'type': 'object',
  'properties': {
    'kind': {
      'type': 'string',
      'enum': ['diagram', 'table', 'text', 'artwork'],
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
    'image_prompt': {'type': 'string'},
  },
  'required': [
    'kind',
    'title',
    'summary',
    'svg',
    'table',
    'text',
    'image_prompt',
  ],
  'additionalProperties': false,
};

/// Everything needed to build one redraw request.
class RedrawRequest {
  RedrawRequest({
    required this.image,
    this.mode = RedrawMode.auto,
    this.extraInstructions = '',
    this.previous,
    this.refineInstruction = '',
    this.artStyle = ArtStyle.original,
  });

  final PreparedImage image;
  final ArtStyle artStyle;
  final RedrawMode mode;
  final String extraInstructions;
  final RedrawResult? previous;
  final String refineInstruction;

  /// The text part of the user message.
  String get userText {
    final b = StringBuffer()
      ..writeln(switch (mode) {
        RedrawMode.auto =>
          'Detect the kind of this image automatically and redraw it.',
        RedrawMode.diagram =>
          'Treat this image as a "diagram" and redraw it as SVG.',
        RedrawMode.table => 'Treat this image as a "table" and extract it.',
        RedrawMode.text => 'Treat this image as "text" and transcribe it.',
        RedrawMode.artwork =>
          'Treat this image as "artwork" and redraw the picture beautifully.',
      });
    if (mode == RedrawMode.auto || mode == RedrawMode.artwork) {
      b.writeln(
        artStyle.prompt.isEmpty
            ? 'If it is artwork, keep its original art style but make it polished.'
            : 'If it is artwork, the requested art style is: ${artStyle.prompt}.',
      );
    }
    if (extraInstructions.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('Additional style preferences from the user:')
        ..writeln(extraInstructions.trim());
    }
    if (previous != null) {
      b
        ..writeln()
        ..writeln('You already produced this result for the same image:')
        ..writeln(jsonEncode(previous!.toJson()))
        ..writeln()
        ..writeln(
          'Revise it according to the user\'s request below, keep '
          'everything else unchanged, and return the full updated result.',
        )
        ..writeln('User request: ${refineInstruction.trim()}');
    }
    return b.toString();
  }
}

/// Parses the model's JSON answer, tolerating markdown fences or stray text
/// around the object (useful for providers without strict JSON mode).
RedrawResult parseRedrawJson(String raw) {
  var text = raw.trim();
  if (text.isEmpty) {
    throw AiException('AI không trả về kết quả. Vui lòng thử lại.');
  }
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) text = text.substring(start, end + 1);
  try {
    final json = jsonDecode(text);
    if (json is Map<String, dynamic>) return RedrawResult.fromJson(json);
  } on FormatException {
    // fall through
  }
  throw AiException(
    'Kết quả trả về không đúng định dạng JSON. '
    'Hãy thử lại hoặc chọn model mạnh hơn.',
  );
}

/// Sends [request] and yields the JSON payload of each server-sent event.
Stream<Map<String, dynamic>> sendSse(
  http.Client client,
  http.Request request, {
  required String providerName,
}) async* {
  final http.StreamedResponse response;
  try {
    response = await client.send(request).timeout(const Duration(minutes: 2));
  } on TimeoutException {
    throw AiException('Hết thời gian chờ kết nối tới $providerName.');
  } on Exception catch (e) {
    throw AiException('Không kết nối được tới $providerName: $e');
  }
  if (response.statusCode != 200) {
    final body = await response.stream.bytesToString();
    final message = describeHttpError(response.statusCode, body, providerName);
    if (response.statusCode == 400 || response.statusCode == 422) {
      throw BadRequestException(message);
    }
    throw AiException(message);
  }
  await for (final line
      in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(minutes: 5))) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') continue;
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) yield decoded;
    } on FormatException {
      continue;
    }
  }
}

/// GET helper for model listing.
Future<Map<String, dynamic>> getJson(
  http.Client client,
  Uri uri,
  Map<String, String> headers, {
  required String providerName,
}) async {
  final http.Response res;
  try {
    res = await client
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 30));
  } on Exception catch (e) {
    throw AiException('Không kết nối được tới $providerName: $e');
  }
  if (res.statusCode != 200) {
    throw AiException(
      describeHttpError(
        res.statusCode,
        utf8.decode(res.bodyBytes),
        providerName,
      ),
    );
  }
  final decoded = jsonDecode(utf8.decode(res.bodyBytes));
  if (decoded is Map<String, dynamic>) return decoded;
  if (decoded is List) return {'data': decoded};
  throw AiException('Phản hồi từ $providerName không hợp lệ.');
}

String describeHttpError(int status, String body, String providerName) {
  String? apiMessage;
  try {
    final decoded = jsonDecode(body);
    final err = decoded is List ? decoded.first : decoded;
    final e = (err as Map)['error'];
    apiMessage = e is Map ? e['message']?.toString() : e?.toString();
    // Cloudflare: {"success": false, "errors": [{"code": ..., "message": ...}]}
    final errors = err['errors'];
    if (apiMessage == null && errors is List && errors.isNotEmpty) {
      final first = errors.first;
      apiMessage = first is Map ? first['message']?.toString() : '$first';
    }
  } catch (_) {
    if (body.trim().isNotEmpty && body.length < 300) apiMessage = body.trim();
  }
  final detail = apiMessage == null ? '' : '\n($apiMessage)';
  return switch (status) {
    400 || 422 => 'Yêu cầu không hợp lệ ($providerName).$detail',
    401 =>
      'API key của $providerName không đúng hoặc đã bị thu hồi. Kiểm tra lại trong Cài đặt.$detail',
    403 => 'API key không có quyền dùng model này ($providerName).$detail',
    404 =>
      'Không tìm thấy model hoặc địa chỉ API ($providerName). Kiểm tra lại trong Cài đặt.$detail',
    413 => 'Ảnh quá lớn.$detail',
    429 =>
      'Đã vượt giới hạn tần suất / hạn mức của $providerName. Đợi một chút rồi thử lại.$detail',
    529 || 503 => '$providerName đang quá tải. Vui lòng thử lại sau.$detail',
    _ when status >= 500 =>
      '$providerName gặp sự cố ($status). Thử lại sau.$detail',
    _ => 'Lỗi HTTP $status từ $providerName.$detail',
  };
}
