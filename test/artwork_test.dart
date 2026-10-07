import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ve_lai_cho_dep/models/art_style.dart';
import 'package:ve_lai_cho_dep/models/redraw_result.dart';
import 'package:ve_lai_cho_dep/services/ai/ai_provider.dart';
import 'package:ve_lai_cho_dep/services/ai/ai_service.dart';
import 'package:ve_lai_cho_dep/services/ai/image_service.dart';
import 'package:ve_lai_cho_dep/services/export_service.dart';
import 'package:ve_lai_cho_dep/services/redraw_pipeline.dart';
import 'package:ve_lai_cho_dep/services/settings_service.dart';

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" width="10" height="10"/>';

final _artJson = jsonEncode({
  'kind': 'artwork',
  'title': 'Con mèo',
  'summary': 'Vẽ lại bức tranh con mèo',
  'svg': _svg,
  'table': {'headers': [], 'rows': []},
  'text': '',
  'image_prompt': 'An orange cat sitting on a green hill under a blue sky.',
});

final _pngBytes = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];
final _image = PreparedImage('AAAA', 'image/jpeg');

String _anthropicSse(String text) =>
    'data: ${jsonEncode({
      'type': 'content_block_delta',
      'delta': {'type': 'text_delta', 'text': text},
    })}\n\n'
    'data: ${jsonEncode({
      'type': 'message_delta',
      'delta': {'stop_reason': 'end_turn'},
    })}\n\n';

Future<SettingsService> _settings(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues({
    'provider': 'anthropic',
    'anthropic_api_key': 'ant-key',
    ...values,
  });
  return SettingsService.load();
}

void main() {
  test('artwork JSON parses kind and image prompt', () {
    final r = RedrawResult.fromJson(
      jsonDecode(_artJson) as Map<String, dynamic>,
    );
    expect(r.kind, RedrawKind.artwork);
    expect(r.imagePrompt, contains('orange cat'));
    expect(r.toJson()['image_prompt'], r.imagePrompt);
  });

  test('image prompt includes style, description and refinement', () {
    final p = ImageService.buildPrompt(
      description: 'A cat',
      style: ArtStyle.watercolor,
      refineInstruction: 'add a hat',
    );
    expect(p, contains('watercolor'));
    expect(p, contains('A cat'));
    expect(p, contains('add a hat'));
    expect(p, contains('same composition'));
  });

  test('pipeline repaints artwork with OpenAI images/edits', () async {
    final settings = await _settings({'openai_api_key': 'oa-key'});
    expect(settings.imageBackend?.config.provider, AiProvider.openai);
    final client = MockClient.streaming((req, body) async {
      if (req.url.host == 'api.anthropic.com') {
        await body.drain<void>();
        return http.StreamedResponse(
          Stream.value(utf8.encode(_anthropicSse(_artJson))),
          200,
        );
      }
      expect(req.url.toString(), 'https://api.openai.com/v1/images/edits');
      expect(req.headers['authorization'], 'Bearer oa-key');
      final form = latin1.decode(await body.toBytes());
      expect(form, contains('name="model"'));
      expect(form, contains('gpt-image-2'));
      expect(form, contains('name="image"'));
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'data': [
                {'b64_json': base64Encode(_pngBytes)},
              ],
            }),
          ),
        ),
        200,
      );
    });
    final r = await RedrawPipeline.run(
      settings,
      RedrawRequest(image: _image, artStyle: ArtStyle.anime),
      client: client,
    );
    expect(r.kind, RedrawKind.artwork);
    expect(r.artImage, _pngBytes);
    expect(r.artNote, isEmpty);
  });

  test('Gemini image model returns inline image data', () async {
    final settings = await _settings({
      'image_engine': 'google',
      'google_api_key': 'g-key',
    });
    final backend = settings.imageBackend!;
    expect(backend.model, defaultGeminiImageModel);
    final client = MockClient((req) async {
      expect(
        req.url.path,
        endsWith('/models/$defaultGeminiImageModel:generateContent'),
      );
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect((sent['generationConfig'] as Map)['responseModalities'], [
        'IMAGE',
      ]);
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'inlineData': {
                      'mimeType': 'image/png',
                      'data': base64Encode(_pngBytes),
                    },
                  },
                ],
              },
            },
          ],
        }),
        200,
      );
    });
    final bytes = await ImageService(
      backend,
      client: client,
    ).repaint(source: _image, prompt: 'x');
    expect(bytes, _pngBytes);
  });

  test('without image keys artwork falls back to the vector redraw', () async {
    final settings = await _settings({});
    expect(settings.imageBackend, isNull);
    final client = MockClient.streaming((req, body) async {
      await body.drain<void>();
      return http.StreamedResponse(
        Stream.value(utf8.encode(_anthropicSse(_artJson))),
        200,
      );
    });
    final r = await RedrawPipeline.run(
      settings,
      RedrawRequest(image: _image),
      client: client,
    );
    expect(r.artImage, isNull);
    expect(r.svg, isNotEmpty);
    expect(r.artNote, contains('vector'));
  });

  test('image generation errors keep the vector and explain why', () async {
    final settings = await _settings({'openai_api_key': 'oa-key'});
    final client = MockClient.streaming((req, body) async {
      await body.drain<void>();
      if (req.url.host == 'api.anthropic.com') {
        return http.StreamedResponse(
          Stream.value(utf8.encode(_anthropicSse(_artJson))),
          200,
        );
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"error":{"message":"quota"}}')),
        429,
      );
    });
    final r = await RedrawPipeline.run(
      settings,
      RedrawRequest(image: _image),
      client: client,
    );
    expect(r.artImage, isNull);
    expect(r.artNote, contains('OpenAI'));
  });

  testWidgets('artwork exports: JPEG output becomes PNG and PDF', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final jpg = img.encodeJpg(img.Image(width: 40, height: 30));
      final r = RedrawResult.fromJson(
        jsonDecode(_artJson) as Map<String, dynamic>,
      )..artImage = jpg;
      final png = ExportService.ensurePng(r.artImage!);
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final pdf = await ExportService.buildPdf(r);
      expect(ascii.decode(pdf.sublist(0, 4)), '%PDF');
      final vectorPdf = await ExportService.buildPdf(r, preferVector: true);
      expect(ascii.decode(vectorPdf.sublist(0, 4)), '%PDF');
    });
  });
}
