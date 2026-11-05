import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bookalog_catalog/catalog.dart';
import 'package:bookalog_catalog/offline_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'offline_fixtures.dart';
import 'widget_test.dart' show editionRecord;

void main() {
  late DateTime now;
  late OfflineFixture fixture;
  late CatalogSnapshot snapshot;

  setUp(() async {
    now = DateTime.utc(2030);
    fixture = await OfflineFixture.create(now: () => now);
    snapshot = CatalogSnapshot(
      role: CatalogRole.viewer,
      editions: [CatalogEdition.fromRecord(editionRecord())],
    );
  });

  Future<OfflineCatalogEntry> save([CatalogSnapshot? value]) =>
      fixture.cache.save(
        subject: offlineTestSubject,
        snapshot: value ?? snapshot,
        leaseToken: fixture.token,
        generation: fixture.cache.generation,
      );

  test('Dart verifies a real server-produced Ed25519 lease', () async {
    final path = Platform.environment['BOOKALOG_LEASE_TEST_VECTOR'];
    expect(path, isNotNull, reason: 'Run tests through script/test-app.sh.');
    final vector =
        jsonDecode(await File(path!).readAsString()) as Map<String, dynamic>;
    final verifier = OfflineLeaseVerifier(
      issuer: vector['issuer'] as String,
      publicKey: vector['publicKey'] as String,
    );
    final lease = await verifier.verify(
      vector['lease'] as String,
      vector['subject'] as String,
      DateTime.fromMillisecondsSinceEpoch(vector['now'] as int, isUtc: true),
    );
    expect(lease.role, CatalogRole.viewer);
    expect(
      lease.expiresAt.difference(lease.issuedAt),
      const Duration(hours: 24),
    );
  });

  test(
    'encrypted catalog survives a restart and contains no plaintext title',
    () async {
      await save();
      expect(
        utf8.decode(fixture.storage.files.values.single, allowMalformed: true),
        isNot(contains('The Quiet Atlas')),
      );
      final restarted = OfflineCatalogCache(
        issuer: offlineTestIssuer,
        publicKey: fixture.publicKey,
        storage: fixture.storage,
        now: () => now,
      );
      final restored = await restarted.read(offlineTestSubject);
      expect(restored!.snapshot.editions.single.title, 'The Quiet Atlas');
      expect(restored.lease.role, CatalogRole.viewer);
      expect(await restarted.read('another-user'), isNull);
    },
  );

  test(
    'signature, account binding and the exact expiry are enforced',
    () async {
      final verifier = fixture.cache.verifier;
      await expectLater(
        verifier.verify(
          'X${fixture.token.substring(1)}',
          offlineTestSubject,
          now,
        ),
        throwsFormatException,
      );
      await expectLater(
        verifier.verify(fixture.token, 'another-user', now),
        throwsFormatException,
      );
      await expectLater(
        verifier.verify(
          await fixture.tokenFor(lifetime: const Duration(hours: 25)),
          offlineTestSubject,
          now,
        ),
        throwsA(isA<OfflineAccessUnavailable>()),
      );
      await save();
      now = now.add(const Duration(hours: 24));
      await expectLater(
        fixture.cache.read(offlineTestSubject),
        throwsA(isA<OfflineAccessUnavailable>()),
      );
    },
  );

  test(
    'protected clock high-water mark prevents rollback across restarts',
    () async {
      await save();
      now = now.add(const Duration(hours: 2));
      await fixture.cache.read(offlineTestSubject);
      now = now.subtract(const Duration(hours: 1));
      await expectLater(
        fixture.cache.read(offlineTestSubject),
        throwsA(isA<OfflineAccessUnavailable>()),
      );
    },
  );

  test(
    'restoring an older encrypted file cannot replay an earlier snapshot',
    () async {
      await save();
      final filename = fixture.storage.files.keys.single;
      final oldBytes = Uint8List.fromList(fixture.storage.files[filename]!);
      final updated = snapshot.replace(
        CatalogEdition.fromRecord(
          editionRecord(title: 'New title', revision: 2),
        ),
      );
      await save(updated);
      fixture.storage.files[filename] = oldBytes;
      await expectLater(
        fixture.cache.read(offlineTestSubject),
        throwsFormatException,
      );
    },
  );

  test('sign-out removes keys and files and rejects late saves', () async {
    await save();
    final oldGeneration = fixture.cache.generation;
    await fixture.cache.clearAll();
    expect(fixture.storage.files, isEmpty);
    expect(fixture.storage.protected, isEmpty);
    await expectLater(
      fixture.cache.save(
        subject: offlineTestSubject,
        snapshot: snapshot,
        leaseToken: fixture.token,
        generation: oldGeneration,
      ),
      throwsStateError,
    );
    expect(await fixture.cache.read(offlineTestSubject), isNull);
  });

  test('account changes discard the previous account cache', () async {
    await save();
    const anotherSubject = '00000000-0000-4000-8000-000000000003';
    await fixture.cache.save(
      subject: anotherSubject,
      snapshot: snapshot,
      leaseToken: await fixture.tokenFor(subject: anotherSubject),
      generation: fixture.cache.generation,
    );
    expect(await fixture.cache.read(offlineTestSubject), isNull);
    expect(
      (await fixture.cache.read(anotherSubject))!.snapshot.editions,
      hasLength(1),
    );
    expect(fixture.storage.files, hasLength(1));
  });

  test(
    'live access cannot recover after clock rollback without verification',
    () async {
      final entry = await save();
      expect(entry.isUsable(now.add(const Duration(minutes: 2))), isTrue);
      expect(entry.isUsable(now.add(const Duration(minutes: 1))), isFalse);
      expect(entry.isUsable(now.add(const Duration(minutes: 3))), isFalse);
    },
  );
}
