import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bookalog_flutter_spike/backend.dart';
import 'package:bookalog_flutter_spike/backend_controls.dart';
import 'package:bookalog_flutter_spike/catalog.dart';
import 'package:bookalog_flutter_spike/main.dart';

void main() {
  http.Response response(String body, int status) => http.Response(
    body,
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  final editions = decodeCatalog(
    File('assets/catalog.json').readAsStringSync(),
  );
  Matcher status(int code) =>
      isA<BackendFailure>().having((error) => error.status, 'status', code);
  Backend make(MockClient client) => Backend(
    provider: Provider.postgrest,
    baseUrl: 'https://catalog.invalid/rest/v1',
    accessToken: 'test-token',
    client: client,
  );
  test('remote HTTP, embedded credentials, query strings, and empty tokens are rejected', () {
    for (final url in [
      'http://catalog.invalid',
      'https://user:pass@catalog.invalid',
      'https://catalog.invalid?x=1',
    ]) {
      expect(
        () => Backend(
          provider: Provider.gateway,
          baseUrl: url,
          accessToken: 'test-token',
        ),
        throwsA(status(0)),
      );
    }
    expect(
      () => Backend(
        provider: Provider.gateway,
        baseUrl: 'https://catalog.invalid',
        accessToken: '',
      ),
      throwsA(status(401)),
    );
  });
  test(
    'short pages are followed until empty and membership is rechecked',
    () async {
      final offsets = <String>[];
      var memberships = 0;
      final backend = make(
        MockClient((request) async {
          expect(request.followRedirects, false);
          if (request.url.path.endsWith('current_catalog_role')) {
            memberships++;
            return response('"viewer"', 200);
          }
          offsets.add(request.url.queryParameters['offset']!);
          final offset = int.parse(offsets.last);
          return response(
            jsonEncode(
              offset < 3
                  ? [
                      {'record': editions[offset].record},
                    ]
                  : [],
            ),
            200,
          );
        }),
      );
      addTearDown(backend.close);
      expect((await backend.load()).length, 3);
      expect(offsets, ['0', '1', '2', '3']);
      expect(memberships, 2);
    },
  );
  test('failed pages and redirects never return a partial catalog', () async {
    for (final failure in [503, 307]) {
      final backend = make(
        MockClient((request) async {
          if (request.url.path.endsWith('current_catalog_role')) {
            return response('"viewer"', 200);
          }
          if (request.url.queryParameters['offset'] == '0') {
            return response(
              jsonEncode([
                {'record': editions[0].record},
              ]),
              200,
            );
          }
          return response('', failure);
        }),
      );
      addTearDown(backend.close);
      await expectLater(backend.load(), throwsA(status(failure)));
    }
  });
  test('duplicate pages are rejected immediately', () async {
    var requests = 0;
    final backend = make(
      MockClient((request) async {
        requests++;
        return response(
          request.url.path.endsWith('current_catalog_role')
              ? '"viewer"'
              : jsonEncode([
                  {'record': editions[0].record},
                ]),
          200,
        );
      }),
    );
    addTearDown(backend.close);
    await expectLater(backend.load(), throwsA(status(0)));
    expect(requests, 3);
  });
  test('revocation during pagination rejects the complete result', () async {
    var checks = 0;
    final backend = make(
      MockClient((request) async {
        if (request.url.path.endsWith('current_catalog_role')) {
          return response(++checks == 1 ? '"viewer"' : 'null', 200);
        }
        return response('[]', 200);
      }),
    );
    addTearDown(backend.close);
    await expectLater(backend.load(), throwsA(status(403)));
  });
  testWidgets('a conflict leaves the edit dialog and draft intact', (
    tester,
  ) async {
    final backend = make(MockClient((_) async => response('{}', 409)));
    addTearDown(backend.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditionEditor(backend: backend, edition: editions[0]),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.runAsync(() async {
      await tester.tap(find.text('Save title'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('Keep this draft'), findsOneWidget);
    expect(
      find.textContaining('This edition changed'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .join('\n'),
    );
    expect(find.text('Cancel edit'), findsOneWidget);
  });
  testWidgets('comparison controls remain scrollable at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ComparisonApp());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.text('File exchange'), findsNothing);
    await tester.tap(find.text('File exchange and test cache'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('File exchange'), findsOneWidget);
    expect(find.text('Synthetic cache'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blank title feedback prevents an unnecessary save request', (
    tester,
  ) async {
    var requests = 0;
    final backend = make(
      MockClient((_) async {
        requests++;
        return response('{}', 400);
      }),
    );
    addTearDown(backend.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditionEditor(backend: backend, edition: editions[0]),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Save title'));
    await tester.pump();
    expect(find.text('Enter a title before saving.'), findsOneWidget);
    expect(requests, 0);
  });
}
