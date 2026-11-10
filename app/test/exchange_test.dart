import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bookalog_catalog/catalog.dart';
import 'package:bookalog_catalog/exchange.dart';
import 'package:bookalog_exchange/bookalog_exchange.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show editionRecord;

void main() {
  final existing = CatalogEdition.fromRecord({
    ...editionRecord(),
    'isbn13': '9780306406157',
  });
  final snapshot = CatalogSnapshot(
    role: CatalogRole.editor,
    editions: [existing],
  );
  CatalogSourceFile source(String csv) =>
      CatalogSourceFile('catalog.csv', Uint8List.fromList(utf8.encode(csv)));
  Future<CatalogImportPlan> preview(String csv) async {
    final file = source(csv);
    final table = decodeCsvTable(file.bytes);
    return prepareCatalogImport(
      file,
      table,
      inferColumnMapping(table.first),
      snapshot,
    );
  }

  test(
    'CSV preserves text, Unicode, quoted commas and multiline descriptions',
    () {
      final file = source(
        'title,description\r\n"Édition, one","Line one\r\nLine two"\r\n',
      );
      final table = decodeCsvTable(file.bytes);
      expect(table, [
        ['title', 'description'],
        ['Édition, one', 'Line one\r\nLine two'],
      ]);
      expect(
        decodeCsvTable(
          source('title,description\nOne,"Line one\nLine two"\n').bytes,
        )[1][1],
        'Line one\nLine two',
      );
    },
  );

  test(
    'invalid headers, row widths, cell content and file limits are rejected',
    () {
      for (final csv in [
        'title,Title\none,two',
        'title,\none,two',
        'title\none,two',
        'title\nbad\u0000text',
      ]) {
        expect(() => decodeCsvTable(source(csv).bytes), throwsFormatException);
      }
      expect(
        () => decodeCsvTable(Uint8List(maximumFileBytes + 1)),
        throwsFormatException,
      );
      expect(
        () => decodeCsvTable(source('title\none\ntwo').bytes, maximumRows: 1),
        throwsFormatException,
      );
    },
  );

  test(
    'XLSX preserves every projected value for 5,000 text-only editions',
    () async {
      final records = List.generate(
        5000,
        (index) => CatalogEdition.fromRecord({
          ...existing.record,
          'id': 'edition-$index',
          'title': 'Édition $index + =safe',
          'description': 'Line one\nLine two',
          'release_date': index.isEven ? '2030' : '2030-02',
        }),
      );
      final bytes = await exportCatalogCore(records, xlsx: true);
      final table = decodeXlsxTable(bytes);
      expect(table.length, 5001);
      expect(table.first, coreExchangeColumns);
      final exportPath = Platform.environment['BOOKALOG_EXCHANGE_TEST_EXPORT'];
      if (exportPath != null) {
        await File(exportPath).writeAsBytes(bytes);
        await File('$exportPath.json').writeAsString(
          jsonEncode([
            coreExchangeColumns,
            ...records.map(
              (record) => coreExchangeColumns
                  .map((field) => record.record[field]?.toString() ?? '')
                  .toList(),
            ),
          ]),
        );
      }
      for (var index = 0; index < records.length; index++) {
        expect(
          table[index + 1],
          coreExchangeColumns
              .map((field) => records[index].record[field]?.toString() ?? '')
              .toList(),
        );
      }
    },
  );

  test('CSV escapes formula-like values while XLSX keeps exact strings', () {
    final rows = [
      ['title'],
      ['=SUM(A1)'],
      [' \t+value'],
      ["'quoted"],
      ['Normal'],
    ];
    expect(
      decodeCsvTable(encodeCsvTable(rows)).skip(1).map((row) => row.single),
      ["'=SUM(A1)", "' \t+value", "''quoted", 'Normal'],
    );
    expect(decodeXlsxTable(encodeXlsxTable(rows)), rows);
  });

  test('shared XLSX decoder rejects forged expansion declarations', () {
    final bytes = encodeXlsxTable([
      ['title'],
      ['One'],
    ]);
    final data = ByteData.sublistView(bytes);
    for (var index = 0; index + 28 <= bytes.length; index++) {
      if (data.getUint32(index, Endian.little) == 0x02014b50) {
        data.setUint32(index + 24, maximumExpandedBytes + 1, Endian.little);
        break;
      }
    }
    expect(() => decodeXlsxTable(bytes), throwsFormatException);
  });

  test(
    'known IDs update without clearing unmapped optional metadata',
    () async {
      final plan = await preview(
        'id,title,format,language,publication_status\n'
        'edition-1,New title,paperback,en,announced',
      );
      expect(plan.canApply, isTrue);
      final row = plan.rows.single;
      expect(row.action, 'Update');
      expect(row.metadata['description'], existing.description);
      expect(row.metadata['isbn13'], existing.isbn);
      expect(row.toRequest()['expected_revision'], existing.revision);
      expect(row.workId, existing.workId);
    },
  );

  test('mapped empty optional values explicitly clear them', () async {
    final plan = await preview(
      'id,title,format,language,publication_status,isbn13,description,release_date\n'
      'edition-1,New title,paperback,en,announced,,,',
    );
    expect(plan.canApply, isTrue);
    expect(plan.rows.single.metadata['isbn13'], isNull);
    expect(plan.rows.single.metadata['release_date'], isNull);
    expect(plan.rows.single.metadata['description'], '');
  });

  test(
    'new editions retain partial dates and only explicit known work identity',
    () async {
      final plan = await preview(
        'work_id,title,format,language,publication_status,release_date\n'
        'work-1,Additional,audio,en,planned,2030-02\n'
        ',New work,ebook,en,planned,2031',
      );
      expect(plan.canApply, isTrue);
      expect(plan.rows.map((row) => row.action), ['Create', 'Create']);
      expect(plan.rows.map((row) => row.workId), ['work-1', null]);
      expect(plan.rows.first.toRequest()['expected_revision'], isNull);
      expect(plan.sourceSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    },
  );

  test('ambiguous ISBNs, unknown identity, stale revisions and duplicate rows block apply', () async {
    for (final csv in [
      'title,format,language,publication_status,isbn13\nNew,paperback,en,planned,9780306406157',
      'id,title,format,language,publication_status\nunknown,New,paperback,en,planned',
      'id,revision,title,format,language,publication_status\nedition-1,999,New,paperback,en,planned',
      'id,title,format,language,publication_status\nedition-1,New,paperback,en,planned\nedition-1,Again,paperback,en,planned',
      'work_id,title,format,language,publication_status\nunknown,New,paperback,en,planned',
      'title,format,language,publication_status,release_date\nNew,paperback,en,planned,2030-02-30',
    ]) {
      final plan = await preview(csv);
      expect(plan.canApply, isFalse, reason: csv);
      expect(plan.rows.any((row) => row.errors.isNotEmpty), isTrue);
    }
  });

  test(
    'mapping supports source headers and rejects duplicate assignments',
    () async {
      final file = source('Book,Binding,Language,Status\nOne,ebook,en,planned');
      final table = decodeCsvTable(file.bytes);
      final mapping = {
        'title': 0,
        'format': 1,
        'language': 2,
        'publication_status': 3,
      };
      final plan = await prepareCatalogImport(file, table, mapping, snapshot);
      expect(plan.canApply, isTrue);
      await expectLater(
        prepareCatalogImport(file, table, {
          ...mapping,
          'description': 0,
        }, snapshot),
        throwsFormatException,
      );
    },
  );

  test(
    'unchanged export has no proposed metadata changes and empty XML fails',
    () async {
      final bytes = await exportCatalogCore([existing], xlsx: true);
      final file = CatalogSourceFile('roundtrip.xlsx', bytes);
      final table = decodeXlsxTable(bytes);
      final plan = await prepareCatalogImport(
        file,
        table,
        inferColumnMapping(table.first),
        snapshot,
      );
      expect(plan.rows.single.action, 'Unchanged');
      await expectLater(
        readCatalogDocument(CatalogSourceFile('catalog.xml', Uint8List(0))),
        throwsFormatException,
      );
    },
  );
}
