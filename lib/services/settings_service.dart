import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Models offered in the settings screen.
const availableModels = <String, String>{
  'claude-opus-5-5': 'Claude Opus 5.5 (khuyên dùng)',
  'claude-sonnet-5-5': 'Claude Sonnet 5.5 (nhanh, rẻ hơn)',
  'claude-fable-5-1': 'Claude Fable 5.1 (mạnh nhất)',
};

const defaultModel = 'claude-opus-5-5';

/// Persisted user settings (API key, model, export preferences).
class SettingsService extends ChangeNotifier {
  SettingsService._(this._prefs);

  static const _kApiKey = 'anthropic_api_key';
  static const _kModel = 'model';
  static const _kInstructions = 'extra_instructions';

  final SharedPreferences _prefs;

  static Future<SettingsService> load() async =>
      SettingsService._(await SharedPreferences.getInstance());

  String get apiKey => _prefs.getString(_kApiKey) ?? '';
  String get model {
    final m = _prefs.getString(_kModel) ?? defaultModel;
    return availableModels.containsKey(m) ? m : defaultModel;
  }

  /// Extra style instructions appended to every request (optional).
  String get extraInstructions => _prefs.getString(_kInstructions) ?? '';

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  Future<void> save({
    required String apiKey,
    required String model,
    required String extraInstructions,
  }) async {
    await _prefs.setString(_kApiKey, apiKey.trim());
    await _prefs.setString(_kModel, model);
    await _prefs.setString(_kInstructions, extraInstructions.trim());
    notifyListeners();
  }
}
