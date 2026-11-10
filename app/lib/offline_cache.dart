import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'catalog.dart';

const maximumOfflineBytes = 32 * 1024 * 1024;

class OfflineAccessUnavailable implements Exception {
  const OfflineAccessUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class OfflineLease {
  const OfflineLease({
    required this.token,
    required this.subject,
    required this.role,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String token;
  final String subject;
  final CatalogRole role;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

class OfflineLeaseVerifier {
  OfflineLeaseVerifier({required this.issuer, required String publicKey})
    : _publicKey = SimplePublicKey(
        base64Url.decode(base64Url.normalize(publicKey)),
        type: KeyPairType.ed25519,
      ) {
    if (_publicKey.bytes.length != 32) {
      throw const FormatException(
        'The offline verification key must be 32 bytes.',
      );
    }
  }

  final String issuer;
  final SimplePublicKey _publicKey;

  Future<OfflineLease> verify(
    String token,
    String subject,
    DateTime now,
  ) async {
    final parts = token.split('.');
    if (token.length > 8192 || parts.length != 2) {
      throw const FormatException('The offline lease is malformed.');
    }
    final payload = base64Url.decode(base64Url.normalize(parts[0]));
    final signature = base64Url.decode(base64Url.normalize(parts[1]));
    if (signature.length != 64 ||
        !await Ed25519().verify(
          payload,
          signature: Signature(signature, publicKey: _publicKey),
        )) {
      throw const FormatException('The offline lease signature is invalid.');
    }
    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map<String, dynamic> ||
        claims['version'] != 1 ||
        claims['issuer'] != issuer ||
        claims['subject'] != subject ||
        claims['issued_at'] is! int ||
        claims['expires_at'] is! int ||
        claims['nonce'] is! String ||
        !RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
            .hasMatch(claims['nonce'] as String)) {
      throw const FormatException(
        'The offline lease does not match this account and project.',
      );
    }
    final issued = claims['issued_at'] as int;
    final expires = claims['expires_at'] as int;
    if (issued < 0 ||
        expires - issued != 86400 ||
        issued * 1000 > now.millisecondsSinceEpoch + 60000 ||
        expires * 1000 <= now.millisecondsSinceEpoch) {
      throw const OfflineAccessUnavailable(
        'Offline access expired or the device clock is incorrect. Reconnect to verify membership.',
      );
    }
    return OfflineLease(
      token: token,
      subject: subject,
      role: CatalogRole.parse(claims['role']),
      issuedAt: DateTime.fromMillisecondsSinceEpoch(issued * 1000, isUtc: true),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expires * 1000,
        isUtc: true,
      ),
    );
  }
}

class OfflineCatalogEntry {
  OfflineCatalogEntry({
    required this.snapshot,
    required this.lease,
    required DateTime openedAt,
  }) : _lastObserved = openedAt,
       _allowance = lease.expiresAt.difference(
         openedAt.isBefore(lease.issuedAt) ? lease.issuedAt : openedAt,
       );

  final CatalogSnapshot snapshot;
  final OfflineLease lease;
  final Stopwatch _elapsed = Stopwatch()..start();
  final Duration _allowance;
  DateTime _lastObserved;
  bool _clockRolledBack = false;

  bool isUsable(DateTime now) {
    if (now.isBefore(_lastObserved)) _clockRolledBack = true;
    _lastObserved = now;
    return !_clockRolledBack &&
        now.isBefore(lease.expiresAt) &&
        _elapsed.elapsed < _allowance;
  }
}

abstract interface class OfflineCacheStorage {
  Future<String?> readProtected(String key);
  Future<void> writeProtected(String key, String value);
  Future<void> deleteProtected(String key);
  Future<Uint8List?> readFile(String name);
  Future<void> writeFile(String name, Uint8List bytes);
  Future<void> deleteFile(String name);
}

class DeviceOfflineCacheStorage implements OfflineCacheStorage {
  const DeviceOfflineCacheStorage();
  static const _protected = FlutterSecureStorage();

  @override
  Future<String?> readProtected(String key) => _protected.read(key: key);
  @override
  Future<void> writeProtected(String key, String value) =>
      _protected.write(key: key, value: value);
  @override
  Future<void> deleteProtected(String key) => _protected.delete(key: key);

  Future<File> _file(String name) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(name)) {
      throw const FormatException('Invalid offline cache filename.');
    }
    return File(
      '${(await getApplicationSupportDirectory()).path}/offline/$name.enc',
    );
  }

  @override
  Future<Uint8List?> readFile(String name) async {
    final file = await _file(name);
    if (!await file.exists()) return null;
    if (await file.length() > maximumOfflineBytes) {
      throw const FormatException(
        'The saved catalog exceeds the offline size limit.',
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maximumOfflineBytes) {
      throw const FormatException(
        'The saved catalog exceeds the offline size limit.',
      );
    }
    return bytes;
  }

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {
    final file = await _file(name);
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.pending');
    await pending.writeAsBytes(bytes, flush: true);
    await pending.rename(file.path);
  }

  @override
  Future<void> deleteFile(String name) async {
    final file = await _file(name);
    if (await file.exists()) await file.delete();
    final pending = File('${file.path}.pending');
    if (await pending.exists()) await pending.delete();
  }
}

class OfflineCatalogCache {
  OfflineCatalogCache({
    required String issuer,
    required String publicKey,
    required this.storage,
    DateTime Function()? now,
  }) : verifier = OfflineLeaseVerifier(issuer: issuer, publicKey: publicKey),
       _now = now ?? DateTime.now;

  final OfflineLeaseVerifier verifier;
  final OfflineCacheStorage storage;
  final DateTime Function() _now;
  final _cipher = AesGcm.with256bits();
  Future<void> _pending = Future.value();
  int _generation = 0;
  int get generation => _generation;
  String get _activeKey =>
      'bookalog.offline.active.${base64Url.encode(utf8.encode(verifier.issuer))}';

  Future<T> _serial<T>(Future<T> Function() action) async {
    final previous = _pending;
    final done = Completer<void>();
    _pending = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<String> _name(String subject) async =>
      (await Sha256().hash(utf8.encode('${verifier.issuer}\n$subject'))).bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();

  Future<String> _digest(List<int> bytes) async =>
      base64Encode((await Sha256().hash(bytes)).bytes);

  Future<Map<String, dynamic>?> _manifest(String name) async {
    final raw = await storage.readProtected('bookalog.offline.$name');
    if (raw == null) return null;
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value['key'] is! String ||
        value['digest'] is! String ||
        value['last_seen'] is! int) {
      throw const FormatException(
        'The protected offline cache metadata is invalid.',
      );
    }
    return value;
  }

  void _checkClock(Map<String, dynamic>? manifest, DateTime now) {
    if (manifest != null &&
        now.millisecondsSinceEpoch < (manifest['last_seen'] as int)) {
      throw const OfflineAccessUnavailable(
        'The device clock moved backward. Reconnect before using the saved catalog.',
      );
    }
  }

  Future<OfflineCatalogEntry> save({
    required String subject,
    required CatalogSnapshot snapshot,
    required String leaseToken,
    required int generation,
  }) => _serial(() async {
    if (generation != _generation) {
      throw StateError('Offline save cancelled because the account changed.');
    }
    final now = _now();
    final lease = await verifier.verify(leaseToken, subject, now);
    if (lease.role != snapshot.role) {
      throw const CatalogAccessDenied(
        'Membership changed while preparing offline access.',
      );
    }
    final name = await _name(subject);
    _checkClock(await _manifest(name), now);
    final plaintext = utf8.encode(
      jsonEncode({
        'version': 1,
        'lease': leaseToken,
        'records': snapshot.editions.map((edition) => edition.record).toList(),
      }),
    );
    if (snapshot.editions.map((edition) => edition.id).toSet().length !=
        snapshot.editions.length) {
      throw const FormatException('The catalog contains duplicate editions.');
    }
    if (snapshot.editions.length > 10000 ||
        plaintext.length + 28 > maximumOfflineBytes) {
      throw const FormatException(
        'This catalog exceeds the 32 MiB offline limit.',
      );
    }
    final key = await _cipher.newSecretKey();
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: key,
      aad: utf8.encode('${verifier.issuer}\n$subject'),
    );
    final bytes = Uint8List.fromList(box.concatenation());
    final previousSubject = await storage.readProtected(_activeKey);
    if (previousSubject != null && previousSubject != subject) {
      await _clearSubject(previousSubject);
    }
    if (generation != _generation) {
      throw StateError('Offline save cancelled because the account changed.');
    }
    await storage.writeProtected(_activeKey, subject);
    await storage.writeFile(name, bytes);
    await storage.writeProtected(
      'bookalog.offline.$name',
      jsonEncode({
        'key': base64Encode(await key.extractBytes()),
        'digest': await _digest(bytes),
        'last_seen': now.millisecondsSinceEpoch,
      }),
    );
    return OfflineCatalogEntry(snapshot: snapshot, lease: lease, openedAt: now);
  });

  Future<OfflineCatalogEntry?> read(String subject) => _serial(() async {
    final name = await _name(subject);
    final manifest = await _manifest(name);
    if (manifest == null) return null;
    final now = _now();
    _checkClock(manifest, now);
    final bytes = await storage.readFile(name);
    if (bytes == null ||
        bytes.length < 28 ||
        bytes.length > maximumOfflineBytes ||
        await _digest(bytes) != manifest['digest']) {
      throw const FormatException(
        'The saved catalog is missing, damaged, or an older copy.',
      );
    }
    final keyBytes = base64Decode(manifest['key'] as String);
    if (keyBytes.length != 32) {
      throw const FormatException('The protected cache key is invalid.');
    }
    final plaintext = await _cipher.decrypt(
      SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
      secretKey: SecretKey(keyBytes),
      aad: utf8.encode('${verifier.issuer}\n$subject'),
    );
    final value = jsonDecode(utf8.decode(plaintext));
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['lease'] is! String ||
        value['records'] is! List ||
        (value['records'] as List).length > 10000) {
      throw const FormatException('The saved catalog format is invalid.');
    }
    final lease = await verifier.verify(value['lease'] as String, subject, now);
    final editions = (value['records'] as List)
        .map(CatalogEdition.fromRecord)
        .toList();
    if (editions.map((edition) => edition.id).toSet().length !=
        editions.length) {
      throw const FormatException(
        'The saved catalog contains duplicate editions.',
      );
    }
    await storage.writeProtected(
      'bookalog.offline.$name',
      jsonEncode({...manifest, 'last_seen': now.millisecondsSinceEpoch}),
    );
    return OfflineCatalogEntry(
      snapshot: CatalogSnapshot(
        role: lease.role,
        editions: List.unmodifiable(editions),
      ),
      lease: lease,
      openedAt: now,
    );
  });

  Future<void> recordUse(String subject) => _serial(() async {
    final name = await _name(subject);
    final manifest = await _manifest(name);
    if (manifest == null) return;
    final now = _now();
    _checkClock(manifest, now);
    await storage.writeProtected(
      'bookalog.offline.$name',
      jsonEncode({...manifest, 'last_seen': now.millisecondsSinceEpoch}),
    );
  });

  Future<void> _clearSubject(String subject) async {
    final name = await _name(subject);
    await storage.deleteProtected('bookalog.offline.$name');
    await storage.deleteFile(name);
  }

  Future<void> clearAll() {
    _generation++;
    return _serial(() async {
      final subject = await storage.readProtected(_activeKey);
      if (subject != null) await _clearSubject(subject);
      await storage.deleteProtected(_activeKey);
    });
  }
}
