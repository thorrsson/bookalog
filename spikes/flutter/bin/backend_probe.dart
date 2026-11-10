import 'dart:convert';
import 'dart:io';

import 'package:bookalog_flutter_spike/backend.dart';
import 'package:bookalog_flutter_spike/catalog.dart';
import 'package:bookalog_flutter_spike/exchange.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> expectFailure(
  int status,
  Future<dynamic> Function() action,
) async {
  try {
    await action();
  } on BackendFailure catch (failure) {
    check(
      failure.status == status,
      'Expected HTTP $status, received ${failure.status}.',
    );
    return;
  }
  throw StateError('Expected HTTP $status, but operation succeeded.');
}

Future<void> main() async {
  final config = Platform.environment['BOOKALOG_MATRIX_CASES'];
  if (config == null) throw StateError('Use script/test-matrix.sh.');
  final cases = jsonDecode(config) as List;
  for (final item in cases) {
    Backend connect(String token) => Backend(
      provider: Provider.values.byName(item['provider'] as String),
      baseUrl: item['base_url'] as String,
      accessToken: token,
    );
    final viewer = connect(item['viewer_token'] as String);
    final editor = connect(item['editor_token'] as String);
    final invalid = connect('invalid-test-token');
    final unapproved = connect(item['unapproved_token'] as String);
    try {
      final rows = await viewer.load();
      check(
        rows.length == 5000 && viewer.role == 'viewer',
        'Incomplete or unauthorized catalog.',
      );
      final row = rows.first;
      await expectFailure(403, () => viewer.saveTitle(row, 'Denied Dart edit'));
      await expectFailure(401, invalid.load);
      await expectFailure(403, unapproved.load);
      final saved = await editor.saveTitle(row, 'Dart matrix title');
      check(
        saved.title == 'Dart matrix title',
        'Saved title did not round-trip.',
      );
      await expectFailure(409, () => editor.saveTitle(row, 'Stale Dart edit'));
    } finally {
      viewer.close();
      editor.close();
      invalid.close();
      unapproved.close();
    }
  }
  final output = Platform.environment['BOOKALOG_MATRIX_OUTPUT_DIR'];
  if (output != null) {
    final editions = decodeCatalog(
      File('assets/catalog.json').readAsStringSync(),
    );
    await File('$output/dart.xlsx').writeAsBytes(xlsxProjection(editions));
    await File('$output/dart.xml').writeAsBytes(onixProjection(editions));
  }
  stdout.writeln(
    'Dart: both backend paths passed list, membership, editing, and conflict checks.',
  );
}
