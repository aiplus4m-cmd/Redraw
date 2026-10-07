import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/art_style.dart';
import 'ai/ai_provider.dart';
import 'ai/image_service.dart';

/// Persisted user settings: active AI provider, per-provider connection
/// settings and default style instructions.
class SettingsService extends ChangeNotifier {
  SettingsService._(this._prefs) {
    _migrateLegacy();
  }

  static const _kProvider = 'provider';
  static const _kInstructions = 'extra_instructions';
  static const _kImageEngine = 'image_engine';
  static const _kOpenAiImageModel = 'openai_image_model';
  static const _kGeminiImageModel = 'google_image_model';
  static const _kArtStyle = 'art_style';
  static const _kCfAccount = 'cloudflare_account_id';
  static const _kCfToken = 'cloudflare_api_token';
  static const _kCfModel = 'cloudflare_image_model';

  final SharedPreferences _prefs;

  static Future<SettingsService> load() async =>
      SettingsService._(await SharedPreferences.getInstance());

  static String _keyOf(AiProvider p) => '${p.name}_api_key';
  static String _modelOf(AiProvider p) => '${p.name}_model';
  static String _urlOf(AiProvider p) => '${p.name}_base_url';

  /// Version 1.0.0 stored a single Anthropic key under 'anthropic_api_key'
  /// (same key name as now) and the model under 'model'.
  void _migrateLegacy() {
    final legacyModel = _prefs.getString('model');
    if (legacyModel != null &&
        _prefs.getString(_modelOf(AiProvider.anthropic)) == null) {
      _prefs.setString(_modelOf(AiProvider.anthropic), legacyModel);
      _prefs.remove('model');
    }
  }

  AiProvider get provider => AiProvider.parse(_prefs.getString(_kProvider));

  ProviderConfig configFor(AiProvider p) => ProviderConfig(
    provider: p,
    apiKey: _prefs.getString(_keyOf(p)) ?? '',
    model: _prefs.getString(_modelOf(p)) ?? p.defaultModel,
    baseUrl: _prefs.getString(_urlOf(p)) ?? p.defaultBaseUrl,
  );

  ProviderConfig get activeConfig => configFor(provider);

  /// Extra style instructions appended to every request (optional).
  String get extraInstructions => _prefs.getString(_kInstructions) ?? '';

  bool get isReady => activeConfig.problem == null;

  // ------------------------------------------------------------ artwork

  ImageEngine get imageEngine =>
      ImageEngine.parse(_prefs.getString(_kImageEngine));

  String get openAiImageModel =>
      _nonEmpty(_prefs.getString(_kOpenAiImageModel), defaultOpenAiImageModel);

  String get geminiImageModel =>
      _nonEmpty(_prefs.getString(_kGeminiImageModel), defaultGeminiImageModel);

  ArtStyle get artStyle => ArtStyle.parse(_prefs.getString(_kArtStyle));

  String get cloudflareAccountId => _prefs.getString(_kCfAccount) ?? '';
  String get cloudflareToken => _prefs.getString(_kCfToken) ?? '';
  String get cloudflareImageModel =>
      _nonEmpty(_prefs.getString(_kCfModel), defaultCloudflareImageModel);

  static String _nonEmpty(String? v, String fallback) =>
      (v == null || v.trim().isEmpty) ? fallback : v.trim();

  ImageBackend? _backendFor(AiProvider p) {
    final config = configFor(p);
    if (config.apiKey.trim().isEmpty) return null;
    return ImageBackend.fromProvider(
      config,
      p == AiProvider.google ? geminiImageModel : openAiImageModel,
    );
  }

  ImageBackend? get _cloudflareBackend {
    if (cloudflareToken.trim().isEmpty ||
        !ImageBackend.isValidCloudflareAccountId(cloudflareAccountId)) {
      return null;
    }
    return ImageBackend(
      kind: ImageBackendKind.cloudflare,
      apiKey: cloudflareToken.trim(),
      model: cloudflareImageModel,
      accountId: cloudflareAccountId.trim(),
    );
  }

  /// The image-generation back-end used to repaint artwork, or null when
  /// only the vector redraw is available.
  ImageBackend? get imageBackend => switch (imageEngine) {
    ImageEngine.openai => _backendFor(AiProvider.openai),
    ImageEngine.google => _backendFor(AiProvider.google),
    ImageEngine.cloudflare => _cloudflareBackend,
    ImageEngine.vector => null,
    ImageEngine.auto =>
      _backendFor(AiProvider.openai) ??
          _backendFor(AiProvider.google) ??
          _cloudflareBackend,
  };

  Future<void> saveArtStyle(ArtStyle style) async {
    await _prefs.setString(_kArtStyle, style.name);
    notifyListeners();
  }

  Future<void> save({
    required AiProvider active,
    required Map<AiProvider, ProviderConfig> configs,
    required String extraInstructions,
    ImageEngine? imageEngine,
    String? openAiImageModel,
    String? geminiImageModel,
    String? cloudflareAccountId,
    String? cloudflareToken,
    String? cloudflareImageModel,
  }) async {
    if (cloudflareAccountId != null) {
      await _prefs.setString(_kCfAccount, cloudflareAccountId.trim());
    }
    if (cloudflareToken != null) {
      await _prefs.setString(_kCfToken, cloudflareToken.trim());
    }
    if (cloudflareImageModel != null) {
      await _prefs.setString(_kCfModel, cloudflareImageModel.trim());
    }
    if (imageEngine != null) {
      await _prefs.setString(_kImageEngine, imageEngine.name);
    }
    if (openAiImageModel != null) {
      await _prefs.setString(_kOpenAiImageModel, openAiImageModel.trim());
    }
    if (geminiImageModel != null) {
      await _prefs.setString(_kGeminiImageModel, geminiImageModel.trim());
    }
    await _prefs.setString(_kProvider, active.name);
    for (final c in configs.values) {
      await _prefs.setString(_keyOf(c.provider), c.apiKey.trim());
      await _prefs.setString(_modelOf(c.provider), c.model.trim());
      await _prefs.setString(_urlOf(c.provider), c.baseUrl.trim());
    }
    await _prefs.setString(_kInstructions, extraInstructions.trim());
    notifyListeners();
  }
}
