import 'dart:convert';

import 'package:csv/csv.dart';

class Edition {
  final Map<String, dynamic> record;
  Edition(this.record) {
    for (final field in [
      'id',
      'work_id',
      'title',
      'format',
      'publication_status',
    ]) {
      if (record[field] is! String ||
          (record[field] as String).trim().isEmpty) {
        throw FormatException('Edition field $field must be nonempty text.');
      }
    }
    if (record['contributors'] is! List ||
        record['categories'] is! List ||
        record['revision'] is! int ||
        record['revision'] < 1) {
      throw const FormatException('Invalid edition relationships or revision.');
    }
    for (final credit in record['contributors']) {
      if (credit is! Map ||
          credit['name'] is! String ||
          credit['role'] is! String) {
        throw const FormatException('Invalid contributor.');
      }
    }
    if (!(record['categories'] as List).every((value) => value is String)) {
      throw const FormatException('Categories must be text.');
    }
    if (record['isbn13'] != null && record['isbn13'] is! String) {
      throw const FormatException('ISBNs must be text.');
    }
    if (record['release_date'] != null) {
      final date = record['release_date'];
      if (date is! String ||
          !RegExp(r'^[1-9]\d{3}(-\d{2}(-\d{2})?)?$').hasMatch(date)) {
        throw const FormatException('Invalid publication date.');
      }
      final parts = date.split('-').map(int.parse).toList();
      final parsed = DateTime.utc(
        parts[0],
        parts.length > 1 ? parts[1] : 1,
        parts.length > 2 ? parts[2] : 1,
      );
      if (parsed.year != parts[0] ||
          (parts.length > 1 && parsed.month != parts[1]) ||
          (parts.length > 2 && parsed.day != parts[2])) {
        throw const FormatException('Invalid publication date.');
      }
    }
  }
  String get title => record['title'] as String;
  String get id => record['id'] as String;
  String get format => record['format'] as String;
  String? get releaseDate => record['release_date'] as String?;
  String? get isbn => record['isbn13'] as String?;
  bool matches(String query) =>
      [
        title,
        isbn ?? '',
        ...record['contributors'].map((credit) => credit['name']),
        ...record['categories'],
      ].any(
        (value) => (value as String).toLowerCase().contains(
          query.trim().toLowerCase(),
        ),
      );
}

List<Edition> decodeCatalog(String source) {
  final data = jsonDecode(source);
  if (data is! Map<String, dynamic> ||
      data['synthetic'] != true ||
      data['editions'] is! List) {
    throw const FormatException(
      'Only the synthetic comparison catalog is accepted.',
    );
  }
  return (data['editions'] as List).map((value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid edition object.');
    }
    return Edition(value);
  }).toList();
}

const exchangeColumns = [
  'id',
  'work_id',
  'title',
  'format',
  'isbn13',
  'publication_status',
  'release_date',
];

String csvProjection(List<Edition> editions) {
  String safe(Object? value) {
    final text = value?.toString() ?? '';
    return RegExp(r'^[\s]*[=+\-@]').hasMatch(text) ? "'$text" : text;
  }

  return const ListToCsvConverter().convert([
    exchangeColumns,
    ...editions.map(
      (row) =>
          exchangeColumns.map((column) => safe(row.record[column])).toList(),
    ),
  ]);
}

int previewCsv(String source) {
  final rows = const CsvToListConverter(
    shouldParseNumbers: false,
    allowInvalid: false,
  ).convert(source.replaceAll('\r\n', '\n'), eol: '\n');
  if (rows.isEmpty || rows.first.join('|') != exchangeColumns.join('|')) {
    throw const FormatException('Expected the seven comparison CSV columns.');
  }
  if (rows.skip(1).any((row) => row.length != exchangeColumns.length)) {
    throw const FormatException('A CSV row has the wrong number of columns.');
  }
  return rows.length - 1;
}

bool canReadOffline({
  required int verifiedAt,
  required int now,
  required int lastSeenAt,
  required bool accountMatches,
  required bool revoked,
}) =>
    accountMatches &&
    !revoked &&
    lastSeenAt >= verifiedAt &&
    now >= lastSeenAt &&
    now < verifiedAt + const Duration(hours: 24).inMilliseconds;
