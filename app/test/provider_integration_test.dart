import 'dart:convert';
import 'dart:io';

import 'package:bookalog_catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _LocalCertificateHttp extends HttpOverrides {
  _LocalCertificateHttp(String certificate)
    : context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(certificate);

  final SecurityContext context;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(this.context);
}

Future<CatalogEdition> _save(
  CatalogRepository repository,
  CatalogEdition edition, {
  required String title,
  required String? coverKey,
}) => repository.updateMetadata(
  edition,
  title: title,
  format: edition.format,
  language: edition.language,
  isbn: edition.isbn,
  publicationStatus: edition.publicationStatus,
  releaseDate: edition.releaseDate,
  description: edition.description,
  coverKey: coverKey,
);

void main() {
  final directory = Platform.environment['BOOKALOG_SERVICE_TEST_DIRECTORY'];

  test(
    'actual Supabase SDK and catalog repository use the local provider',
    () async {
      final status = jsonDecode(
        File('$directory/status.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final fixture = jsonDecode(
        File('$directory/client-fixture.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final url = status['API_URL'] as String;
      final origin = Uri.parse(url);
      expect(origin.scheme, 'https');
      expect(origin.host, '127.0.0.1');
      await HttpOverrides.runWithHttpOverrides(() async {
        final clients = <String, SupabaseClient>{};
        try {
          for (final role in [
            'administrator',
            'editor',
            'viewer',
            'unapproved',
          ]) {
            final client = SupabaseClient(url, status['ANON_KEY'] as String);
            clients[role] = client;
            final credentials = fixture['accounts'][role];
            final identity = await client.auth.signInWithPassword(
              email: credentials['email'] as String,
              password: credentials['password'] as String,
            );
            expect(identity.user, isNotNull);
          }
          final administrator = CatalogRepository(clients['administrator']!);
          final editor = CatalogRepository(clients['editor']!);
          final viewer = CatalogRepository(clients['viewer']!);
          final unapproved = CatalogRepository(clients['unapproved']!);
          await expectLater(
            unapproved.loadCatalog(),
            throwsA(isA<CatalogAccessDenied>()),
          );
          await expectLater(
            viewer.loadCatalog(),
            throwsA(isA<CatalogAccessDenied>()),
          );
          final viewerId = clients['viewer']!.auth.currentUser!.id;
          final approved = await administrator.updateMember(
            userId: viewerId,
            role: CatalogRole.viewer,
            active: true,
          );
          expect(approved.active, isTrue);
          expect(await administrator.loadMembers(), hasLength(3));
          expect((await viewer.loadCatalog()).role, CatalogRole.viewer);
          await expectLater(
            editor.loadMembers(),
            throwsA(
              isA<PostgrestException>().having(
                (error) => error.code,
                'code',
                '42501',
              ),
            ),
          );

          final snapshot = await editor.loadCatalog();
          expect(snapshot.role, CatalogRole.editor);
          expect(snapshot.editions, hasLength(2));
          final original = snapshot.editions.singleWhere(
            (edition) => edition.id == fixture['editionId'],
          );
          await expectLater(
            _save(
              viewer,
              original,
              title: 'Denied',
              coverKey: original.coverKey,
            ),
            throwsA(
              isA<PostgrestException>().having(
                (error) => error.code,
                'code',
                '42501',
              ),
            ),
          );
          final updated = await _save(
            editor,
            original,
            title: 'Saved through Dart',
            coverKey: original.coverKey,
          );
          expect(updated.revision, original.revision + 1);
          await expectLater(
            _save(
              editor,
              original,
              title: 'Stale',
              coverKey: original.coverKey,
            ),
            throwsA(
              isA<PostgrestException>().having(
                (error) => error.code,
                'code',
                'PT409',
              ),
            ),
          );
          final additional = await editor.createEdition(
            workId: original.workId,
            title: 'Dart additional edition',
            format: 'audio',
            language: 'en',
            isbn: null,
            publicationStatus: 'planned',
            releaseDate: '2032',
            description: '',
          );
          expect(additional.workId, original.workId);
          final options = await editor.loadRelationOptions();
          final related = await editor.updateRelations(
            additional,
            credits: [
              CatalogCredit(
                contributor: options.contributors.first,
                role: 'author',
              ),
            ],
            categories: [options.categories.first],
          );
          expect(
            related.credits.single.contributor.id,
            options.contributors.first.id,
          );
          expect(
            related.categoryReferences.single.id,
            options.categories.first.id,
          );

          final bytes = await File('$directory/cover.png').readAsBytes();
          final coverKey = await editor.uploadCover(
            editionId: related.id,
            bytes: bytes,
            extension: 'png',
            contentType: 'image/png',
          );
          final covered = await _save(
            editor,
            related,
            title: related.title,
            coverKey: coverKey,
          );
          final signed = Uri.parse(await viewer.signedCoverUrl(coverKey));
          expect(signed.origin, origin.origin);
          final http = HttpClient();
          try {
            final response = await (await http.getUrl(signed)).close();
            expect(response.statusCode, 200);
            final downloaded = await response.fold<List<int>>(
              [],
              (result, chunk) => result..addAll(chunk),
            );
            expect(downloaded, orderedEquals(bytes));
          } finally {
            http.close(force: true);
          }
          expect(
            await clients['viewer']!.storage.from('book-covers').remove([
              coverKey,
            ]),
            isEmpty,
          );
          await expectLater(
            viewer.removeCover(coverKey),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                contains('not confirmed'),
              ),
            ),
          );
          expect(
            await clients['editor']!.storage
                .from('book-covers')
                .download(coverKey),
            orderedEquals(bytes),
          );
          final input = fixture['importRequest'] as Map<String, dynamic>;
          final report = await editor.importMetadata(
            requestId: input['p_request_id'] as String,
            sourceName: input['p_source_name'] as String,
            sourceSha256: input['p_source_sha256'] as String,
            rows: (input['p_rows'] as List)
                .map((row) => row as Map<String, dynamic>)
                .toList(),
          );
          expect(report, fixture['importReport']);
          expect(await editor.loadImportReports(), contains(equals(report)));
          await clients['editor']!.auth.refreshSession();
          expect((await editor.loadCatalog()).editions, hasLength(3));
          await administrator.updateMember(
            userId: viewerId,
            role: CatalogRole.viewer,
            active: false,
          );
          await expectLater(
            viewer.loadCatalog(),
            throwsA(isA<CatalogAccessDenied>()),
          );
          await _save(editor, covered, title: covered.title, coverKey: null);
          await editor.removeCover(coverKey);
          await expectLater(
            clients['editor']!.storage.from('book-covers').download(coverKey),
            throwsA(isA<StorageException>()),
          );
          await clients['editor']!.auth.signOut();
          expect(clients['editor']!.auth.currentSession, isNull);
        } finally {
          for (final client in clients.values) {
            await client.dispose();
          }
        }
      }, _LocalCertificateHttp('$directory/ca.pem'));
    },
    skip: directory == null
        ? 'Run through script/test-supabase-services.sh for disposable live services.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
