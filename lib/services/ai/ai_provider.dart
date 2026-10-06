/// AI back-ends the app can use.
enum AiProvider {
  anthropic(
    label: 'Anthropic Claude',
    shortLabel: 'Claude',
    defaultModel: 'claude-opus-5-5',
    suggestedModels: [
      'claude-opus-5-5',
      'claude-sonnet-5-5',
      'claude-fable-5-1',
    ],
    keyHint: 'sk-ant-…',
    keyUrl: 'https://console.anthropic.com/settings/keys',
    defaultBaseUrl: 'https://api.anthropic.com/v1',
  ),
  google(
    label: 'Google Gemini',
    shortLabel: 'Gemini',
    defaultModel: 'gemini-pro-latest',
    suggestedModels: [
      'gemini-pro-latest',
      'gemini-flash-latest',
      'gemini-3.1-pro-preview',
      'gemini-3.5-flash',
    ],
    keyHint: 'AIza…',
    keyUrl: 'https://aistudio.google.com/apikey',
    defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  ),
  openai(
    label: 'OpenAI',
    shortLabel: 'OpenAI',
    defaultModel: 'gpt-5',
    suggestedModels: ['gpt-5', 'gpt-5-mini', 'chat-latest'],
    keyHint: 'sk-…',
    keyUrl: 'https://platform.openai.com/api-keys',
    defaultBaseUrl: 'https://api.openai.com/v1',
  ),
  custom(
    label: 'Custom API (tương thích OpenAI)',
    shortLabel: 'Custom',
    defaultModel: '',
    suggestedModels: [],
    keyHint: 'API key (bỏ trống nếu máy chủ không yêu cầu)',
    keyUrl: '',
    defaultBaseUrl: '',
  );

  const AiProvider({
    required this.label,
    required this.shortLabel,
    required this.defaultModel,
    required this.suggestedModels,
    required this.keyHint,
    required this.keyUrl,
    required this.defaultBaseUrl,
  });

  final String label;
  final String shortLabel;
  final String defaultModel;
  final List<String> suggestedModels;
  final String keyHint;
  final String keyUrl;
  final String defaultBaseUrl;

  /// Custom endpoints may run without authentication (e.g. a local server).
  bool get requiresKey => this != AiProvider.custom;

  /// Only the custom provider lets the user change the base URL.
  bool get editableBaseUrl => this == AiProvider.custom;

  static AiProvider parse(String? name) => AiProvider.values.firstWhere(
    (p) => p.name == name,
    orElse: () => AiProvider.anthropic,
  );
}

/// Connection settings for one provider.
class ProviderConfig {
  const ProviderConfig({
    required this.provider,
    required this.apiKey,
    required this.model,
    required this.baseUrl,
  });

  final AiProvider provider;
  final String apiKey;
  final String model;
  final String baseUrl;

  /// Base URL without a trailing slash.
  String get normalizedBaseUrl {
    var url = (baseUrl.trim().isEmpty ? provider.defaultBaseUrl : baseUrl)
        .trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Returns a Vietnamese error message if the config can't be used yet.
  String? get problem {
    if (provider.requiresKey && apiKey.trim().isEmpty) {
      return 'Chưa nhập API key cho ${provider.label}.';
    }
    if (model.trim().isEmpty) {
      return 'Chưa nhập tên model cho ${provider.label}.';
    }
    if (provider == AiProvider.custom) {
      final uri = Uri.tryParse(baseUrl.trim());
      if (baseUrl.trim().isEmpty ||
          uri == null ||
          !uri.hasScheme ||
          uri.host.isEmpty) {
        return 'Base URL của Custom API chưa hợp lệ (ví dụ: https://openrouter.ai/api/v1).';
      }
    }
    return null;
  }
}
