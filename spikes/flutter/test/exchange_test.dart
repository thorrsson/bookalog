import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel_community/excel_community.dart';
import 'package:xml/xml.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bookalog_flutter_spike/catalog.dart';
import 'package:bookalog_flutter_spike/exchange.dart';

void main() {
  final editions = decodeCatalog(
    File('assets/catalog.json').readAsStringSync(),
  );
  Uint8List fixture(String name) =>
      File('../fixtures/generated/$name').readAsBytesSync();
  Uint8List workbookWith(String content) {
    final bytes = utf8.encode(content);
    final archive = Archive()
      ..addFile(ArchiveFile('xl/worksheets/sheet1.xml', bytes.length, bytes));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  test(
    'native XLSX reads the common fixture and exports 5,000 string-only rows',
    () {
      expect(previewXlsx(fixture('catalog.xlsx')), 12);
      final bytes = xlsxProjection(editions);
      expect(previewXlsx(bytes), 5000);
      final sheet = Excel.decodeBytes(bytes).tables.values.single;
      expect(sheet.rows[5][2]!.value.toString(), editions[4].title);
      expect(sheet.rows[2][4]!.value.toString(), editions[1].isbn);
      expect(sheet.rows[2][6]!.value.toString(), '2030');
      expect(sheet.rows[5][2]!.value, isA<TextCellValue>());
    },
  );
  test('native XLSX rejects malformed files, oversized grids, formulas and entities', () {
    expect(
      () => previewXlsx(fixture('malformed.xlsx')),
      throwsA(isA<Exception>()),
    );
    for (final content in [
      '<worksheet><sheetData><row><c r="XFD1048576"/></row></sheetData></worksheet>',
      '<worksheet><sheetData><row><c r="A1"><f>1+1</f></c></row></sheetData></worksheet>',
      '<!DOCTYPE x [<!ENTITY x SYSTEM "file:///synthetic">]><worksheet/>',
      '<Relationships><Relationship TargetMode="External"/></Relationships>',
    ]) {
      expect(
        () => previewXlsx(workbookWith(content)),
        throwsA(isA<Exception>()),
      );
    }
  });
  test(
    'illustrative ONIX round-trips Unicode and escaped XML for all editions',
    () {
      expect(previewOnix(fixture('illustrative-onix.xml')), 1);
      expect(previewOnix(onixProjection(editions)), 5000);
      final special = Edition({
        ...editions[0].record,
        'title': 'A & B <C> "\u00e9"',
      });
      final document = XmlDocument.parse(
        utf8.decode(onixProjection([special])),
      );
      expect(
        document.findAllElements('TitleText').single.innerText,
        special.title,
      );
      for (final name in ['malformed-onix.xml', 'external-entity.xml']) {
        expect(() => previewOnix(fixture(name)), throwsA(isA<Exception>()));
      }
      expect(
        () => previewOnix(
          Uint8List.fromList(
            utf8.encode('<ONIXMessage release="3.0"><Product/></ONIXMessage>'),
          ),
        ),
        throwsA(isA<Exception>()),
      );
    },
  );
  test(
    'workbook byte and declared expansion limits reject input before parsing',
    () {
      expect(
        () => previewXlsx(Uint8List(maximumFileBytes + 1)),
        throwsFormatException,
      );
      final bytes = workbookWith('<worksheet/>');
      final data = ByteData.sublistView(bytes);
      var changed = false;
      for (var offset = 0; offset + 28 <= bytes.length; offset++) {
        if (data.getUint32(offset, Endian.little) == 0x02014b50) {
          data.setUint32(offset + 24, maximumExpandedBytes + 1, Endian.little);
          changed = true;
          break;
        }
      }
      expect(changed, isTrue);
      expect(
        () => previewXlsx(bytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('expanded-size'),
          ),
        ),
      );
    },
  );
}
