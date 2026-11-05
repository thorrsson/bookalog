import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bookalog_exchange/bookalog_exchange.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:uuid/uuid.dart';

import 'catalog.dart';
import 'onix.dart';

const coreMetadataColumns = [
  'title',
  'format',
  'language',
  'isbn13',
  'publication_status',
  'release_date',
  'description',
];
const coreExchangeColumns = [
  'id',
  'work_id',
  'revision',
  ...coreMetadataColumns,
];
const requiredImportColumns = [
  'title',
  'format',
  'language',
  'publication_status',
];
const coreExchangeNotice =
    'Core metadata only. Contributors, categories, cover files and work-level metadata '
    'are not included. Existing relationships and covers are preserved on import. '
    'These files are not catalog backups.';

enum CatalogExchangeFormat { csv, xlsx, onix }

class CatalogImportDocument {
  const CatalogImportDocument(this.table, {this.onixProvenance});
  final List<List<String>> table;
  final List<Map<String, String>>? onixProvenance;
  bool get isOnix => onixProvenance != null;
}

class CatalogSourceFile {
  const CatalogSourceFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

class CatalogExchangeFiles {
  Future<CatalogImportDocument> read(CatalogSourceFile source) =>
      readCatalogDocument(source);

  Future<Uint8List> encode(
    List<CatalogEdition> editions, {
    required CatalogExchangeFormat format,
    String publisher = '',
  }) => format == CatalogExchangeFormat.onix
      ? Isolate.run(
          () => encodeCatalogOnix(
            editions,
            publisher: publisher,
            sentAt: DateTime.now().toUtc(),
          ),
        )
      : exportCatalogCore(editions, xlsx: format == CatalogExchangeFormat.xlsx);

  Future<CatalogSourceFile?> pick() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Catalog exchange file',
          extensions: ['csv', 'xlsx', 'xml', 'onix'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > maximumFileBytes) {
      throw const FormatException('File exceeds 8 MiB.');
    }
    return CatalogSourceFile(file.name, await file.readAsBytes());
  }

  Future<bool> save(String name, Uint8List bytes) async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      throw UnsupportedError(
        'File export currently requires a desktop client.',
      );
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return false;
    await XFile.fromData(bytes, name: name).saveTo(location.path);
    return true;
  }
}

Future<CatalogImportDocument> readCatalogDocument(CatalogSourceFile source) =>
    Isolate.run(() => decodeCatalogDocument(source));

CatalogImportDocument decodeCatalogDocument(CatalogSourceFile source) {
  if (source.name.isEmpty || source.name.length > 200) {
    throw const FormatException('Use a filename of 1-200 characters.');
  }
  final extension = source.name.split('.').last.toLowerCase();
  if (extension == 'xml' || extension == 'onix') {
    final onix = decodeCatalogOnix(source.bytes);
    return CatalogImportDocument([
      coreExchangeColumns,
      ...onix.records.map(
        (record) => coreExchangeColumns.map((field) => record[field]!).toList(),
      ),
    ], onixProvenance: onix.provenance);
  }
  return CatalogImportDocument(switch (extension) {
    'csv' => decodeCsvTable(source.bytes),
    'xlsx' => decodeXlsxTable(source.bytes),
    _ => throw const FormatException(
      'Select UTF-8 CSV, text-only XLSX, or an ONIX 3.0 core-profile XML file.',
    ),
  });
}

Map<String, int?> inferColumnMapping(List<String> headers) {
  final mapping = <String, int?>{};
  for (final field in coreExchangeColumns) {
    final index = headers.indexWhere((header) => header.toLowerCase() == field);
    mapping[field] = index < 0 ? null : index;
  }
  return mapping;
}

Map<String, dynamic> coreMetadata(CatalogEdition record) => {
  for (final field in coreMetadataColumns)
    field: field == 'description' ? record.description : record.record[field],
};

class ImportPreviewRow {
  const ImportPreviewRow({
    required this.sourceRow,
    required this.existing,
    required this.workId,
    required this.metadata,
    required this.errors,
    this.sourceContext,
  });
  final int sourceRow;
  final CatalogEdition? existing;
  final String? workId;
  final Map<String, dynamic> metadata;
  final List<String> errors;
  final Map<String, String>? sourceContext;
  bool get unchanged =>
      existing != null &&
      coreMetadataColumns.every(
        (field) => existing!.record[field] == metadata[field],
      );
  String get action => errors.isNotEmpty
      ? 'Needs attention'
      : existing == null
      ? 'Create'
      : unchanged
      ? 'Unchanged'
      : 'Update';
  Map<String, dynamic> toRequest() => {
    'source_row': sourceRow,
    'edition_id': existing?.id,
    'work_id': workId,
    'expected_revision': existing?.revision,
    'metadata': metadata,
    if (sourceContext != null) 'source_context': sourceContext,
  };
}

class CatalogImportPlan {
  CatalogImportPlan({
    required this.sourceName,
    required this.sourceSha256,
    required this.rows,
  }) : requestId = const Uuid().v4();
  final String requestId;
  final String sourceName;
  final String sourceSha256;
  final List<ImportPreviewRow> rows;
  bool get canApply =>
      rows.isNotEmpty && rows.every((row) => row.errors.isEmpty);
}

Future<CatalogImportPlan> prepareCatalogImport(
  CatalogSourceFile source,
  List<List<String>> table,
  Map<String, int?> mapping,
  CatalogSnapshot snapshot, {
  List<Map<String, String>>? onixProvenance,
}) async {
  if (table.length < 2 || table.length > 5001) {
    throw const FormatException('Select 1-5,000 data rows.');
  }
  if (mapping.keys.any((key) => !coreExchangeColumns.contains(key)) ||
      requiredImportColumns.any((field) => mapping[field] == null) ||
      mapping.values.whereType<int>().any(
        (index) => index < 0 || index >= table.first.length,
      ) ||
      mapping.values.whereType<int>().toSet().length !=
          mapping.values.whereType<int>().length) {
    throw const FormatException(
      'Map each required field to a distinct source column.',
    );
  }
  if (onixProvenance != null &&
      (onixProvenance.length != table.length - 1 ||
          !coreExchangeColumns.every(
            (field) => mapping[field] == coreExchangeColumns.indexOf(field),
          ))) {
    throw const FormatException('ONIX uses the fixed core-profile mapping.');
  }
  final byId = {for (final record in snapshot.editions) record.id: record};
  final byIsbn = {
    for (final record in snapshot.editions)
      if (record.isbn != null) record.isbn!: record,
  };
  final workIds = snapshot.editions.map((record) => record.workId).toSet();
  final seenIds = <String>{};
  final seenIsbns = <String>{};
  final rows = <ImportPreviewRow>[];
  for (final entry in table.skip(1).indexed) {
    final cells = entry.$2;
    if (cells.length != table.first.length) {
      throw const FormatException('Row width differs from the header.');
    }
    String? value(String field) {
      final column = mapping[field];
      return column == null ? null : cells[column];
    }

    String? identity(String field) {
      final text = value(field)?.trim().toLowerCase();
      return text == null || text.isEmpty ? null : text;
    }

    final errors = <String>[];
    final id = identity('id');
    final existing = byId[id];
    final workId = identity('work_id') ?? existing?.workId;
    if (id != null && existing == null) {
      errors.add(
        'Edition ID is unknown. Use a known Bookalog ID or leave it blank to create.',
      );
    }
    if (id != null && !seenIds.add(id)) {
      errors.add('Edition ID is repeated in this file.');
    }
    if (workId != null && !workIds.contains(workId)) {
      errors.add('Work ID is unknown.');
    }
    if (existing != null && workId != existing.workId) {
      errors.add('An import cannot move an edition to another work.');
    }
    final revision = value('revision')?.trim();
    if (revision != null &&
        revision.isNotEmpty &&
        (existing == null || int.tryParse(revision) != existing.revision)) {
      errors.add('Revision differs from the catalog. Review a fresh export.');
    }
    final metadata = existing == null
        ? <String, dynamic>{
            'title': '',
            'format': '',
            'language': '',
            'isbn13': null,
            'publication_status': '',
            'release_date': null,
            'description': '',
          }
        : coreMetadata(existing);
    for (final field in coreMetadataColumns) {
      final text = value(field);
      if (text == null) continue;
      metadata[field] = field == 'description' ? text : text.trim();
      if ((field == 'isbn13' || field == 'release_date') &&
          metadata[field] == '') {
        metadata[field] = null;
      }
      if (onixProvenance != null &&
          existing != null &&
          onixLanguageCode(existing.language) != null &&
          onixLanguageCode(existing.language) ==
              onixLanguageCode(metadata['language'] as String)) {
        metadata['language'] = existing.language;
      }
    }
    final title = metadata['title'] as String;
    final language = metadata['language'] as String;
    final isbn = metadata['isbn13'] as String?;
    final release = metadata['release_date'] as String?;
    if (title.isEmpty || title.length > 500) {
      errors.add('Title must contain 1-500 characters.');
    }
    if (language.length < 2 || language.length > 35) {
      errors.add('Language must contain 2-35 characters.');
    }
    if (![
      'paperback',
      'hardback',
      'ebook',
      'audio',
    ].contains(metadata['format'])) {
      errors.add('Unsupported format.');
    }
    if (![
      'planned',
      'announced',
      'released',
      'out_of_print',
    ].contains(metadata['publication_status'])) {
      errors.add('Unsupported publication status.');
    }
    if (release != null && !isValidReleaseDate(release)) {
      errors.add('Use a real YYYY, YYYY-MM or YYYY-MM-DD release date.');
    }
    final isbnError = validateCatalogIsbn(isbn ?? '');
    if (isbnError != null) errors.add(isbnError);
    if (isbn != null) {
      if (!seenIsbns.add(isbn)) errors.add('ISBN is repeated in this file.');
      if (byIsbn[isbn] != null && byIsbn[isbn]!.id != id) {
        errors.add(
          'ISBN belongs to another edition. Match its ID explicitly; automatic merging is disabled.',
        );
      }
    }
    rows.add(
      ImportPreviewRow(
        sourceRow: entry.$1 + 2,
        existing: existing,
        workId: workId,
        metadata: Map.unmodifiable(metadata),
        errors: List.unmodifiable(errors),
        sourceContext: onixProvenance == null
            ? null
            : Map.unmodifiable(onixProvenance[entry.$1]),
      ),
    );
  }
  final hash = await Sha256().hash(source.bytes);
  return CatalogImportPlan(
    sourceName: source.name,
    sourceSha256: hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(),
    rows: List.unmodifiable(rows),
  );
}

Future<Uint8List> exportCatalogCore(
  List<CatalogEdition> editions, {
  required bool xlsx,
}) async {
  if (editions.length > 5000) {
    throw const FormatException('Export at most 5,000 editions.');
  }
  final table = [
    coreExchangeColumns,
    ...editions.map(
      (record) => coreExchangeColumns
          .map((field) => record.record[field]?.toString() ?? '')
          .toList(),
    ),
  ];
  return Isolate.run(
    () => xlsx ? encodeXlsxTable(table) : encodeCsvTable(table),
  );
}

class CatalogImportReport {
  CatalogImportReport.fromRecord(Map<String, dynamic> record)
    : record = Map.unmodifiable(record) {
    if (record['request_id'] is! String ||
        record['source_name'] is! String ||
        record['source_sha256'] is! String ||
        record['occurred_at'] is! String ||
        DateTime.tryParse(record['occurred_at'] as String) == null ||
        record['rows'] is! List ||
        [
          'created',
          'updated',
          'unchanged',
        ].any((field) => record[field] is! int || (record[field] as int) < 0)) {
      throw const FormatException(
        'The import report is invalid; check history before retrying.',
      );
    }
    final rows = record['rows'] as List;
    if (rows.isEmpty ||
        rows.length > 5000 ||
        rows.any(
          (row) =>
              row is! Map<String, dynamic> ||
              row['source_row'] is! int ||
              (row['source_row'] as int) < 2 ||
              (row['source_row'] as int) > 5001 ||
              row['edition_id'] is! String ||
              row['revision'] is! int ||
              (row['revision'] as int) < 1 ||
              !['created', 'updated', 'unchanged'].contains(row['action']),
        ) ||
        ['created', 'updated', 'unchanged'].any(
          (action) =>
              record[action] !=
              rows.where((row) => row['action'] == action).length,
        )) {
      throw const FormatException(
        'The import report counts or outcomes are invalid.',
      );
    }
    if (rows.map((row) => row['source_row']).toSet().length != rows.length ||
        rows.map((row) => row['edition_id']).toSet().length != rows.length) {
      throw const FormatException(
        'The import report repeats a row or edition.',
      );
    }
  }
  final Map<String, dynamic> record;
  String get requestId => record['request_id'] as String;
  String get sourceName => record['source_name'] as String;
  bool confirms(CatalogImportPlan plan) {
    final rows = (record['rows'] as List).cast<Map<String, dynamic>>();
    if (requestId != plan.requestId ||
        sourceName != plan.sourceName ||
        record['source_sha256'] != plan.sourceSha256 ||
        rows.length != plan.rows.length) {
      return false;
    }
    final bySource = {for (final row in rows) row['source_row'] as int: row};
    return plan.rows.every((row) {
      final result = bySource[row.sourceRow];
      final action = row.existing == null
          ? 'created'
          : row.unchanged
          ? 'unchanged'
          : 'updated';
      final revision = row.existing == null
          ? 1
          : row.existing!.revision + (row.unchanged ? 0 : 1);
      return result != null &&
          result['action'] == action &&
          result['revision'] == revision &&
          (row.existing == null || result['edition_id'] == row.existing!.id) &&
          (row.sourceContext == null ||
              (result['source_context'] is Map &&
                  (result['source_context'] as Map).length ==
                      row.sourceContext!.length &&
                  row.sourceContext!.entries.every(
                    (entry) =>
                        result['source_context'][entry.key] == entry.value,
                  )));
    });
  }

  String get summary =>
      '${record['created']} created, ${record['updated']} updated, ${record['unchanged']} unchanged';
}
