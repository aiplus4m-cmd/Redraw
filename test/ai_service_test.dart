import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ve_lai_cho_dep/models/redraw_result.dart';
import 'package:ve_lai_cho_dep/services/ai/ai_provider.dart';
import 'package:ve_lai_cho_dep/services/ai/ai_service.dart';

const _result = {
  'kind': 'text',
  'title': 'Ghi chú',
  'summary': 'Chép lại ghi chú',
  'svg': '',
  'table': {'headers': [], 'rows': []},
  'text': 'Xin chào',
};

/// Splits [text] into a few chunks to exercise streaming concatenation.
List<String> _chunks(String text) {
  final n = (text.length / 3).ceil();
  return [
    for (var i = 0; i < text.length; i += n)
      text.substring(i, (i + n).clamp(0, text.length)),
  ];
}

String _sse(List<Object> events) =>
    events.map((e) => 'data: ${jsonEncode(e)}\n\n').join();

http.StreamedResponse _streamed(String body, [int status = 200]) =>
    http.StreamedResponse(Stream.value(utf8.encode(body)), status);

ProviderConfig _config(AiProvider p, {String baseUrl = ''}) => ProviderConfig(
  provider: p,
  apiKey: 'test-key',
  model: p == AiProvider.custom ? 'llava' : p.defaultModel,
  baseUrl: baseUrl.isEmpty ? p.defaultBaseUrl : baseUrl,
);

final _image = PreparedImage('AAAA', 'image/jpeg');

void main() {
  final json = jsonEncode(_result);

  test('Anthropic: streams text deltas and falls back on HTTP 400', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient.streaming((req, bodyStream) async {
      final body =
          jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
      bodies.add(body);
      expect(req.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(req.headers['x-api-key'], 'test-key');
      if (bodies.length == 1) {
        return _streamed('{"error":{"message":"thinking not supported"}}', 400);
      }
      return _streamed(
        _sse([
          {'type': 'message_start', 'message': {}},
          for (final c in _chunks(json))
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': c},
            },
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
          },
        ]),
      );
    });
    final service = AiService.create(
      _config(AiProvider.anthropic),
      client: client,
    );
    final r = await service.redraw(RedrawRequest(image: _image));
    expect(r.kind, RedrawKind.text);
    expect(r.text, 'Xin chào');
    expect(bodies.length, 2);
    expect(bodies[0]['fallbacks'], 'default');
    expect(bodies[1].containsKey('thinking'), isFalse);
  });

  test('Anthropic: refusal becomes a readable error', () async {
    final client = MockClient.streaming(
      (req, _) async => _streamed(
        _sse([
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'refusal'},
          },
        ]),
      ),
    );
    final service = AiService.create(
      _config(AiProvider.anthropic),
      client: client,
    );
    expect(
      service.redraw(RedrawRequest(image: _image)),
      throwsA(isA<AiException>()),
    );
  });

  test('Gemini: concatenates parts and skips thoughts', () async {
    late http.BaseRequest seen;
    final client = MockClient.streaming((req, body) async {
      seen = req;
      final chunks = _chunks(json);
      return _streamed(
        _sse([
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'thinking…', 'thought': true},
                    {'text': chunks[0]},
                  ],
                },
              },
            ],
          },
          for (final c in chunks.skip(1))
            {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': c},
                    ],
                  },
                },
              ],
            },
          {
            'candidates': [
              {'finishReason': 'STOP'},
            ],
          },
        ]),
      );
    });
    final service = AiService.create(
      _config(AiProvider.google),
      client: client,
    );
    final r = await service.redraw(RedrawRequest(image: _image));
    expect(r.title, 'Ghi chú');
    expect(
      seen.url.path,
      endsWith('/models/gemini-pro-latest:streamGenerateContent'),
    );
    expect(seen.url.queryParameters['alt'], 'sse');
    expect(seen.headers['x-goog-api-key'], 'test-key');
  });

  test('OpenAI: parses chat completion chunks with bearer auth', () async {
    late Map<String, dynamic> sent;
    final client = MockClient.streaming((req, body) async {
      sent = jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
      expect(req.headers['authorization'], 'Bearer test-key');
      expect(req.url.toString(), 'https://api.openai.com/v1/chat/completions');
      final events = _sse([
        for (final c in _chunks(json))
          {
            'choices': [
              {
                'delta': {'content': c},
                'finish_reason': null,
              },
            ],
          },
        {
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'},
          ],
        },
      ]);
      return _streamed('${events}data: [DONE]\n\n');
    });
    final service = AiService.create(
      _config(AiProvider.openai),
      client: client,
    );
    final r = await service.redraw(RedrawRequest(image: _image));
    expect(r.text, 'Xin chào');
    expect((sent['response_format'] as Map)['type'], 'json_schema');
  });

  test(
    'Custom: uses base URL, steps down to plain prompt, accepts fenced JSON',
    () async {
      final formats = <Object?>[];
      final client = MockClient.streaming((req, body) async {
        final sent =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        formats.add(sent['response_format']);
        expect(
          req.url.toString(),
          'http://localhost:11434/v1/chat/completions',
        );
        if (sent.containsKey('response_format')) {
          return _streamed(
            '{"error":{"message":"response_format unsupported"}}',
            400,
          );
        }
        return _streamed(
          _sse([
            {
              'choices': [
                {
                  'delta': {'content': 'Đây là kết quả:\n```json\n$json\n```'},
                  'finish_reason': 'stop',
                },
              ],
            },
          ]),
        );
      });
      final service = AiService.create(
        _config(AiProvider.custom, baseUrl: 'http://localhost:11434/v1/'),
        client: client,
      );
      final r = await service.redraw(RedrawRequest(image: _image));
      expect(r.text, 'Xin chào');
      expect(formats.length, 3);
      expect(formats.last, isNull);
    },
  );

  test('Custom provider requires a valid base URL', () {
    const c = ProviderConfig(
      provider: AiProvider.custom,
      apiKey: '',
      model: 'llava',
      baseUrl: 'not a url',
    );
    expect(c.problem, isNotNull);
  });

  test('listModels reads ids from each provider format', () async {
    final client = MockClient((req) async {
      if (req.url.host.contains('googleapis')) {
        return http.Response(
          jsonEncode({
            'models': [
              {
                'name': 'models/gemini-pro-latest',
                'supportedGenerationMethods': ['generateContent'],
              },
              {
                'name': 'models/embedding-001',
                'supportedGenerationMethods': ['embedContent'],
              },
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'b-model'},
            {'id': 'a-model'},
          ],
        }),
        200,
      );
    });
    expect(
      await AiService.create(
        _config(AiProvider.google),
        client: client,
      ).listModels(),
      ['gemini-pro-latest'],
    );
    expect(
      await AiService.create(
        _config(AiProvider.openai),
        client: client,
      ).listModels(),
      ['a-model', 'b-model'],
    );
  });
}
