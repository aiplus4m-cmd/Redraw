import 'dart:convert';

/// Kind of document detected in the input image.
enum RedrawKind {
  diagram,
  table,
  text;

  String get label => switch (this) {
    RedrawKind.diagram => 'Sơ đồ / lưu đồ',
    RedrawKind.table => 'Bảng biểu',
    RedrawKind.text => 'Văn bản',
  };

  static RedrawKind parse(String value) => RedrawKind.values.firstWhere(
    (k) => k.name == value,
    orElse: () => RedrawKind.text,
  );
}

/// What the user wants the app to produce (auto = let the model decide).
enum RedrawMode {
  auto('Tự nhận diện'),
  diagram('Sơ đồ'),
  table('Bảng'),
  text('Văn bản');

  const RedrawMode(this.label);
  final String label;
}

class RedrawResult {
  RedrawResult({
    required this.kind,
    required this.title,
    required this.summary,
    this.svg = '',
    this.headers = const [],
    this.rows = const [],
    this.text = '',
  });

  final RedrawKind kind;
  final String title;
  final String summary;

  /// Diagram: a self-contained SVG document.
  final String svg;

  /// Table: header row and body rows.
  final List<String> headers;
  final List<List<String>> rows;

  /// Text: transcription using a light markdown subset (#, ##, -, 1.).
  String text;

  factory RedrawResult.fromJson(Map<String, dynamic> json) {
    final table = (json['table'] as Map?)?.cast<String, dynamic>() ?? const {};
    return RedrawResult(
      kind: RedrawKind.parse(json['kind'] as String? ?? 'text'),
      title: (json['title'] as String? ?? '').trim(),
      summary: (json['summary'] as String? ?? '').trim(),
      svg: (json['svg'] as String? ?? '').trim(),
      headers: [
        for (final h in (table['headers'] as List? ?? const [])) h.toString(),
      ],
      rows: [
        for (final r in (table['rows'] as List? ?? const []))
          [for (final c in (r as List)) c.toString()],
      ],
      text: (json['text'] as String? ?? '').trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'title': title,
    'summary': summary,
    'svg': svg,
    'table': {'headers': headers, 'rows': rows},
    'text': text,
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Normalized table where every row has the same number of cells.
  List<List<String>> get paddedRows {
    final width = [
      headers.length,
      for (final r in rows) r.length,
    ].fold<int>(0, (a, b) => a > b ? a : b);
    return [
      for (final r in rows) [...r, for (var i = r.length; i < width; i++) ''],
    ];
  }

  List<String> get paddedHeaders {
    final width = [
      headers.length,
      for (final r in rows) r.length,
    ].fold<int>(0, (a, b) => a > b ? a : b);
    return [...headers, for (var i = headers.length; i < width; i++) ''];
  }
}
