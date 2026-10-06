import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings});

  final SettingsService settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _keyCtrl;
  late final TextEditingController _instrCtrl;
  late String _model;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController(text: widget.settings.apiKey);
    _instrCtrl = TextEditingController(text: widget.settings.extraInstructions);
    _model = widget.settings.model;
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _instrCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.settings.save(
      apiKey: _keyCtrl.text,
      model: _model,
      extraInstructions: _instrCtrl.text,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Đã lưu cài đặt')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Anthropic API key',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keyCtrl,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'sk-ant-…',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Key chỉ được lưu trên thiết bị này và gửi trực tiếp tới api.anthropic.com.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse('https://console.anthropic.com/settings/keys'),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Lấy API key tại console.anthropic.com'),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Mô hình AI',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _model,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: [
                  for (final e in availableModels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _model = v ?? defaultModel),
              ),
              const SizedBox(height: 20),
              Text(
                'Phong cách mặc định (không bắt buộc)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _instrCtrl,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText:
                      'VD: dùng tông màu xanh lá; sơ đồ bố cục từ trái sang phải; '
                      'bảng có cột số thứ tự…',
                ),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Lưu cài đặt'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
