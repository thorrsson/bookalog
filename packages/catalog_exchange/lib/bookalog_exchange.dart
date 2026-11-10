import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:excel_community/excel_community.dart';
import 'package:xml/xml.dart';

const maximumFileBytes = 8 * 1024 * 1024;
const maximumExpandedBytes = 32 * 1024 * 1024;

XmlDocument _xml(String source) {
  if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(source)) {
    throw const FormatException(
      'DTD and entity declarations are not accepted.',
    );
  }
  return XmlDocument.parse(source);
}

void _checkBytes(Uint8List bytes) {
  if (bytes.length > maximumFileBytes) {
    throw const FormatException('File exceeds 8 MiB.');
  }
}

List<List<String>> _checkedTable(
  List<List<String>> rows,
  int maximumRows,
  int maximumColumns,
) {
  if (rows.isEmpty ||
      rows.length > maximumRows + 1 ||
      rows.first.isEmpty ||
      rows.first.length > maximumColumns) {
    throw FormatException(
      'Expected a header and at most $maximumRows rows, $maximumColumns columns.',
    );
  }
  final headers = rows.first.map((text) => text.trim()).toList();
  if (headers.any((text) => text.isEmpty || text.length > 100) ||
      headers.map((text) => text.toLowerCase()).toSet().length !=
          headers.length) {
    throw const FormatException('Column names must be nonempty and unique.');
  }
  if (rows.any(
    (row) =>
        row.length != headers.length ||
        row.any((text) => text.contains('\u0000') || text.length > 100000),
  )) {
    throw const FormatException(
      'Rows must match the header; cells may not contain NUL or exceed 100,000 characters.',
    );
  }
  return [headers, ...rows.skip(1)];
}

List<List<String>> decodeCsvTable(
  Uint8List bytes, {
  int maximumRows = 5000,
  int maximumColumns = 32,
}) {
  _checkBytes(bytes);
  var source = utf8.decode(bytes);
  if (source.startsWith('\ufeff')) source = source.substring(1);
  final newline = source.indexOf('\n');
  final eol = newline > 0 && source[newline - 1] == '\r' ? '\r\n' : '\n';
  final parsed = CsvToListConverter(
    shouldParseNumbers: false,
    allowInvalid: false,
    eol: eol,
  ).convert(source);
  return _checkedTable(
    parsed.map((row) => row.map((cell) => cell.toString()).toList()).toList(),
    maximumRows,
    maximumColumns,
  );
}

Uint8List encodeCsvTable(List<List<String>> rows) {
  _checkedTable(rows, 10000, 32);
  String safe(String text) =>
      RegExp(r"^\s*[=+\-@']").hasMatch(text) ? "'$text" : text;
  final bytes = Uint8List.fromList(
    utf8.encode(
      const ListToCsvConverter().convert(
        rows.map((row) => row.map(safe).toList()).toList(),
      ),
    ),
  );
  _checkBytes(bytes);
  return bytes;
}

void _cellReference(String value, int maximumRows, int maximumColumns) {
  final match = RegExp(r'^([A-Z]{1,3})([1-9][0-9]{0,5})$').firstMatch(value);
  if (match == null)
    throw const FormatException('Invalid worksheet coordinate.');
  final column = match[1]!.codeUnits.fold(
    0,
    (total, letter) => total * 26 + letter - 64,
  );
  if (column > maximumColumns || int.parse(match[2]!) > maximumRows + 1) {
    throw const FormatException('Worksheet exceeds the row or column limit.');
  }
}

List<List<String>> decodeXlsxTable(
  Uint8List bytes, {
  int maximumRows = 5000,
  int maximumColumns = 32,
}) {
  _checkBytes(bytes);
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.length > 100 ||
      directory.fileHeaders.map((entry) => entry.filename).toSet().length !=
          directory.fileHeaders.length ||
      directory.fileHeaders.fold<int>(
            0,
            (sum, entry) => sum + entry.uncompressedSize,
          ) >
          maximumExpandedBytes) {
    throw const FormatException(
      'Workbook exceeds the entry count or expanded-size limit, or repeats an entry.',
    );
  }
  final archive = ZipDecoder().decodeBytes(
    bytes,
    verify: true,
    throwOnError: true,
  );
  var expanded = 0;
  for (final file in archive) {
    if (file.isSymbolicLink ||
        file.name.contains('..') ||
        file.name.startsWith('/')) {
      throw const FormatException('Invalid workbook entry.');
    }
    if (!file.isFile) continue;
    if (!(file.name.endsWith('.xml') || file.name.endsWith('.rels'))) {
      throw const FormatException(
        'Embedded objects and macros are not accepted.',
      );
    }
    final content = file.content;
    expanded += content.length;
    if (expanded > maximumExpandedBytes) {
      throw const FormatException('Workbook exceeds the expanded-size limit.');
    }
    final document = _xml(utf8.decode(content));
    for (final node in document.descendants.whereType<XmlElement>()) {
      if (node.name.local == 'f' ||
          node.getAttribute('TargetMode') == 'External') {
        throw const FormatException(
          'Formulas and external links are not accepted.',
        );
      }
      if (file.name.startsWith('xl/worksheets/')) {
        if (node.name.local == 'c') {
          _cellReference(
            node.getAttribute('r') ?? '',
            maximumRows,
            maximumColumns,
          );
        }
        if (node.name.local == 'row') {
          final row = int.tryParse(node.getAttribute('r') ?? '');
          if (row == null || row < 1 || row > maximumRows + 1) {
            throw const FormatException('Invalid worksheet row.');
          }
        }
        if (node.name.local == 'dimension') {
          for (final reference in (node.getAttribute('ref') ?? '').split(':')) {
            _cellReference(reference, maximumRows, maximumColumns);
          }
        }
      }
    }
  }
  final workbook = Excel.decodeBytes(_withOptionalStyles(archive));
  if (workbook.tables.length != 1) {
    throw const FormatException('Select a workbook with exactly one sheet.');
  }
  final sheet = workbook.tables.values.single;
  if (sheet.maxRows < 1 ||
      sheet.maxRows > maximumRows + 1 ||
      sheet.maxColumns > maximumColumns) {
    throw const FormatException('Worksheet exceeds the row or column limit.');
  }
  String text(Data? cell) => switch (cell?.value) {
    null => '',
    TextCellValue value => value.value.toString(),
    _ => throw const FormatException(
      'Use text cells; numeric, date and formula cells are rejected.',
    ),
  };
  final rows = sheet.rows
      .map(
        (row) => List.generate(
          sheet.maxColumns,
          (index) => index < row.length ? text(row[index]) : '',
        ),
      )
      .toList();
  return _checkedTable(rows, maximumRows, maximumColumns);
}

List<int> _withOptionalStyles(Archive archive) {
  const path = 'xl/_rels/workbook.xml.rels';
  const styleType =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles';
  final relationFile = archive.findFile(path);
  if (relationFile == null)
    throw const FormatException('Missing workbook relationships.');
  final relationships = _xml(utf8.decode(relationFile.content));
  if (!relationships
      .findAllElements('Relationship')
      .any((node) => node.getAttribute('Type') == styleType)) {
    // XLSX makes styles optional, but excel_community requires this relationship.
    if (archive.findFile('xl/styles.xml') == null) {
      final defaults = ZipDecoder().decodeBytes(Excel.createExcel().encode()!);
      archive.addFile(defaults.findFile('xl/styles.xml')!);
    }
    final ids = relationships
        .findAllElements('Relationship')
        .map((node) => node.getAttribute('Id'))
        .toSet();
    var id = 'bookalogStyles';
    while (ids.contains(id)) {
      id += '_';
    }
    relationships.rootElement.children.add(
      XmlElement(XmlName.parts('Relationship'), [
        XmlAttribute(XmlName.parts('Id'), id),
        XmlAttribute(XmlName.parts('Type'), styleType),
        XmlAttribute(XmlName.parts('Target'), 'styles.xml'),
      ]),
    );
    final content = utf8.encode(relationships.toXmlString());
    archive.addFile(ArchiveFile(path, content.length, content));
    final typesFile = archive.findFile('[Content_Types].xml');
    if (typesFile == null)
      throw const FormatException('Missing workbook content types.');
    final types = _xml(utf8.decode(typesFile.content));
    if (!types
        .findAllElements('Override')
        .any((node) => node.getAttribute('PartName') == '/xl/styles.xml')) {
      types.rootElement.children.add(
        XmlElement(XmlName.parts('Override'), [
          XmlAttribute(XmlName.parts('PartName'), '/xl/styles.xml'),
          XmlAttribute(
            XmlName.parts('ContentType'),
            'application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml',
          ),
        ]),
      );
      final bytes = utf8.encode(types.toXmlString());
      archive.addFile(ArchiveFile('[Content_Types].xml', bytes.length, bytes));
    }
  }
  return ZipEncoder().encode(archive);
}

Uint8List encodeXlsxTable(List<List<String>> rows) {
  _checkedTable(rows, 10000, 32);
  if (rows.fold<int>(
        0,
        (total, row) =>
            total +
            row.fold<int>(0, (sum, cell) => sum + utf8.encode(cell).length),
      ) >
      maximumExpandedBytes) {
    throw const FormatException('Export exceeds the expanded-size limit.');
  }
  if (rows.length > 10001)
    throw const FormatException('Export at most 10,000 rows.');
  final workbook = Excel.createExcel();
  for (final row in rows) {
    workbook['Sheet1'].appendRow(row.map(TextCellValue.new).toList());
  }
  final result = workbook.encode();
  if (result == null) throw StateError('Workbook encoding failed.');
  final bytes = Uint8List.fromList(result);
  _checkBytes(bytes);
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.fold<int>(
        0,
        (sum, entry) => sum + entry.uncompressedSize,
      ) >
      maximumExpandedBytes) {
    throw const FormatException('Export exceeds the expanded-size limit.');
  }
  return bytes;
}
