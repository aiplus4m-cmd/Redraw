import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/redraw_result.dart';
import 'app_info.dart';

/// One line of the light markup used for text transcriptions.
class MarkupLine {
  MarkupLine(this.type, this.text, [this.marker = '']);
  final MarkupType type;
  final String text;
  final String marker;
}

enum MarkupType { h1, h2, bullet, numbered, paragraph, blank }

final _numbered = RegExp(r'^(\d+[.)])\s+(.*)$');

MarkupLine _parseLine(String raw) {
  final line = raw.trimRight();
  final t = line.trimLeft();
  if (t.isEmpty) return MarkupLine(MarkupType.blank, '');
  if (t.startsWith('## ')) return MarkupLine(MarkupType.h2, t.substring(3));
  if (t.startsWith('# ')) return MarkupLine(MarkupType.h1, t.substring(2));
  if (t.startsWith('- ') || t.startsWith('* ') || t.startsWith('• ')) {
    return MarkupLine(MarkupType.bullet, t.substring(2));
  }
  final m = _numbered.firstMatch(t);
  if (m != null) {
    return MarkupLine(MarkupType.numbered, m.group(2)!, m.group(1)!);
  }
  return MarkupLine(MarkupType.paragraph, line);
}

List<MarkupLine> parseMarkup(String text) => [
  for (final raw in const LineSplitter().convert(text)) _parseLine(raw),
];

/// Builds PNG / PDF / TXT / CSV files from a [RedrawResult] and saves or shares them.
class ExportService {
  static const _blue = PdfColor.fromInt(0xFF2272B9);
  static const _orange = PdfColor.fromInt(0xFFF28A30);
  static const _lightBlue = PdfColor.fromInt(0xFFEAF3FB);

  static pw.ThemeData? _theme;

  static Future<pw.ThemeData> _pdfTheme() async {
    if (_theme != null) return _theme!;
    final regular = await rootBundle.load(
      'assets/fonts/BeVietnamPro-Regular.ttf',
    );
    final bold = await rootBundle.load('assets/fonts/BeVietnamPro-Bold.ttf');
    return _theme = pw.ThemeData.withFont(
      base: pw.Font.ttf(regular),
      bold: pw.Font.ttf(bold),
    );
  }

  static String safeFileName(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final base = cleaned.isEmpty ? 've-lai-cho-dep' : cleaned;
    return base.length > 60 ? base.substring(0, 60).trim() : base;
  }

  // ---------------------------------------------------------------- PNG

  /// Rasterizes a diagram SVG at high resolution on a white background.
  static Future<Uint8List> svgToPng(
    String svg, {
    double targetWidth = 2400,
  }) async {
    final info = await vg.loadPicture(SvgStringLoader(svg), null);
    try {
      final size = info.size;
      if (size.isEmpty) throw StateError('SVG has no size');
      final scale = targetWidth / size.width;
      final w = (size.width * scale).round();
      final h = (size.height * scale).round();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..drawRect(
          ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        )
        ..scale(scale);
      canvas.drawPicture(info.picture);
      final image = await recorder.endRecording().toImage(w, h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    } finally {
      info.picture.dispose();
    }
  }

  /// Captures a widget wrapped in a [RepaintBoundary] as PNG.
  static Future<Uint8List> captureBoundary(
    GlobalKey key, {
    double pixelRatio = 3,
  }) async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// Re-encodes JPEG/WEBP output of image models as PNG.
  static Uint8List ensurePng(Uint8List bytes) {
    const sig = [0x89, 0x50, 0x4E, 0x47];
    if (bytes.length > 4 &&
        List.generate(4, (i) => bytes[i]).join() == sig.join()) {
      return bytes;
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    return img.encodePng(decoded);
  }

  /// Whether an artwork result shows the AI-painted image (vs. the vector).
  static bool usesArtImage(RedrawResult r, {bool preferVector = false}) =>
      r.kind == RedrawKind.artwork && r.artImage != null && !preferVector;

  static Future<Uint8List> buildPng(
    RedrawResult result,
    GlobalKey previewKey, {
    bool preferVector = false,
  }) async {
    if (usesArtImage(result, preferVector: preferVector)) {
      return ensurePng(result.artImage!);
    }
    if ((result.kind == RedrawKind.diagram ||
            result.kind == RedrawKind.artwork) &&
        result.svg.isNotEmpty) {
      return svgToPng(result.svg);
    }
    return captureBoundary(previewKey);
  }

  // ---------------------------------------------------------------- PDF

  static Future<Uint8List> buildPdf(
    RedrawResult result, {
    Uint8List? diagramPng,
    bool preferVector = false,
  }) async {
    final theme = await _pdfTheme();
    final doc = pw.Document(
      title: result.title,
      author: AppInfo.developer,
      creator: '${AppInfo.appName} - ${AppInfo.developer}',
    );

    pw.Widget footer(pw.Context ctx) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 12),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            '${AppInfo.appName} • ${AppInfo.developer} • topvl.net',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
          pw.Text(
            '${ctx.pageNumber}/${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ],
      ),
    );

    pw.Widget heading() => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          result.title.isEmpty ? AppInfo.appName : result.title,
          style: pw.TextStyle(
            fontSize: 20,
            fontWeight: pw.FontWeight.bold,
            color: _blue,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Container(height: 3, width: 60, color: _orange),
        pw.SizedBox(height: 14),
      ],
    );

    switch (result.kind) {
      case RedrawKind.diagram || RedrawKind.artwork:
        final png =
            diagramPng ??
            (usesArtImage(result, preferVector: preferVector)
                ? ensurePng(result.artImage!)
                : await svgToPng(result.svg));
        final image = pw.MemoryImage(png);
        final landscape = (image.width ?? 1) > (image.height ?? 1) * 1.15;
        doc.addPage(
          pw.Page(
            theme: theme,
            pageFormat: landscape
                ? PdfPageFormat.a4.landscape
                : PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(28),
            build: (ctx) => pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                heading(),
                pw.Expanded(
                  child: pw.Center(
                    child: pw.Image(image, fit: pw.BoxFit.contain),
                  ),
                ),
                footer(ctx),
              ],
            ),
          ),
        );

      case RedrawKind.table:
        final headers = result.paddedHeaders;
        final rows = result.paddedRows;
        final cols = headers.isEmpty
            ? (rows.isEmpty ? 1 : rows.first.length)
            : headers.length;
        final hasHeader = headers.any((h) => h.trim().isNotEmpty);
        doc.addPage(
          pw.MultiPage(
            theme: theme,
            pageFormat: cols > 5
                ? PdfPageFormat.a4.landscape
                : PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(28),
            footer: footer,
            build: (ctx) => [
              heading(),
              pw.TableHelper.fromTextArray(
                headers: hasHeader ? headers : null,
                data: rows,
                border: pw.TableBorder.all(
                  color: PdfColors.grey400,
                  width: 0.6,
                ),
                headerDecoration: const pw.BoxDecoration(color: _blue),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                  fontSize: 10,
                ),
                cellStyle: const pw.TextStyle(fontSize: 9.5),
                cellAlignment: pw.Alignment.centerLeft,
                headerAlignment: pw.Alignment.centerLeft,
                cellPadding: const pw.EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 5,
                ),
                oddRowDecoration: const pw.BoxDecoration(color: _lightBlue),
              ),
            ],
          ),
        );

      case RedrawKind.text:
        doc.addPage(
          pw.MultiPage(
            theme: theme,
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.symmetric(horizontal: 48, vertical: 40),
            footer: footer,
            build: (ctx) => [
              heading(),
              for (final line in parseMarkup(result.text)) _pdfLine(line),
            ],
          ),
        );
    }
    return doc.save();
  }

  static pw.Widget _pdfLine(MarkupLine line) {
    const body = pw.TextStyle(fontSize: 11.5, lineSpacing: 3);
    return switch (line.type) {
      MarkupType.h1 => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 10, bottom: 6),
        child: pw.Text(
          line.text,
          style: pw.TextStyle(
            fontSize: 16,
            fontWeight: pw.FontWeight.bold,
            color: _blue,
          ),
        ),
      ),
      MarkupType.h2 => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 8, bottom: 4),
        child: pw.Text(
          line.text,
          style: pw.TextStyle(fontSize: 13.5, fontWeight: pw.FontWeight.bold),
        ),
      ),
      MarkupType.bullet || MarkupType.numbered => pw.Padding(
        padding: const pw.EdgeInsets.only(left: 12, bottom: 3),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 18,
              child: pw.Text(
                line.type == MarkupType.bullet ? '•' : line.marker,
                style: body.copyWith(
                  color: _orange,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Expanded(child: pw.Text(line.text, style: body)),
          ],
        ),
      ),
      MarkupType.blank => pw.SizedBox(height: 8),
      MarkupType.paragraph => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 3),
        child: pw.Text(line.text, style: body, textAlign: pw.TextAlign.justify),
      ),
    };
  }

  // ---------------------------------------------------------------- TXT / CSV

  static Uint8List buildTxt(RedrawResult result) {
    final buffer = StringBuffer();
    if (result.title.isNotEmpty) {
      buffer
        ..writeln(result.title)
        ..writeln('=' * result.title.length.clamp(3, 60))
        ..writeln();
    }
    buffer.writeln(result.text);
    // UTF-8 BOM so Windows Notepad opens Vietnamese text correctly.
    return Uint8List.fromList([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(buffer.toString()),
    ]);
  }

  static Uint8List buildCsv(RedrawResult result) {
    String esc(String v) =>
        RegExp(r'[",\n\r]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
    final lines = <String>[
      if (result.headers.any((h) => h.trim().isNotEmpty))
        result.paddedHeaders.map(esc).join(','),
      for (final row in result.paddedRows) row.map(esc).join(','),
    ];
    return Uint8List.fromList([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(lines.join('\r\n')),
    ]);
  }

  // ---------------------------------------------------------------- Save / share

  /// Shows the native "save as" dialog. Returns a user-facing location or null.
  static Future<String?> save(
    Uint8List bytes,
    String fileName,
    String mimeType,
  ) async {
    final ext = fileName.split('.').last;
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Lưu tệp',
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (uri == null) return null;
    return uri.scheme == 'file' ? uri.toFilePath() : fileName;
  }

  /// Opens the system share sheet (falls back to the save dialog on desktop).
  static Future<void> share(
    Uint8List bytes,
    String fileName,
    String mimeType,
  ) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType, name: fileName)],
        subject: fileName,
      ),
    );
  }
}
