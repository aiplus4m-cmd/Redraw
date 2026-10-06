import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/redraw_result.dart';
import '../services/ai/ai_service.dart';
import '../services/export_service.dart';
import '../services/settings_service.dart';
import '../widgets/progress_panel.dart';
import '../widgets/result_views.dart';

enum ExportFormat {
  png('Ảnh PNG', 'png', 'image/png', Icons.image_outlined),
  pdf('PDF', 'pdf', 'application/pdf', Icons.picture_as_pdf_outlined),
  txt('Văn bản .txt', 'txt', 'text/plain', Icons.description_outlined),
  csv('Bảng tính .csv', 'csv', 'text/csv', Icons.grid_on_outlined),
  svg('Vector .svg', 'svg', 'image/svg+xml', Icons.polyline_outlined);

  const ExportFormat(this.label, this.ext, this.mime, this.icon);
  final String label;
  final String ext;
  final String mime;
  final IconData icon;
}

class ResultScreen extends StatefulWidget {
  const ResultScreen({
    super.key,
    required this.settings,
    required this.original,
    required this.prepared,
    required this.initial,
  });

  final SettingsService settings;
  final Uint8List original;
  final PreparedImage prepared;
  final RedrawResult initial;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final _previewKey = GlobalKey();
  final _refineCtrl = TextEditingController();
  late final TextEditingController _textCtrl;
  late RedrawResult _result;
  bool _showOriginal = false;
  bool _editingText = false;
  bool _busy = false;
  int _progressChars = 0;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _result = widget.initial;
    _textCtrl = TextEditingController(text: _result.text);
  }

  @override
  void dispose() {
    _refineCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  List<ExportFormat> get _formats => switch (_result.kind) {
    RedrawKind.diagram => const [
      ExportFormat.png,
      ExportFormat.pdf,
      ExportFormat.svg,
    ],
    RedrawKind.table => const [
      ExportFormat.png,
      ExportFormat.pdf,
      ExportFormat.csv,
    ],
    RedrawKind.text => const [
      ExportFormat.txt,
      ExportFormat.pdf,
      ExportFormat.png,
    ],
  };

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<Uint8List> _build(ExportFormat f) async {
    switch (f) {
      case ExportFormat.png:
        // Make sure the preview (not the original photo) is on screen to capture.
        if (_showOriginal) setState(() => _showOriginal = false);
        await WidgetsBinding.instance.endOfFrame;
        return ExportService.buildPng(_result, _previewKey);
      case ExportFormat.pdf:
        return ExportService.buildPdf(_result);
      case ExportFormat.txt:
        return ExportService.buildTxt(_result);
      case ExportFormat.csv:
        return ExportService.buildCsv(_result);
      case ExportFormat.svg:
        return Uint8List.fromList(utf8.encode(_result.svg));
    }
  }

  Future<void> _export(ExportFormat f, {required bool share}) async {
    _commitTextEdit();
    setState(() => _exporting = true);
    try {
      final bytes = await _build(f);
      final name = '${ExportService.safeFileName(_result.title)}.${f.ext}';
      if (share) {
        await ExportService.share(bytes, name, f.mime);
      } else {
        final where = await ExportService.save(bytes, name, f.mime);
        if (where != null && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Đã lưu: $where')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không xuất được tệp: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _commitTextEdit() {
    if (_editingText) {
      _result.text = _textCtrl.text;
      setState(() => _editingText = false);
    }
  }

  Future<void> _refine() async {
    final instruction = _refineCtrl.text.trim();
    if (instruction.isEmpty) return;
    _commitTextEdit();
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _progressChars = 0;
    });
    final service = AiService.create(widget.settings.activeConfig);
    try {
      final updated = await service.redraw(
        RedrawRequest(
          image: widget.prepared,
          extraInstructions: widget.settings.extraInstructions,
          previous: _result,
          refineInstruction: instruction,
        ),
        onProgress: (c) {
          if (mounted) setState(() => _progressChars = c);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = updated;
        _textCtrl.text = updated.text;
        _refineCtrl.clear();
        _showOriginal = false;
      });
    } on AiException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Đã có lỗi xảy ra: $e');
    } finally {
      service.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _preview() {
    if (_showOriginal) {
      return InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Image.memory(widget.original, fit: BoxFit.contain),
        ),
      );
    }
    switch (_result.kind) {
      case RedrawKind.diagram:
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: RepaintBoundary(
              key: _previewKey,
              child: DiagramView(svg: _result.svg),
            ),
          ),
        );
      case RedrawKind.table:
        return SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: RepaintBoundary(
              key: _previewKey,
              child: TableSheet(result: _result),
            ),
          ),
        );
      case RedrawKind.text:
        if (_editingText) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _textCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                helperText: 'Dùng "# " cho tiêu đề, "- " cho gạch đầu dòng.',
              ),
            ),
          );
        }
        return SingleChildScrollView(
          child: RepaintBoundary(
            key: _previewKey,
            child: TextSheet(result: _result),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final preview = Card(
      clipBehavior: Clip.antiAlias,
      child: Container(color: Colors.white, child: _preview()),
    );

    final side = ListView(
      padding: const EdgeInsets.all(16),
      shrinkWrap: !wide,
      physics: wide ? null : const NeverScrollableScrollPhysics(),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              avatar: Icon(switch (_result.kind) {
                RedrawKind.diagram => Icons.account_tree_outlined,
                RedrawKind.table => Icons.table_chart_outlined,
                RedrawKind.text => Icons.notes_outlined,
              }, size: 18),
              label: Text(_result.kind.label),
            ),
            if (_result.kind == RedrawKind.text)
              ActionChip(
                avatar: const Icon(Icons.copy_all_outlined, size: 18),
                label: const Text('Sao chép chữ'),
                onPressed: () {
                  _commitTextEdit();
                  Clipboard.setData(ClipboardData(text: _result.text));
                  _snack('Đã sao chép văn bản');
                },
              ),
          ],
        ),
        if (_result.summary.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _result.summary,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 20),
        Text('Xuất kết quả', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final f in _formats)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _exporting || _busy
                        ? null
                        : () => _export(f, share: false),
                    icon: Icon(f.icon),
                    label: Text('Lưu ${f.label}'),
                  ),
                ),
                if (_isMobile) ...[
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: 'Chia sẻ ${f.label}',
                    onPressed: _exporting || _busy
                        ? null
                        : () => _export(f, share: true),
                    icon: const Icon(Icons.share_outlined),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 20),
        Text(
          'Chưa ưng ý? Yêu cầu chỉnh sửa',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _refineCtrl,
          enabled: !_busy,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText:
                'VD: đổi sang bố cục ngang, tô màu xanh lá cho bước kết thúc, '
                'thêm cột "Ghi chú"…',
          ),
        ),
        const SizedBox(height: 10),
        if (_busy)
          ProgressPanel(chars: _progressChars)
        else
          FilledButton.icon(
            onPressed: _refine,
            icon: const Icon(Icons.auto_fix_high_outlined),
            label: const Text('Vẽ lại theo yêu cầu'),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _result.title.isEmpty ? 'Kết quả' : _result.title,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_result.kind == RedrawKind.text && !_showOriginal)
            IconButton(
              tooltip: _editingText ? 'Xong' : 'Sửa văn bản',
              icon: Icon(_editingText ? Icons.check : Icons.edit_outlined),
              onPressed: () {
                if (_editingText) {
                  _commitTextEdit();
                } else {
                  _textCtrl.text = _result.text;
                  setState(() => _editingText = true);
                }
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Bản đẹp')),
                ButtonSegment(value: true, label: Text('Ảnh gốc')),
              ],
              selected: {_showOriginal},
              onSelectionChanged: (s) {
                _commitTextEdit();
                setState(() => _showOriginal = s.first);
              },
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: preview,
                    ),
                  ),
                  SizedBox(width: 360, child: side),
                ],
              )
            else
              ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: SizedBox(
                      height: MediaQuery.sizeOf(context).height * 0.55,
                      child: preview,
                    ),
                  ),
                  side,
                ],
              ),
            if (_exporting) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
