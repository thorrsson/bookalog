import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bookalog_catalog/catalog.dart';
import 'package:bookalog_catalog/exchange.dart';
import 'package:bookalog_catalog/onix.dart';
import 'package:bookalog_exchange/bookalog_exchange.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show editionRecord;

const externalOnix = '''<?xml version="1.0" encoding="UTF-8"?>
<ONIXMessage xmlns="http://ns.editeur.org/onix/3.0/reference" release="3.0">
<Header><Sender><SenderName>Example Sender</SenderName></Sender><SentDateTime>20300102T030405Z</SentDateTime></Header>
<Product><RecordReference>external-book-001</RecordReference><NotificationType>02</NotificationType>
<ProductIdentifier><ProductIDType>15</ProductIDType><IDValue>9780306406157</IDValue></ProductIdentifier>
<DescriptiveDetail><ProductComposition>00</ProductComposition><ProductForm>BC</ProductForm>
<TitleDetail><TitleType>01</TitleType><TitleElement><TitleElementLevel>01</TitleElementLevel><TitleText>A &amp; B</TitleText></TitleElement></TitleDetail>
<Language><LanguageRole>01</LanguageRole><LanguageCode>eng</LanguageCode></Language></DescriptiveDetail>
<CollateralDetail><TextContent><TextType>03</TextType><ContentAudience>00</ContentAudience><Text textformat="06">First line&#13;
Second line &lt;literal&gt;</Text></TextContent></CollateralDetail>
<PublishingDetail><Publisher><PublishingRole>01</PublishingRole><PublisherName>Example Press</PublisherName></Publisher>
<PublishingStatus>02</PublishingStatus><PublishingDate><PublishingDateRole>01</PublishingDateRole><Date dateformat="01">203002</Date></PublishingDate>
</PublishingDetail></Product></ONIXMessage>''';

Uint8List bytes(String xml) => Uint8List.fromList(utf8.encode(xml));

CatalogEdition edition([Map<String, dynamic> changes = const {}]) =>
    CatalogEdition.fromRecord({
      ...editionRecord(),
      'id': '00000000-0000-4000-8000-000000000001',
      'work_id': '00000000-0000-4000-8000-000000000002',
      'isbn13': '9780306406157',
      ...changes,
    });

Uint8List encode(List<CatalogEdition> editions) => encodeCatalogOnix(
  editions,
  publisher: 'Example Press',
  sentAt: DateTime.utc(2030, 1, 2, 3, 4, 5),
);

void main() {
  test('independently authored external message maps metadata and keeps provenance', () async {
    final source = CatalogSourceFile('catalog.onix', bytes(externalOnix));
    final document = await readCatalogDocument(source);
    final plan = await prepareCatalogImport(
      source,
      document.table,
      inferColumnMapping(document.table.first),
      const CatalogSnapshot(role: CatalogRole.editor, editions: []),
      onixProvenance: document.onixProvenance,
    );
    expect(plan.canApply, isTrue);
    final row = plan.rows.single;
    expect(row.action, 'Create');
    expect(row.metadata, {
      'title': 'A & B',
      'format': 'paperback',
      'language': 'en',
      'isbn13': '9780306406157',
      'publication_status': 'announced',
      'release_date': '2030-02',
      'description': 'First line\r\nSecond line <literal>',
    });
    expect(row.sourceContext, {
      'profile': onixProfile,
      'record_reference': 'external-book-001',
      'sender': 'Example Sender',
      'sent_at': '20300102T030405Z',
      'publisher': 'Example Press',
    });
    expect(row.toRequest()['source_context'], row.sourceContext);
    expect(row.toRequest()['expected_revision'], isNull);
  });

  test(
    'all forms, statuses, partial dates, Unicode and literal CR round-trip',
    () {
      for (final form in ['paperback', 'hardback', 'ebook', 'audio']) {
        for (final status in [
          'planned',
          'announced',
          'released',
          'out_of_print',
        ]) {
          for (final date in ['2030', '2030-02', '2032-02-29']) {
            final record = edition({
              'format': form,
              'publication_status': status,
              'release_date': date,
              'title': 'Édition <&> 日本語',
              'description': "First\r\nSecond\rThird\t' =🙂",
            });
            final parsed = decodeCatalogOnix(encode([record])).records.single;
            for (final field in coreExchangeColumns.where(
              (field) => field != 'revision',
            )) {
              expect(
                parsed[field],
                record.record[field]?.toString() ?? '',
                reason: field,
              );
            }
            expect(parsed['revision'], '');
          }
        }
      }
      final absent = edition({
        'publication_status': 'released',
        'release_date': null,
        'isbn13': null,
        'description': '',
      });
      expect(
        decodeCatalogOnix(encode([absent])).records.single['release_date'],
        '',
      );
    },
  );

  test('prefixed reference tags work without accepting foreign namespaces', () {
    final prefixed = externalOnix
        .replaceFirst('xmlns=', 'xmlns:o=')
        .replaceAllMapped(
          RegExp(r'<(/?)([A-Z][A-Za-z]*)'),
          (match) => '<${match[1]}o:${match[2]}',
        );
    expect(decodeCatalogOnix(bytes(prefixed)).records.single['title'], 'A & B');
    expect(
      () => decodeCatalogOnix(
        bytes(
          prefixed.replaceFirst(
            '<o:TitleText>',
            '<o:TitleText xmlns:o="https://invalid.example">',
          ),
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'unsupported, duplicated or reordered data blocks the whole message',
    () {
      final cases = [
        externalOnix.replaceFirst('release="3.0"', 'release="3.1"'),
        externalOnix.replaceFirst('ProductForm>BC', 'ProductForm>ZZ'),
        externalOnix.replaceFirst('LanguageCode>eng', 'LanguageCode>en'),
        externalOnix.replaceFirst(
          '<Language>',
          '<Contributor><PersonName>A Writer</PersonName></Contributor><Language>',
        ),
        externalOnix.replaceFirst(
          '</DescriptiveDetail>',
          '<Subject><SubjectHeadingText>Fiction</SubjectHeadingText></Subject></DescriptiveDetail>',
        ),
        externalOnix.replaceFirst('</Product>', '<ProductSupply/></Product>'),
        externalOnix.replaceFirst(
          '<PublisherName>',
          '<PublisherName language="eng">',
        ),
        externalOnix.replaceFirst('textformat="06"', 'textformat="05"'),
        externalOnix.replaceFirst('textformat="06"', 'textformat="00"'),
        externalOnix.replaceFirst('A &amp; B', '<b>Title</b>'),
        externalOnix.replaceFirst(
          '<ProductForm>BC</ProductForm>',
          '<ProductForm>BC</ProductForm><ProductForm>BB</ProductForm>',
        ),
        externalOnix.replaceFirst(
          '<ProductComposition>00</ProductComposition><ProductForm>BC</ProductForm>',
          '<ProductForm>BC</ProductForm><ProductComposition>00</ProductComposition>',
        ),
        externalOnix.replaceFirst('NotificationType>02', 'NotificationType>04'),
        externalOnix.replaceFirst('NotificationType>02', 'NotificationType>05'),
        externalOnix.replaceFirst('NotificationType>02', 'NotificationType>89'),
        externalOnix.replaceFirst('PublishingStatus>02', 'PublishingStatus>09'),
        externalOnix.replaceFirst(
          '<Date dateformat="01">203002</Date>',
          '<Date dateformat="00">20300230</Date>',
        ),
        externalOnix.replaceFirst('dateformat="01"', 'dateformat="02"'),
        externalOnix.replaceFirst(
          RegExp(r'<PublishingDate>.*?</PublishingDate>'),
          '',
        ),
        externalOnix.replaceFirst('20300102T030405Z', '20300102T240000Z'),
        externalOnix.replaceFirst('9780306406157', '9780306406158'),
        externalOnix.replaceFirst('ProductIDType>15', 'ProductIDType>01'),
        externalOnix.replaceFirst(
          '<Text textformat="06">',
          '<Text textformat="06">&#0;',
        ),
      ];
      for (final xml in cases) {
        expect(
          () => decodeCatalogOnix(bytes(xml)),
          throwsFormatException,
          reason: xml,
        );
      }
    },
  );

  test('entities, processing instructions, encodings and structural limits fail closed', () {
    for (final xml in [
      '<!DOCTYPE ONIXMessage [<!ENTITY secret SYSTEM "file:///etc/passwd">]>$externalOnix',
      externalOnix.replaceFirst(
        '<Header>',
        '<?xml-stylesheet href="https://invalid.example/x"?><Header>',
      ),
      externalOnix.replaceFirst('encoding="UTF-8"', 'encoding="UTF-16"'),
      '${'<nested>' * 25}${'</nested>' * 25}',
      externalOnix.replaceFirst('A &amp; B', 'x' * 501),
    ]) {
      expect(() => decodeCatalogOnix(bytes(xml)), throwsFormatException);
    }
    expect(
      () => decodeCatalogOnix(Uint8List(maximumFileBytes + 1)),
      throwsFormatException,
    );
    final product = RegExp(
      r'<Product>.*?</Product>',
      dotAll: true,
    ).firstMatch(externalOnix)!.group(0)!;
    expect(
      () => decodeCatalogOnix(
        bytes(
          externalOnix.replaceFirst('</ONIXMessage>', '$product</ONIXMessage>'),
        ),
      ),
      throwsFormatException,
    );
    // A compact invalid message still exercises the element ceiling before DOM allocation.
    expect(
      () => decodeCatalogOnix(bytes('<root>${'<x/>' * 250001}</root>')),
      throwsFormatException,
    );
    final shell = externalOnix.replaceFirst(product, '<Product/>' * 5001);
    expect(() => decodeCatalogOnix(bytes(shell)), throwsFormatException);
  });

  test('export refuses unsupported metadata rather than defaulting or inventing values', () {
    for (final record in [
      edition({'format': 'other'}),
      edition({'language': 'en-US'}),
      edition({'language': 'zzz'}),
      edition({'publication_status': 'unknown'}),
      edition({'publication_status': 'planned', 'release_date': null}),
      edition({'title': 'bad\u0000text'}),
      edition({'description': 'x' * 100001}),
      edition({'isbn13': '9780306406158'}),
      edition({'isbn13': ''}),
      edition({'id': 'not-a-uuid'}),
    ]) {
      expect(() => encode([record]), throwsFormatException);
    }
    expect(() => encode([]), throwsFormatException);
    expect(() => encode([edition(), edition()]), throwsFormatException);
    expect(() => encode(List.filled(5001, edition())), throwsFormatException);
    expect(
      () => encodeCatalogOnix(
        [edition()],
        publisher: ' ',
        sentAt: DateTime.utc(2030),
      ),
      throwsFormatException,
    );
  });

  test('export enforces actual encoded byte size and valid message timestamps', () {
    expect(
      () => encode(
        List.generate(
          90,
          (index) => edition({
            'id':
                '00000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
            'description': 'x' * 100000,
          }),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => encodeCatalogOnix(
        [edition()],
        publisher: 'Example Press',
        sentAt: DateTime.utc(10000),
      ),
      throwsFormatException,
    );
  });

  test(
    'known identities update at preview revision; ISBN matching never merges',
    () async {
      final existing = edition({'language': 'eng', 'revision': 7});
      final source = CatalogSourceFile('catalog.xml', encode([existing]));
      final document = await readCatalogDocument(source);
      final snapshot = CatalogSnapshot(
        role: CatalogRole.editor,
        editions: [existing],
      );
      final plan = await prepareCatalogImport(
        source,
        document.table,
        inferColumnMapping(document.table.first),
        snapshot,
        onixProvenance: document.onixProvenance,
      );
      expect(plan.rows.single.action, 'Unchanged');
      expect(plan.rows.single.metadata['language'], 'eng');
      expect(plan.rows.single.toRequest()['expected_revision'], 7);
      final external = CatalogSourceFile('external.xml', bytes(externalOnix));
      final input = await readCatalogDocument(external);
      final collision = await prepareCatalogImport(
        external,
        input.table,
        inferColumnMapping(input.table.first),
        snapshot,
        onixProvenance: input.onixProvenance,
      );
      expect(collision.canApply, isFalse);
      expect(
        collision.rows.single.errors.join(' '),
        contains('Match its ID explicitly'),
      );
      await expectLater(
        prepareCatalogImport(
          source,
          document.table,
          {...inferColumnMapping(document.table.first), 'id': null},
          snapshot,
          onixProvenance: document.onixProvenance,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'import report must bind every provenance field before claiming success',
    () async {
      final source = CatalogSourceFile('catalog.xml', bytes(externalOnix));
      final document = await readCatalogDocument(source);
      final plan = await prepareCatalogImport(
        source,
        document.table,
        inferColumnMapping(document.table.first),
        const CatalogSnapshot(role: CatalogRole.editor, editions: []),
        onixProvenance: document.onixProvenance,
      );
      final row = {
        'source_row': 2,
        'edition_id': 'created-id',
        'revision': 1,
        'action': 'created',
        'source_context': plan.rows.single.sourceContext,
      };
      final record = {
        'request_id': plan.requestId,
        'source_name': plan.sourceName,
        'source_sha256': plan.sourceSha256,
        'occurred_at': DateTime.utc(2030).toIso8601String(),
        'created': 1,
        'updated': 0,
        'unchanged': 0,
        'rows': [row],
      };
      expect(CatalogImportReport.fromRecord(record).confirms(plan), isTrue);
      expect(
        CatalogImportReport.fromRecord({
          ...record,
          'rows': [
            {
              ...row,
              'source_context': {
                ...plan.rows.single.sourceContext!,
                'publisher': 'Changed',
              },
            },
          ],
        }).confirms(plan),
        isFalse,
      );
    },
  );

  test('5,000-product export preserves projected values for independent XSD and reader checks', () async {
    final records = List.generate(
      5000,
      (index) => edition({
        'id':
            '00000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
        'title': 'Édition $index <&>',
        'description': 'First\r\nSecond 日本語',
        'isbn13': null,
        'format': ['paperback', 'hardback', 'ebook', 'audio'][index % 4],
        'publication_status': [
          'planned',
          'announced',
          'released',
          'out_of_print',
        ][index % 4],
        'release_date': ['2030', '2030-02', '2032-02-29'][index % 3],
        'language': ['en', 'fr', 'de', 'ja'][index % 4],
      }),
    );
    final encoded = encode(records);
    final decoded = decodeCatalogOnix(encoded);
    expect(decoded.records.length, 5000);
    final expected = [
      for (final record in records)
        {
          for (final field in coreExchangeColumns.where(
            (field) => field != 'revision',
          ))
            field: record.record[field]?.toString() ?? '',
        },
    ];
    for (var index = 0; index < records.length; index++) {
      expect(decoded.records[index], {...expected[index], 'revision': ''});
    }
    final exportPath = Platform.environment['BOOKALOG_ONIX_TEST_EXPORT'];
    if (exportPath != null) {
      await File(exportPath).writeAsBytes(encoded);
      await File('$exportPath.json').writeAsString(jsonEncode(expected));
      await File('$exportPath.sample.xml').writeAsBytes(encode([edition()]));
      await File('$exportPath.external.xml').writeAsString(externalOnix);
    }
  });
}
