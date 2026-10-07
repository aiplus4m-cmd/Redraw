import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/art_style.dart';
import '../models/redraw_result.dart';
import '../services/app_info.dart';
import '../services/ai/ai_service.dart';
import '../services/redraw_pipeline.dart';
import '../services/settings_service.dart';
import '../widgets/progress_panel.dart';
import 'about_screen.dart';
import 'result_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.settings});

  final SettingsService settings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Uint8List? _imageBytes;
  String _imageName = '';
  RedrawMode _mode = RedrawMode.auto;
  bool _busy = false;
  int _progressChars = 0;
  String _progressStatus = '';

  bool get _canUseCamera => Platform.isAndroid || Platform.isIOS;

  Future<void> _pickFromFiles() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Chọn ảnh cần vẽ lại',
      type: FileType.image,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _imageBytes = bytes;
      _imageName = file.name;
    });
  }

  Future<void> _pickFromCamera() async {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera);
    if (shot == null) return;
    final bytes = await shot.readAsBytes();
    setState(() {
      _imageBytes = bytes;
      _imageName = shot.name;
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(settings: widget.settings),
      ),
    );
    setState(() {});
  }

  Future<void> _redraw() async {
    final bytes = _imageBytes;
    if (bytes == null) return;
    final problem = widget.settings.activeConfig.problem;
    if (problem != null) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cần cấu hình AI'),
          content: Text(
            'Ứng dụng dùng AI (Claude, Gemini, OpenAI hoặc API tuỳ chỉnh) để đọc và '
            'vẽ lại ảnh.\n\n$problem',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Để sau'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mở Cài đặt'),
            ),
          ],
        ),
      );
      if (go == true) await _openSettings();
      return;
    }

    setState(() {
      _busy = true;
      _progressChars = 0;
      _progressStatus = '';
    });
    try {
      final prepared = await prepareImage(bytes);
      final result = await RedrawPipeline.run(
        widget.settings,
        RedrawRequest(
          image: prepared,
          mode: _mode,
          extraInstructions: widget.settings.extraInstructions,
          artStyle: widget.settings.artStyle,
        ),
        onProgress: (status, c) {
          if (mounted) {
            setState(() {
              _progressStatus = status;
              _progressChars = c;
            });
          }
        },
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            settings: widget.settings,
            original: bytes,
            prepared: prepared,
            initial: result,
          ),
        ),
      );
    } on AiException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Đã có lỗi xảy ra: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline),
        title: const Text('Không vẽ lại được'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/icon/app_icon.png',
                width: 32,
                height: 32,
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              AppInfo.appName,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Cài đặt',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _busy ? null : _openSettings,
          ),
          IconButton(
            tooltip: 'Giới thiệu',
            icon: const Icon(Icons.info_outline),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Đưa ảnh xấu vào, nhận bản đẹp ra',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Sơ đồ vẽ tay → sơ đồ chuyên nghiệp • Bảng nguệch ngoạc → bảng gọn gàng • Tranh vẽ xấu → tranh đẹp • '
                  'Chữ viết tay → văn bản. Xuất ảnh PNG, PDF hoặc tệp văn bản.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                if (!widget.settings.isReady)
                  Card(
                    color: scheme.secondaryContainer,
                    child: ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: const Text('Chưa cấu hình AI'),
                      subtitle: Text(
                        widget.settings.activeConfig.problem ?? '',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openSettings,
                    ),
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ActionChip(
                      avatar: const Icon(Icons.memory_outlined, size: 18),
                      label: Text(
                        '${widget.settings.provider.shortLabel} · '
                        '${widget.settings.activeConfig.model}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      tooltip: 'Đổi nhà cung cấp / model trong Cài đặt',
                      onPressed: _busy ? null : _openSettings,
                    ),
                  ),
                const SizedBox(height: 20),
                _ImageDropZone(
                  bytes: _imageBytes,
                  name: _imageName,
                  onPick: _busy ? null : _pickFromFiles,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _pickFromFiles,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(
                        _canUseCamera ? 'Chọn từ thư viện' : 'Chọn ảnh từ máy',
                      ),
                    ),
                    if (_canUseCamera)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pickFromCamera,
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Chụp ảnh'),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  'Loại nội dung',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<RedrawMode>(
                    segments: const [
                      ButtonSegment(
                        value: RedrawMode.auto,
                        icon: Icon(Icons.auto_awesome_outlined),
                        label: Text('Tự động'),
                      ),
                      ButtonSegment(
                        value: RedrawMode.diagram,
                        icon: Icon(Icons.account_tree_outlined),
                        label: Text('Sơ đồ'),
                      ),
                      ButtonSegment(
                        value: RedrawMode.table,
                        icon: Icon(Icons.table_chart_outlined),
                        label: Text('Bảng'),
                      ),
                      ButtonSegment(
                        value: RedrawMode.text,
                        icon: Icon(Icons.notes_outlined),
                        label: Text('Văn bản'),
                      ),
                      ButtonSegment(
                        value: RedrawMode.artwork,
                        icon: Icon(Icons.palette_outlined),
                        label: Text('Tranh'),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: _busy
                        ? null
                        : (s) => setState(() => _mode = s.first),
                  ),
                ),
                if (_mode == RedrawMode.auto ||
                    _mode == RedrawMode.artwork) ...[
                  const SizedBox(height: 20),
                  Text(
                    _mode == RedrawMode.artwork
                        ? 'Phong cách tranh'
                        : 'Phong cách tranh (khi ảnh là tranh vẽ)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final style in ArtStyle.values)
                        ChoiceChip(
                          label: Text(style.label),
                          selected: widget.settings.artStyle == style,
                          onSelected: _busy
                              ? null
                              : (_) async {
                                  await widget.settings.saveArtStyle(style);
                                  if (mounted) setState(() {});
                                },
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 28),
                if (_busy)
                  ProgressPanel(chars: _progressChars, status: _progressStatus)
                else
                  FilledButton.icon(
                    onPressed: _imageBytes == null ? null : _redraw,
                    icon: const Icon(Icons.brush_outlined),
                    label: const Text(
                      'Vẽ lại cho đẹp',
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageDropZone extends StatelessWidget {
  const _ImageDropZone({
    required this.bytes,
    required this.name,
    required this.onPick,
  });

  final Uint8List? bytes;
  final String name;
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 320,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outlineVariant, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: bytes == null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 56,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Chạm để chọn ảnh sơ đồ / bảng / ghi chép / tranh vẽ',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'JPG, PNG, WEBP',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(bytes!, fit: BoxFit.contain),
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: Chip(
                      avatar: const Icon(Icons.image_outlined, size: 18),
                      label: Text(name, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
