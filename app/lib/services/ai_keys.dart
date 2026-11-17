// API keys of the AI services used for singing advice. They live in the
// system's secret storage, never in the settings file, the logs or a
// problem report:
//  - macOS: the login keychain, encrypted with the login password; another
//    app has to ask the user before it can read the item.
//  - Windows: an AES-GCM encrypted file in the app's support folder whose
//    key is in the Credential Manager. This protects against other Windows
//    accounts and a copied disk, not against a program run by the same user.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class AiKeyStore {
  /// The key saved for [provider] ('claude' or 'openai'), or null.
  Future<String?> read(String provider);

  /// Saves [key] for [provider]; null or empty removes it.
  Future<void> write(String provider, String? key);
}

class SecureAiKeyStore implements AiKeyStore {
  // The data protection keychain needs a keychain-access-groups entitlement,
  // which an ad-hoc signed build does not have; the login keychain works.
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  static String _name(String provider) => 'ai_api_key_$provider';

  @override
  Future<String?> read(String provider) async {
    final v = await _storage.read(key: _name(provider));
    return v == null || v.trim().isEmpty ? null : v.trim();
  }

  @override
  Future<void> write(String provider, String? key) async {
    final v = key?.trim() ?? '';
    if (v.isEmpty) {
      await _storage.delete(key: _name(provider));
    } else {
      await _storage.write(key: _name(provider), value: v);
    }
  }
}

/// In memory, for tests.
class MemoryAiKeyStore implements AiKeyStore {
  final Map<String, String> keys = {};

  @override
  Future<String?> read(String provider) async => keys[provider];

  @override
  Future<void> write(String provider, String? key) async {
    final v = key?.trim() ?? '';
    v.isEmpty ? keys.remove(provider) : keys[provider] = v;
  }
}
