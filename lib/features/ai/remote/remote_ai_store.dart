import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_ai_config.dart';

/// Which engine answers Ask + refines scans: the on-device GGUF or the user's
/// configured cloud model. `local` is the privacy-first default; `remote` is the
/// opt-in escape hatch.
enum AiEngine { local, remote }

/// Persists the optional cloud-model config and which engine is active. The API
/// key is a secret and lives in Keystore-backed [FlutterSecureStorage]; the
/// provider, base URL, model id and flags live in [SharedPreferences].
class RemoteAiStore {
  RemoteAiStore({FlutterSecureStorage? secure})
      : _secure = secure ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;

  // Last successfully read API key, cached for the process, so one transient
  // keystore failure can't flip remoteActive() to false mid-scan.
  String? _cachedKey;
  var _keyCached = false;

  static const _keyApiKey = 'cura_cloud_api_key'; // secure storage
  static const _keyProvider = 'cura_cloud_provider'; // prefs
  static const _keyBaseUrl = 'cura_cloud_base_url'; // prefs
  static const _keyModelId = 'cura_cloud_model_id'; // prefs
  static const _keyEngine = 'cura_active_engine'; // prefs: 'local' | 'remote'
  static const _keyConsented = 'cura_cloud_consented'; // prefs

  /// Reads the saved cloud config (key from secure storage, rest from prefs).
  /// Returns a blank OpenRouter-seeded config when nothing is saved yet.
  Future<RemoteAiConfig> config() async {
    final prefs = await SharedPreferences.getInstance();
    final providerId = prefs.getString(_keyProvider);
    final base = providerById(providerId);
    final key = await _readKey();
    return RemoteAiConfig(
      providerId: base.id,
      baseUrl: prefs.getString(_keyBaseUrl) ?? base.baseUrl,
      apiKey: key ?? '',
      modelId: prefs.getString(_keyModelId) ?? '',
    );
  }

  /// Saves [config]. The key goes to secure storage (or is deleted when blank);
  /// everything else to prefs. Does **not** change the active engine — enabling
  /// is a separate, explicit step ([setEngine]).
  Future<void> saveConfig(RemoteAiConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyProvider, config.providerId);
    await prefs.setString(_keyBaseUrl, config.baseUrl.trim());
    await prefs.setString(_keyModelId, config.modelId.trim());
    final key = config.apiKey.trim();
    if (key.isEmpty) {
      await _secure.delete(key: _keyApiKey);
    } else {
      await _secure.write(key: _keyApiKey, value: key);
    }
    // Keep the in-memory cache authoritative after an explicit write.
    _cachedKey = key.isEmpty ? null : key;
    _keyCached = true;
  }

  /// The active engine. Defaults to [AiEngine.local] — cloud is never on unless
  /// the user turned it on.
  Future<AiEngine> engine() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyEngine) == 'remote'
        ? AiEngine.remote
        : AiEngine.local;
  }

  /// Switches the active engine. Guarded by the caller: the UI only allows
  /// [AiEngine.remote] once the config is complete and consent was given.
  Future<void> setEngine(AiEngine value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _keyEngine, value == AiEngine.remote ? 'remote' : 'local');
  }

  /// True when the cloud engine is active **and** its config is usable. The
  /// service uses this to decide whether to hit the network or the local model.
  Future<bool> remoteActive() async {
    if (await engine() != AiEngine.remote) return false;
    return (await config()).isComplete;
  }

  /// Whether the user has acknowledged the one-time "your text leaves this
  /// device" consent. Enabling the cloud engine requires it.
  Future<bool> consented() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyConsented) ?? false;
  }

  Future<void> setConsented(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyConsented, value);
  }

  /// Clears the cloud config entirely and reverts to the on-device engine —
  /// used by "disconnect" and folded into the app-wide "Delete all data".
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await _secure.delete(key: _keyApiKey);
    await prefs.remove(_keyProvider);
    await prefs.remove(_keyBaseUrl);
    await prefs.remove(_keyModelId);
    await prefs.remove(_keyConsented);
    await prefs.setString(_keyEngine, 'local');
    _cachedKey = null;
    _keyCached = true; // known-empty, not unknown
  }

  Future<String?> _readKey() async {
    // The keystore read can throw transiently, so retry a few times and fall
    // back to the cached key. An unset key returns null without throwing, so
    // on-device users pay nothing here.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final value = await _secure.read(key: _keyApiKey);
        _cachedKey = value;
        _keyCached = true;
        return value;
      } catch (_) {
        if (_keyCached) return _cachedKey; // trust last known good
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    return _keyCached ? _cachedKey : null;
  }
}
