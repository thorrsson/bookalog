import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bookalog_flutter_spike/catalog.dart';
import 'package:bookalog_flutter_spike/cache.dart';
import 'package:bookalog_flutter_spike/main.dart';

Future<void> finishCatalogOperation(WidgetTester tester) async {
  await tester.runAsync(() async {
    final elapsed = Stopwatch()..start();
    while (find.byType(LinearProgressIndicator).evaluate().isNotEmpty &&
        elapsed.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  expect(find.byType(LinearProgressIndicator), findsNothing);
}

void main() {
  final source = File('assets/catalog.json').readAsStringSync();
  final editions = decodeCatalog(source);
  test('reads all fixtures and preserves partial dates and identifiers', () {
    expect(editions.length, 5000);
    expect(editions[0].isbn, null);
    expect(editions[1].releaseDate, '2030');
    expect(editions[2].releaseDate, '2030-02');
    expect(editions.where((e) => e.matches('caf\u00e9')), isNotEmpty);
    expect(editions.where((e) => e.matches(editions[1].isbn!)).length, 1);
    expect(
      () => Edition({...editions[0].record, 'release_date': '2030-02-30'}),
      throwsFormatException,
    );
  });
  test(
    'CSV projection round-trips text and neutralizes spreadsheet formulas',
    () {
      final csv = csvProjection(editions);
      expect(previewCsv(csv), 5000);
      expect(csv, contains("'=Synthetic"));
      expect(
        previewCsv(
          File('../fixtures/generated/catalog.csv').readAsStringSync(),
        ),
        12,
      );
      expect(() => previewCsv('bad,columns\nx,y'), throwsFormatException);
    },
  );
  test('offline policy is fixed to verification and fails closed', () {
    const start = 1900000000000;
    bool allowed(
      int now, {
      int? lastSeen,
      bool revoked = false,
      bool account = true,
    }) =>
        canReadOffline(
          verifiedAt: start,
          lastSeenAt: lastSeen ?? start,
          now: now,
          revoked: revoked,
          accountMatches: account,
        );
    expect(allowed(start + 86400000 - 1), isTrue);
    expect(allowed(start + 86400000), isFalse);
    expect(allowed(start + 86400001), isFalse);
    expect(allowed(start - 1), isFalse);
    expect(allowed(start + 3600000, lastSeen: start + 3600000), isTrue);
    expect(allowed(start + 86400000, lastSeen: start + 3600000), isFalse);
    expect(allowed(start, revoked: true), isFalse);
    expect(allowed(start, account: false), isFalse);
  });
  test('cache encryption authenticates contents and rejects tampering or wrong keys', () async {
    final key = await cipher.newSecretKey();
    final sealed = await seal(source, key);
    expect(sealed, isNot(contains('Synthetic Atlas')));
    expect(await unseal(sealed, key), source);
    final envelope = jsonDecode(sealed) as Map<String, dynamic>;
    final bytes = base64Decode(envelope['ciphertext'] as String);
    bytes[0] ^= 1;
    envelope['ciphertext'] = base64Encode(bytes);
    await expectLater(
      unseal(jsonEncode(envelope), key),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      unseal(sealed, await cipher.newSecretKey()),
      throwsA(isA<Exception>()),
    );
  });
  testWidgets(
    'comparison shell labels its synthetic and unauthenticated state',
    (tester) async {
      await tester.pumpWidget(const ComparisonApp());
      expect(find.text('Synthetic catalog'), findsOneWidget);
      expect(find.textContaining('No sign-in'), findsOneWidget);
    },
  );
  testWidgets('clear search restores all editions and keyboard focus', (
    tester,
  ) async {
    rootBundle.evict('assets/catalog.json');
    await tester.pumpWidget(const ComparisonApp());
    await finishCatalogOperation(tester);
    await tester.enterText(find.byType(TextField), 'no-such-synthetic-edition');
    await tester.pumpAndSettle();
    expect(find.text('0 matching editions'), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    final clear = find.widgetWithText(TextButton, 'Clear search');
    await tester.ensureVisible(clear);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.text('5000 matching editions'), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), editions[1].isbn!);
    await tester.pumpAndSettle();
    expect(find.text('1 matching edition'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('5000 matching editions'), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
  });
  testWidgets('cache failure preserves loaded catalog and search recovery', (
    tester,
  ) async {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    rootBundle.evict('assets/catalog.json');
    await tester.pumpWidget(const ComparisonApp());
    await finishCatalogOperation(tester);
    await tester.tap(find.text('File exchange and test cache'));
    await tester.pumpAndSettle();
    final readCache = find.widgetWithText(OutlinedButton, 'Read test cache');
    await tester.ensureVisible(readCache);
    await tester.pumpAndSettle();
    await tester.tap(readCache);
    await tester.pump();
    await finishCatalogOperation(tester);
    expect(find.textContaining('No protected cache key'), findsOneWidget);
    await tester.ensureVisible(find.text('File exchange and test cache'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File exchange and test cache'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'no-such-synthetic-edition');
    await tester.pumpAndSettle();
    expect(find.text('Synthetic catalog'), findsOneWidget);
    expect(find.textContaining('No matching editions.'), findsOneWidget);
    expect(find.text('Restore synthetic catalog'), findsNothing);
    final clear = find.widgetWithText(TextButton, 'Clear search');
    await tester.ensureVisible(clear);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.text('5000 matching editions'), findsOneWidget);
    expect(find.textContaining('No protected cache key'), findsOneWidget);
  });
  testWidgets('failed fixture load offers recovery and restores the catalog', (
    tester,
  ) async {
    rootBundle.evict('assets/catalog.json');
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (_) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        'flutter/assets',
        null,
      );
      rootBundle.evict('assets/catalog.json');
    });
    await tester.pumpWidget(const ComparisonApp());
    await finishCatalogOperation(tester);
    expect(find.text('Catalog unavailable'), findsOneWidget);
    expect(find.textContaining('No catalog loaded.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Clear search'), findsNothing);
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (message) async =>
          message != null &&
              const StringCodec().decodeMessage(message) ==
                  'assets/catalog.json'
          ? ByteData.sublistView(utf8.encode(source))
          : null,
    );
    rootBundle.evict('assets/catalog.json');
    final restore = find.widgetWithText(
      TextButton,
      'Restore synthetic catalog',
    );
    await tester.ensureVisible(restore);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pump();
    await finishCatalogOperation(tester);
    expect(find.text('Synthetic catalog'), findsOneWidget);
    expect(find.text('5000 matching editions'), findsOneWidget);
    expect(find.text('Restore synthetic catalog'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
