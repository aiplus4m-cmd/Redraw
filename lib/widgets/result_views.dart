import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/redraw_result.dart';
import '../services/export_service.dart';

const _blue = Color(0xFF2272B9);
const _orange = Color(0xFFF28A30);
const _ink = Color(0xFF1F2937);

/// Renders a redrawn diagram (SVG) on a white sheet.
class DiagramView extends StatelessWidget {
  const DiagramView({super.key, required this.svg});

  final String svg;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: SvgPicture.string(
        svg,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Không hiển thị được sơ đồ. Hãy thử "Vẽ lại" lần nữa.',
            style: TextStyle(color: _ink),
          ),
        ),
      ),
    );
  }
}

/// A professional-looking table, always rendered on white for export.
class TableSheet extends StatelessWidget {
  const TableSheet({super.key, required this.result});

  final RedrawResult result;

  @override
  Widget build(BuildContext context) {
    final headers = result.paddedHeaders;
    final rows = result.paddedRows;
    final hasHeader = headers.any((h) => h.trim().isNotEmpty);
    const cellPad = EdgeInsets.symmetric(horizontal: 12, vertical: 9);

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _SheetTitle(result.title),
          Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: const Color(0xFFCBD5E1), width: 0.8),
            children: [
              if (hasHeader)
                TableRow(
                  decoration: const BoxDecoration(color: _blue),
                  children: [
                    for (final h in headers)
                      Padding(
                        padding: cellPad,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Text(
                            h,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              for (var i = 0; i < rows.length; i++)
                TableRow(
                  decoration: BoxDecoration(
                    color: i.isOdd ? const Color(0xFFEAF3FB) : Colors.white,
                  ),
                  children: [
                    for (final c in rows[i])
                      Padding(
                        padding: cellPad,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Text(c, style: const TextStyle(color: _ink)),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Typeset transcription (light markdown), rendered on white for export.
class TextSheet extends StatelessWidget {
  const TextSheet({super.key, required this.result});

  final RedrawResult result;

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(color: _ink, fontSize: 15, height: 1.55);
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SheetTitle(result.title),
          for (final line in parseMarkup(result.text))
            switch (line.type) {
              MarkupType.h1 => Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Text(
                  line.text,
                  style: const TextStyle(
                    color: _blue,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              MarkupType.h2 => Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  line.text,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              MarkupType.bullet || MarkupType.numbered => Padding(
                padding: const EdgeInsets.only(left: 10, bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        line.type == MarkupType.bullet ? '•' : line.marker,
                        style: body.copyWith(
                          color: _orange,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(child: Text(line.text, style: body)),
                  ],
                ),
              ),
              MarkupType.blank => const SizedBox(height: 10),
              MarkupType.paragraph => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  line.text,
                  style: body,
                  textAlign: TextAlign.justify,
                ),
              ),
            },
        ],
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    if (title.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _blue,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Container(height: 3, width: 56, color: _orange),
        ],
      ),
    );
  }
}
