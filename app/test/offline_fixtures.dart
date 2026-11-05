import 'dart:convert';
import 'dart:typed_data';

import 'package:bookalog_catalog/catalog.dart';
import 'package:bookalog_catalog/offline_cache.dart';
import 'package:cryptography/cryptography.dart';

const offlineTestSubject = '00000000-0000-4000-8000-000000000002';
const offlineTestIssuer = 'https://catalog.example.test';

class MemoryOfflineStorage implements OfflineCacheStorage {
  final protected = <String, String>{};
  final files = <String, Uint8List>{};

  @override
  Future<String?> readProtected(String key) async => protected[key];
  @override
  Future<void> writeProtected(String key, String value) async =>
      protected[key] = value;
  @override
  Future<void> deleteProtected(String key) async => protected.remove(key);
  @override
  Future<Uint8List?> readFile(String name) async =>
      files[name] == null ? null : Uint8List.fromList(files[name]!);
  @override
  Future<void> writeFile(String name, Uint8List bytes) async =>
      files[name] = Uint8List.fromList(bytes);
  @override
  Future<void> deleteFile(String name) async => files.remove(name);
}

class OfflineFixture {
  OfflineFixture._(this.now);
  final DateTime Function() now;
  final storage = MemoryOfflineStorage();
  late final SimpleKeyPair _keyPair;
  late final String publicKey;
  late final OfflineCatalogCache cache;
  late final String token;

  static Future<OfflineFixture> create({
    required DateTime Function() now,
    CatalogRole role = CatalogRole.viewer,
  }) async {
    final fixture = OfflineFixture._(now);
    fixture._keyPair = await Ed25519().newKeyPair();
    fixture.publicKey = base64Url.encode(
      (await fixture._keyPair.extractPublicKey()).bytes,
    );
    fixture.cache = OfflineCatalogCache(
      issuer: offlineTestIssuer,
      publicKey: fixture.publicKey,
      storage: fixture.storage,
      now: now,
    );
    fixture.token = await fixture.tokenFor(role: role);
    return fixture;
  }

  Future<String> tokenFor({
    String subject = offlineTestSubject,
    CatalogRole role = CatalogRole.viewer,
    Duration lifetime = const Duration(hours: 24),
  }) async {
    final issued = now().millisecondsSinceEpoch ~/ 1000;
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'issuer': offlineTestIssuer,
        'subject': subject,
        'role': role.name,
        'issued_at': issued,
        'expires_at': issued + lifetime.inSeconds,
        'nonce': '00000000-0000-4000-8000-000000000001',
      }),
    );
    final signature = await Ed25519().sign(bytes, keyPair: _keyPair);
    return '${base64Url.encode(bytes)}.${base64Url.encode(signature.bytes)}';
  }
}
