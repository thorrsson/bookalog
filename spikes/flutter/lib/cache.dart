import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'catalog.dart';

final cipher = AesGcm.with256bits();
const account = 'synthetic-comparison';
const keyName = 'bookalog-flutter-spike-key';
const storage = FlutterSecureStorage();

Future<String> seal(String plaintext, SecretKey key) async {
  final box = await cipher.encrypt(
    utf8.encode(plaintext),
    secretKey: key,
    aad: utf8.encode(account),
  );
  return jsonEncode({
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'mac': base64Encode(box.mac.bytes),
  });
}

Future<String> unseal(String envelope, SecretKey key) async {
  final value = jsonDecode(envelope) as Map<String, dynamic>;
  final box = SecretBox(
    base64Decode(value['ciphertext'] as String),
    nonce: base64Decode(value['nonce'] as String),
    mac: Mac(base64Decode(value['mac'] as String)),
  );
  return utf8.decode(
    await cipher.decrypt(box, secretKey: key, aad: utf8.encode(account)),
  );
}

Future<File> cacheFile() async => File(
  '${(await getApplicationSupportDirectory()).path}/synthetic-cache.enc',
);

Future<void> saveSyntheticCache(String catalog) async {
  final existing = await storage.read(key: keyName);
  final key = existing == null
      ? await cipher.newSecretKey()
      : SecretKey(base64Decode(existing));
  final now = DateTime.now().millisecondsSinceEpoch;
  final plaintext = jsonEncode({'savedAt': now, 'catalog': catalog});
  final envelope = await seal(plaintext, key);
  final file = await cacheFile();
  await file.parent.create(recursive: true);
  await storage.write(
    key: keyName,
    value: base64Encode(await key.extractBytes()),
  );
  await storage.write(key: '$keyName-clock', value: '$now');
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(envelope, flush: true);
  await temporary.rename(file.path);
}

Future<String> readSyntheticCache() async {
  final encoded = await storage.read(key: keyName);
  final lastSeen = int.tryParse(
    await storage.read(key: '$keyName-clock') ?? '',
  );
  if (encoded == null || lastSeen == null) {
    throw StateError(
      'No protected cache key. Save the synthetic fixture first.',
    );
  }
  final plaintext = await unseal(
    await (await cacheFile()).readAsString(),
    SecretKey(base64Decode(encoded)),
  );
  final value = jsonDecode(plaintext) as Map<String, dynamic>;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (!canReadOffline(
    verifiedAt: value['savedAt'] as int,
    now: now,
    lastSeenAt: lastSeen,
    accountMatches: true,
    revoked: false,
  )) {
    throw StateError(
      'The test cache expired or the device clock moved backward.',
    );
  }
  await storage.write(key: '$keyName-clock', value: '$now');
  return value['catalog'] as String;
}

Future<void> clearSyntheticCache() async {
  await storage.delete(key: keyName);
  await storage.delete(key: '$keyName-clock');
  final file = await cacheFile();
  if (await file.exists()) await file.delete();
  final temporary = File('${file.path}.tmp');
  if (await temporary.exists()) await temporary.delete();
}
