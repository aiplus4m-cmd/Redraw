import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai/ai_provider.dart';

/// Persisted user settings: active AI provider, per-provider connection
/// settings and default style instructions.
class SettingsService extends ChangeNotifier {
  SettingsService._(this._prefs) {
    _migrateLegacy();
  }

  static const _kProvider = 'provider';
  static const _kInstructions = 'extra_instructions';

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

  Future<void> save({
    required AiProvider active,
    required Map<AiProvider, ProviderConfig> configs,
    required String extraInstructions,
  }) async {
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
