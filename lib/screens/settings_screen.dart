import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/ai/ai_provider.dart';
import '../services/ai/ai_service.dart';
import '../services/ai/image_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings});

  final SettingsService settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Text fields for one provider (kept while the user switches providers).
class _ProviderFields {
  _ProviderFields(ProviderConfig c)
    : key = TextEditingController(text: c.apiKey),
      model = TextEditingController(text: c.model),
      baseUrl = TextEditingController(text: c.baseUrl);

  final TextEditingController key;
  final TextEditingController model;
  final TextEditingController baseUrl;
  List<String> fetchedModels = [];

  void dispose() {
    key.dispose();
    model.dispose();
    baseUrl.dispose();
  }
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AiProvider _provider;
  late final Map<AiProvider, _ProviderFields> _fields;
  late final TextEditingController _instrCtrl;
  late ImageEngine _imageEngine;
  late final TextEditingController _openAiImageCtrl;
  late final TextEditingController _geminiImageCtrl;
  late final TextEditingController _cfAccountCtrl;
  late final TextEditingController _cfTokenCtrl;
  late final TextEditingController _cfModelCtrl;
  bool _cfObscure = true;
  bool _cfTesting = false;
  bool _obscure = true;
  bool _testing = false;

  static const _customExamples = <String, String>{
    'OpenRouter': 'https://openrouter.ai/api/v1',
    'DeepSeek': 'https://api.deepseek.com/v1',
    'Groq': 'https://api.groq.com/openai/v1',
    'Ollama (máy cục bộ)': 'http://localhost:11434/v1',
    'LM Studio (máy cục bộ)': 'http://localhost:1234/v1',
  };

  @override
  void initState() {
    super.initState();
    _provider = widget.settings.provider;
    _fields = {
      for (final p in AiProvider.values)
        p: _ProviderFields(widget.settings.configFor(p)),
    };
    _instrCtrl = TextEditingController(text: widget.settings.extraInstructions);
    _imageEngine = widget.settings.imageEngine;
    // Refresh the "API key present" chips of the artwork section.
    for (final p in [AiProvider.openai, AiProvider.google]) {
      _fields[p]!.key.addListener(() {
        if (mounted) setState(() {});
      });
    }
    _openAiImageCtrl = TextEditingController(
      text: widget.settings.openAiImageModel,
    );
    _geminiImageCtrl = TextEditingController(
      text: widget.settings.geminiImageModel,
    );
    _cfAccountCtrl = TextEditingController(
      text: widget.settings.cloudflareAccountId,
    );
    _cfTokenCtrl = TextEditingController(text: widget.settings.cloudflareToken);
    _cfModelCtrl = TextEditingController(
      text: widget.settings.cloudflareImageModel,
    );
  }

  @override
  void dispose() {
    for (final f in _fields.values) {
      f.dispose();
    }
    _instrCtrl.dispose();
    _openAiImageCtrl.dispose();
    _geminiImageCtrl.dispose();
    _cfAccountCtrl.dispose();
    _cfTokenCtrl.dispose();
    _cfModelCtrl.dispose();
    super.dispose();
  }

  _ProviderFields get _current => _fields[_provider]!;

  ProviderConfig _configOf(AiProvider p) => ProviderConfig(
    provider: p,
    apiKey: _fields[p]!.key.text.trim(),
    model: _fields[p]!.model.text.trim(),
    baseUrl: _fields[p]!.baseUrl.text.trim(),
  );

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _save() async {
    final config = _configOf(_provider);
    final problem = config.problem;
    if (problem != null) {
      _snack(problem);
      return;
    }
    final cfAccount = _cfAccountCtrl.text.trim();
    if (cfAccount.isNotEmpty &&
        !ImageBackend.isValidCloudflareAccountId(cfAccount)) {
      _snack('Cloudflare Account ID phải gồm 32 ký tự (0-9, a-f).');
      return;
    }
    await widget.settings.save(
      active: _provider,
      configs: {for (final p in AiProvider.values) p: _configOf(p)},
      extraInstructions: _instrCtrl.text,
      imageEngine: _imageEngine,
      openAiImageModel: _openAiImageCtrl.text,
      geminiImageModel: _geminiImageCtrl.text,
      cloudflareAccountId: _cfAccountCtrl.text,
      cloudflareToken: _cfTokenCtrl.text,
      cloudflareImageModel: _cfModelCtrl.text,
    );
    if (!mounted) return;
    _snack('Đã lưu cài đặt');
    Navigator.of(context).pop();
  }

  /// Fetches the model list; doubles as a connection test.
  Future<List<String>?> _fetchModels() async {
    final config = _configOf(_provider);
    if (_provider.requiresKey && config.apiKey.isEmpty) {
      _snack('Hãy nhập API key trước.');
      return null;
    }
    if (_provider == AiProvider.custom && config.baseUrl.isEmpty) {
      _snack('Hãy nhập Base URL trước.');
      return null;
    }
    setState(() => _testing = true);
    final service = AiService.create(config);
    try {
      final models = await service.listModels();
      if (!mounted) return null;
      setState(() => _fields[config.provider]!.fetchedModels = models);
      return models;
    } on AiException catch (e) {
      if (mounted) _snack(e.message);
      return null;
    } catch (e) {
      if (mounted) _snack('Không lấy được danh sách model: $e');
      return null;
    } finally {
      service.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _testConnection() async {
    final models = await _fetchModels();
    if (models == null || !mounted) return;
    final model = _current.model.text.trim();
    final found = models.contains(model) || models.contains('models/$model');
    _snack(
      found || models.isEmpty
          ? 'Kết nối thành công (${models.length} model).'
          : 'Kết nối thành công, nhưng không thấy model "$model" trong danh sách '
                '${models.length} model của máy chủ.',
    );
  }

  Future<void> _pickModel() async {
    var models = _current.fetchedModels;
    if (models.isEmpty) {
      models = await _fetchModels() ?? const [];
      if (!mounted) return;
    }
    final options = {..._provider.suggestedModels, ...models}.toList();
    if (options.isEmpty) {
      _snack('Không có danh sách model. Hãy gõ tên model trực tiếp.');
      return;
    }
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => _ModelPickerDialog(
        models: options,
        suggested: _provider.suggestedModels.toSet(),
        current: _current.model.text.trim(),
      ),
    );
    if (chosen != null) setState(() => _current.model.text = chosen);
  }

  bool _hasKey(AiProvider p) => _fields[p]!.key.text.trim().isNotEmpty;

  List<Widget> _artSection(TextStyle? titleStyle, TextStyle hintStyle) {
    final showOpenAi =
        _imageEngine == ImageEngine.auto || _imageEngine == ImageEngine.openai;
    final showGemini =
        _imageEngine == ImageEngine.auto || _imageEngine == ImageEngine.google;

    Widget keyStatus(AiProvider p) => Chip(
      avatar: Icon(
        _hasKey(p) ? Icons.check_circle_outline : Icons.error_outline,
        size: 18,
      ),
      label: Text(
        _hasKey(p)
            ? 'Đã có API key ${p.shortLabel}'
            : 'Chưa có API key ${p.shortLabel}',
      ),
    );

    Widget modelField(TextEditingController c, String label, String def) =>
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            controller: c,
            autocorrect: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: label,
              hintText: def,
              prefixIcon: const Icon(Icons.image_outlined),
            ),
          ),
        );

    return [
      Text('Vẽ lại tranh', style: titleStyle),
      const SizedBox(height: 6),
      Text(
        'Khi ảnh là tranh vẽ, ứng dụng dùng model tạo ảnh để vẽ lại tranh đẹp '
        '(giữ bố cục gốc). Không có model tạo ảnh thì ứng dụng vẽ bản vector.',
        style: hintStyle,
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<ImageEngine>(
        isExpanded: true,
        initialValue: _imageEngine,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.palette_outlined),
        ),
        items: [
          for (final e in ImageEngine.values)
            DropdownMenuItem(
              value: e,
              child: Text(e.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (e) => setState(() => _imageEngine = e ?? _imageEngine),
      ),
      if (showOpenAi || showGemini) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (showOpenAi) keyStatus(AiProvider.openai),
            if (showGemini) keyStatus(AiProvider.google),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Dùng chung API key đã nhập cho OpenAI / Google Gemini ở mục '
          '"Nhà cung cấp AI" phía trên (chọn nhà cung cấp đó để nhập key).',
          style: hintStyle,
        ),
      ],
      if (showOpenAi)
        modelField(
          _openAiImageCtrl,
          'Model tạo ảnh OpenAI',
          defaultOpenAiImageModel,
        ),
      if (showGemini)
        modelField(
          _geminiImageCtrl,
          'Model tạo ảnh Gemini',
          defaultGeminiImageModel,
        ),
      if (_imageEngine == ImageEngine.auto ||
          _imageEngine == ImageEngine.cloudflare)
        ..._cloudflareFields(hintStyle),
    ];
  }

  Future<void> _testCloudflare() async {
    final account = _cfAccountCtrl.text.trim();
    final token = _cfTokenCtrl.text.trim();
    if (!ImageBackend.isValidCloudflareAccountId(account) || token.isEmpty) {
      _snack('Hãy nhập Account ID (32 ký tự) và API token của Cloudflare.');
      return;
    }
    setState(() => _cfTesting = true);
    try {
      _snack(await ImageService.verifyCloudflare(account, token));
    } on AiException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Không kiểm tra được Cloudflare: $e');
    } finally {
      if (mounted) setState(() => _cfTesting = false);
    }
  }

  List<Widget> _cloudflareFields(TextStyle hintStyle) => [
    const SizedBox(height: 20),
    Text(
      'Cloudflare Workers AI (miễn phí ~90 ảnh/ngày)',
      style: Theme.of(context).textTheme.titleSmall,
    ),
    const SizedBox(height: 6),
    Text(
      '1) Đăng ký tài khoản miễn phí tại dash.cloudflare.com.\n'
      '2) Account ID: vào trang Workers AI (hoặc trang tổng quan tài khoản), '
      'sao chép "Account ID".\n'
      '3) API token: My Profile → API Tokens → Create Token → mẫu '
      '"Workers AI" → Create, rồi sao chép token.',
      style: hintStyle,
    ),
    Wrap(
      spacing: 4,
      children: [
        TextButton.icon(
          onPressed: () => launchUrl(
            Uri.parse(
              'https://dash.cloudflare.com/?to=/:account/ai/workers-ai',
            ),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Mở Workers AI'),
        ),
        TextButton.icon(
          onPressed: () => launchUrl(
            Uri.parse('https://dash.cloudflare.com/profile/api-tokens'),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Tạo API token'),
        ),
      ],
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _cfAccountCtrl,
      autocorrect: false,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        labelText: 'Account ID',
        hintText: '32 ký tự, ví dụ 0123456789abcdef0123456789abcdef',
        prefixIcon: Icon(Icons.badge_outlined),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _cfTokenCtrl,
      obscureText: _cfObscure,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: 'API token',
        prefixIcon: const Icon(Icons.key_outlined),
        suffixIcon: IconButton(
          icon: Icon(
            _cfObscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
          onPressed: () => setState(() => _cfObscure = !_cfObscure),
        ),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _cfModelCtrl,
      autocorrect: false,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        labelText: 'Model tạo ảnh Cloudflare',
        hintText: defaultCloudflareImageModel,
        prefixIcon: Icon(Icons.image_outlined),
      ),
    ),
    const SizedBox(height: 6),
    Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final m in cloudflareImageModels)
          ChoiceChip(
            label: Text(m.split('/').last),
            selected: _cfModelCtrl.text.trim() == m,
            onSelected: (_) => setState(() => _cfModelCtrl.text = m),
          ),
      ],
    ),
    const SizedBox(height: 6),
    Text(
      'flux-2-klein-4b: nhanh, ít tốn hạn mức nhất (khuyên dùng). '
      'flux-2-klein-9b / flux-2-dev: đẹp hơn nhưng tốn hạn mức hơn nhiều.',
      style: hintStyle,
    ),
    const SizedBox(height: 10),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: _cfTesting ? null : _testCloudflare,
        icon: _cfTesting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.wifi_tethering),
        label: const Text('Kiểm tra Cloudflare'),
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    final hintStyle = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    final f = _current;

    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('Nhà cung cấp AI', style: titleStyle),
              const SizedBox(height: 8),
              DropdownButtonFormField<AiProvider>(
                isExpanded: true,
                initialValue: _provider,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.hub_outlined),
                ),
                items: [
                  for (final p in AiProvider.values)
                    DropdownMenuItem(
                      value: p,
                      child: Text(p.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (p) => setState(() {
                  _provider = p ?? _provider;
                  _obscure = true;
                }),
              ),
              const SizedBox(height: 6),
              Text(
                'Mỗi nhà cung cấp lưu key và model riêng. '
                'Ứng dụng dùng nhà cung cấp đang chọn ở đây.',
                style: hintStyle,
              ),
              if (_provider.editableBaseUrl) ...[
                const SizedBox(height: 20),
                Text('Base URL', style: titleStyle),
                const SizedBox(height: 8),
                TextField(
                  controller: f.baseUrl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'https://example.com/v1',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Máy chủ tương thích OpenAI (gọi tới <Base URL>/chat/completions). '
                  'Model phải hỗ trợ đọc ảnh (vision).',
                  style: hintStyle,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in _customExamples.entries)
                      ActionChip(
                        label: Text(e.key),
                        onPressed: () =>
                            setState(() => f.baseUrl.text = e.value),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              Text('API key', style: titleStyle),
              const SizedBox(height: 8),
              TextField(
                controller: f.key,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: _provider.keyHint,
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
                'Key chỉ được lưu trên thiết bị này và gửi trực tiếp tới máy chủ '
                'của nhà cung cấp.',
                style: hintStyle,
              ),
              if (_provider.keyUrl.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse(_provider.keyUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(
                      'Lấy API key: ${Uri.parse(_provider.keyUrl).host}',
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Text('Model', style: titleStyle),
              const SizedBox(height: 8),
              TextField(
                controller: f.model,
                autocorrect: false,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: _provider.defaultModel.isEmpty
                      ? 'Tên model, ví dụ: openai/gpt-5, llava…'
                      : _provider.defaultModel,
                  prefixIcon: const Icon(Icons.memory_outlined),
                  suffixIcon: IconButton(
                    tooltip: 'Chọn từ danh sách',
                    icon: const Icon(Icons.list_alt_outlined),
                    onPressed: _testing ? null : _pickModel,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Gõ tên model bất kỳ, hoặc bấm biểu tượng danh sách để tải các model '
                'có sẵn từ máy chủ.',
                style: hintStyle,
              ),
              if (_provider.suggestedModels.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in _provider.suggestedModels)
                      ChoiceChip(
                        label: Text(m),
                        selected: f.model.text.trim() == m,
                        onSelected: (_) => setState(() => f.model.text = m),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('Kiểm tra kết nối'),
                ),
              ),
              const Divider(height: 40),
              ..._artSection(titleStyle, hintStyle),
              const Divider(height: 40),
              Text('Phong cách mặc định (không bắt buộc)', style: titleStyle),
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
                label: Text('Lưu & dùng ${_provider.shortLabel}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({
    required this.models,
    required this.suggested,
    required this.current,
  });

  final List<String> models;
  final Set<String> suggested;
  final String current;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final items = widget.models
        .where((m) => m.toLowerCase().contains(q))
        .toList();
    return AlertDialog(
      title: const Text('Chọn model'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 480,
        height: 460,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Tìm model…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final m = items[i];
                  return ListTile(
                    dense: true,
                    title: Text(m),
                    subtitle: widget.suggested.contains(m)
                        ? const Text('Gợi ý')
                        : null,
                    trailing: m == widget.current
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, m),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Huỷ'),
        ),
      ],
    );
  }
}
