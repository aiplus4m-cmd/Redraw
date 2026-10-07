import 'package:http/http.dart' as http;

import '../models/art_style.dart';
import '../models/redraw_result.dart';
import 'ai/ai_service.dart';
import 'ai/image_service.dart';
import 'settings_service.dart';

/// Progress callback: a short status line and characters generated so far.
typedef RedrawProgress = void Function(String status, int chars);

/// Runs a full redraw: the vision model analyses the image, then - for
/// artwork - an image-generation model repaints the picture.
class RedrawPipeline {
  static Future<RedrawResult> run(
    SettingsService settings,
    RedrawRequest request, {
    RedrawProgress? onProgress,
    http.Client? client,
  }) async {
    onProgress?.call('Đang đọc và phân tích ảnh…', 0);
    final service = AiService.create(settings.activeConfig, client: client);
    final RedrawResult result;
    try {
      result = await service.redraw(
        request,
        onProgress: (c) => onProgress?.call('Đang vẽ lại…', c),
      );
    } finally {
      service.close();
    }
    if (result.kind == RedrawKind.artwork) {
      await paint(
        settings,
        result,
        image: request.image,
        style: request.artStyle,
        refineInstruction: request.refineInstruction,
        onProgress: onProgress,
        client: client,
      );
    }
    return result;
  }

  /// Repaints an artwork [result] with the configured image model (also used
  /// on its own to try another art style without re-analysing the image).
  static Future<void> paint(
    SettingsService settings,
    RedrawResult result, {
    required PreparedImage image,
    required ArtStyle style,
    String refineInstruction = '',
    RedrawProgress? onProgress,
    http.Client? client,
  }) async {
    result.artNote = '';
    final backend = settings.imageBackend;
    if (backend == null) {
      if (settings.imageEngine != ImageEngine.vector) {
        result.artNote = settings.imageEngine == ImageEngine.cloudflare
            ? 'Đang hiển thị bản vẽ vector. Nhập Cloudflare Account ID và API '
                  'token trong Cài đặt → Vẽ lại tranh để dùng FLUX.2 miễn phí.'
            : 'Đang hiển thị bản vẽ vector. Nhập API key OpenAI, Google Gemini '
                  'hoặc Cloudflare (miễn phí) trong Cài đặt để AI vẽ lại tranh '
                  'đẹp như tranh thật.';
      }
      return;
    }
    onProgress?.call(
      'Đang vẽ lại tranh bằng ${backend.name} (${backend.model})…',
      0,
    );
    final images = ImageService(backend, client: client);
    try {
      result.artImage = await images.repaint(
        source: image,
        prompt: ImageService.buildPrompt(
          description: result.imagePrompt.isEmpty
              ? result.summary
              : result.imagePrompt,
          style: style,
          refineInstruction: refineInstruction,
        ),
      );
    } on AiException catch (e) {
      result.artNote =
          'Không tạo được ảnh bằng ${backend.name}: ${e.message}\n'
          '${result.artImage == null ? 'Đang hiển thị bản vẽ vector.' : 'Vẫn giữ ảnh trước đó.'}';
    } finally {
      images.close();
    }
  }
}
