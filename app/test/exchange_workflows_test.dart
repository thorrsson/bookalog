import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bookalog_catalog/catalog.dart';
import 'package:bookalog_catalog/exchange.dart';
import 'package:bookalog_catalog/exchange_screen.dart';
import 'package:bookalog_catalog/onix.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'widget_test.dart' show editionRecord;

class _Files extends CatalogExchangeFiles {
  CatalogSourceFile source = CatalogSourceFile(
    'new.csv',
    Uint8List.fromList(
      utf8.encode(
        'title,format,language,publication_status,release_date\n'
        'New edition,paperback,en,planned,2030-02',
      ),
    ),
  );
  final saved = <String>[];
  final formats = <CatalogExchangeFormat>[];
  String? publisherName;
  @override
  Future<CatalogSourceFile?> pick() async => source;
  @override
  Future<CatalogImportDocument> read(CatalogSourceFile source) async =>
      decodeCatalogDocument(source);
  @override
  Future<Uint8List> encode(
    List<CatalogEdition> editions, {
    required CatalogExchangeFormat format,
    String publisher = '',
  }) async {
    formats.add(format);
    publisherName = publisher;
    return Uint8List(1);
  }

  @override
  Future<bool> save(String name, Uint8List bytes) async {
    saved.add(name);
    return true;
  }
}

class _Repository extends CatalogRepository {
  _Repository(super.client);
  CatalogRole role = CatalogRole.editor;
  bool loseFirstResponse = false;
  bool mismatchReport = false;
  final requests = <String>[];
  final reports = <Map<String, dynamic>>[];
  @override
  Future<CatalogSnapshot> loadCatalog() async =>
      CatalogSnapshot(role: role, editions: []);
  @override
  Future<List<Map<String, dynamic>>> loadImportReports() async => reports;
  @override
  Future<Map<String, dynamic>> importMetadata({
    required String requestId,
    required String sourceName,
    required String sourceSha256,
    required List<Map<String, dynamic>> rows,
  }) async {
    requests.add(requestId);
    if (loseFirstResponse && requests.length == 1) {
      throw const SocketException('Response lost');
    }
    final report = <String, dynamic>{
      'request_id': requestId,
      'source_name': sourceName,
      'source_sha256': sourceSha256,
      'occurred_at': DateTime.utc(2030).toIso8601String(),
      'created': rows.length,
      'updated': 0,
      'unchanged': 0,
      'rows': [
        for (final row in rows)
          {
            'source_row': row['source_row'],
            'action': 'created',
            'edition_id': 'created-${row['source_row']}',
            'revision': mismatchReport ? 99 : 1,
            if (row['source_context'] != null)
              'source_context': row['source_context'],
          },
      ],
    };
    reports.add(report);
    return report;
  }
}

void main() {
  final captureDirectory = Platform.environment['BOOKALOG_CAPTURE_DIR'];
  setUpAll(() async {
    if (captureDirectory != null) {
      final font = File(Platform.environment['BOOKALOG_CAPTURE_FONT']!);
      await (FontLoader(
        'Roboto',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  late _Repository repository;
  late _Files files;
  late SupabaseClient client;
  var refreshes = 0;
  setUp(() {
    client = SupabaseClient('https://catalog.invalid', 'test-publishable-key');
    repository = _Repository(client);
    files = _Files();
    refreshes = 0;
    addTearDown(client.dispose);
  });
  Future<void> open(
    WidgetTester tester, {
    double width = 1100,
    CatalogRole role = CatalogRole.editor,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('exchange-capture'),
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: captureDirectory == null ? null : 'Roboto',
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff315f9c),
              surface: const Color(0xfff7f8f5),
            ),
          ),
          home: CatalogExchangeScreen(
            repository: repository,
            role: role,
            files: files,
            onApplied: () async {
              refreshes++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> click(WidgetTester tester, String label) async {
    final finder = find.text(label);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> review(WidgetTester tester) async {
    await click(tester, 'Select import file');
    await click(tester, 'Review changes');
  }

  testWidgets(
    'mapping and preview never write; confirmation persists a downloadable report',
    (tester) async {
      await open(tester);
      await review(tester);
      expect(repository.requests, isEmpty);
      expect(find.text('Row 2: New edition'), findsOneWidget);
      await click(tester, 'Apply 1 reviewed row');
      expect(repository.requests, hasLength(1));
      expect(find.text('Import complete'), findsOneWidget);
      expect(refreshes, 1);
      await click(tester, 'Save import report');
      expect(files.saved.single, startsWith('bookalog-import-'));
    },
  );

  testWidgets(
    'lost response retries the same immutable request without remapping',
    (tester) async {
      repository.loseFirstResponse = true;
      await open(tester);
      await review(tester);
      await click(tester, 'Apply 1 reviewed row');
      expect(find.textContaining('outcome is not confirmed'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Back to mapping'),
            )
            .onPressed,
        isNull,
      );
      await click(tester, 'Retry same import');
      expect(repository.requests, hasLength(2));
      expect(repository.requests.first, repository.requests.last);
      expect(find.text('Import complete'), findsOneWidget);
    },
  );

  testWidgets(
    'unmapped columns need acknowledgment and invalid rows block all writes',
    (tester) async {
      files.source = CatalogSourceFile(
        'source.csv',
        Uint8List.fromList(
          utf8.encode(
            'title,format,language,publication_status,unmapped\nOne,unknown,en,planned,Do not drop silently',
          ),
        ),
      );
      await open(tester);
      await click(tester, 'Select import file');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review changes'),
            )
            .onPressed,
        isNull,
      );
      await click(tester, 'Ignore these source columns: unmapped');
      await click(tester, 'Review changes');
      expect(
        find.textContaining('Needs attention - Unsupported format.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Apply 1 reviewed row'),
            )
            .onPressed,
        isNull,
      );
      expect(repository.requests, isEmpty);
    },
  );

  testWidgets(
    'a mismatched report does not claim success or refresh the catalog',
    (tester) async {
      repository.mismatchReport = true;
      await open(tester);
      await review(tester);
      await click(tester, 'Apply 1 reviewed row');
      expect(find.text('Import complete'), findsNothing);
      expect(
        find.textContaining('does not match this request'),
        findsOneWidget,
      );
      expect(refreshes, 0);
    },
  );

  testWidgets(
    'viewer exports require acknowledgment and a fresh authorized catalog',
    (tester) async {
      repository.role = CatalogRole.viewer;
      await open(tester, role: CatalogRole.viewer);
      expect(find.text('Select import file'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Export XLSX'),
            )
            .onPressed,
        isNull,
      );
      await click(
        tester,
        'I understand these files are unencrypted and omit the metadata listed above.',
      );
      await click(tester, 'Export XLSX');
      expect(files.saved, ['bookalog-core.xlsx']);
      expect(repository.requests, isEmpty);
    },
  );

  testWidgets('narrow mapping and review remain usable with scaled text', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, width: 390);
    await review(tester);
    await click(tester, 'Back to mapping');
    expect(find.text('Review changes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('export options have a distinct, full-width ONIX section', (
    tester,
  ) async {
    await open(tester, role: CatalogRole.viewer);
    final export = tester.getRect(
      find.widgetWithText(OutlinedButton, 'Export XLSX'),
    );
    final onix = tester.getRect(
      find.widgetWithText(ExpansionTile, 'ONIX 3.0 core profile'),
    );
    expect(onix.top - export.bottom, greaterThanOrEqualTo(16));
    expect(onix.width, greaterThan(export.width * 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ONIX export requires publisher and both disclosures', (
    tester,
  ) async {
    await open(tester, width: 390, role: CatalogRole.viewer);
    await click(tester, 'ONIX 3.0 core profile');
    final export = find.widgetWithText(OutlinedButton, 'Export ONIX');
    expect(tester.widget<OutlinedButton>(export).onPressed, isNull);
    await click(
      tester,
      'I understand these files are unencrypted and omit the metadata listed above.',
    );
    await tester.enterText(find.byType(TextField), 'Example Press');
    await click(
      tester,
      'I understand the ONIX profile limits and have confirmed the publisher.',
    );
    await click(tester, 'Export ONIX');
    expect(files.saved, ['bookalog-onix-core.xml']);
    expect(files.formats, [CatalogExchangeFormat.onix]);
    expect(files.publisherName, 'Example Press');
    expect(repository.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ONIX uses fixed mapping and preserves provenance through confirmation',
    (tester) async {
      final xml = utf8.decode(
        encodeCatalogOnix(
          [
            CatalogEdition.fromRecord({
              ...editionRecord(),
              'id': '00000000-0000-4000-8000-000000000001',
              'work_id': '00000000-0000-4000-8000-000000000002',
              'isbn13': '9780306406157',
            }),
          ],
          publisher: 'Example Press',
          sentAt: DateTime.utc(2030),
        ),
      );
      // An external profile message has an ISBN but no local Bookalog identities.
      final external = xml
          .replaceFirst(
            RegExp(
              r'<ProductIdentifier><ProductIDType>01</ProductIDType>.*?</ProductIdentifier>',
            ),
            '',
          )
          .replaceFirst(RegExp(r'<RelatedMaterial>.*?</RelatedMaterial>'), '');
      files.source = CatalogSourceFile(
        'catalog.onix',
        Uint8List.fromList(utf8.encode(external)),
      );
      await open(tester, width: 390);
      await click(tester, 'Select import file');
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      expect(find.textContaining('Fixed ONIX mapping.'), findsOneWidget);
      await click(tester, 'Review changes');
      expect(repository.requests, isEmpty);
      await click(tester, 'Apply 1 reviewed row');
      expect(find.text('Import complete'), findsOneWidget);
      expect(
        repository.reports.single['rows'][0]['source_context']['publisher'],
        'Example Press',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsupported ONIX content produces an actionable error without writes',
    (tester) async {
      files.source = CatalogSourceFile(
        'bad.xml',
        Uint8List.fromList(utf8.encode('<ONIXMessage release="2.1"/>')),
      );
      await open(tester);
      await click(tester, 'Select import file');
      expect(find.textContaining('File could not be opened:'), findsOneWidget);
      expect(find.text('Review changes'), findsNothing);
      expect(repository.requests, isEmpty);
    },
  );

  if (captureDirectory != null) {
    testWidgets('capture synthetic exchange at desktop and narrow widths', (
      tester,
    ) async {
      Future<void> capture(String name) async {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('exchange-capture')),
          );
          final image = await boundary.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(captureDirectory).create(recursive: true);
            await File('$captureDirectory/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      for (final width in [1100.0, 390.0]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await open(tester, width: width);
        await capture('exchange-home-${width.toInt()}');
        await click(tester, 'ONIX 3.0 core profile');
        await tester.ensureVisible(find.text('Export ONIX'));
        await tester.pumpAndSettle();
        await capture('exchange-onix-${width.toInt()}');
        await review(tester);
        await capture('exchange-review-${width.toInt()}');
        expect(tester.takeException(), isNull);
      }
    });
  }
}
