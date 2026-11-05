import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SecureSupabaseLocalStorage extends LocalStorage {
  SecureSupabaseLocalStorage({required String issuer, this.onSessionRemoved})
    : _sessionKey = 'bookalog.auth.${base64Url.encode(utf8.encode(issuer))}';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final String _sessionKey;
  final Future<void> Function()? onSessionRemoved;

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() => _storage.read(key: _sessionKey);

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: _sessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _sessionKey, value: persistSessionString);

  @override
  Future<void> removePersistedSession() async {
    await _storage.delete(key: _sessionKey);
    await onSessionRemoved?.call();
  }
}
