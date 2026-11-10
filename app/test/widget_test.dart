import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bookalog_catalog/catalog.dart';
import 'package:bookalog_catalog/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> editionRecord({
  String id = 'edition-1',
  String title = 'The Quiet Atlas',
  int revision = 1,
}) => {
  'id': id,
  'work_id': 'work-1',
  'title': title,
  'format': 'paperback',
  'language': 'en',
  'publication_status': 'announced',
  'revision': revision,
  'isbn13': '9780000000001',
  'release_date': '2026-04',
  'description': 'A field guide to quiet places.',
  'cover_key': 'covers/edition-1.jpg',
  'categories': ['Travel'],
  'category_refs': [
    {'id': 'category-1', 'name': 'Travel'},
  ],
  'contributors': [
    {'id': 'contributor-1', 'name': 'A. Writer', 'role': 'author'},
  ],
};

void main() {
  testWidgets('unconfigured app explains how to set up a project', (
    tester,
  ) async {
    await tester.pumpWidget(const BookalogApp());

    expect(find.text('Bookalog catalog'), findsOneWidget);
    expect(find.textContaining('SUPABASE_URL'), findsOneWidget);
    expect(find.textContaining('service-role key'), findsOneWidget);
  });

  test('edition parses metadata and searches all supported fields', () {
    final edition = CatalogEdition.fromRecord(editionRecord());

    expect(edition.title, 'The Quiet Atlas');
    expect(edition.contributors, ['A. Writer']);
    expect(edition.credits.single.contributor.id, 'contributor-1');
    expect(edition.categoryReferences.single.id, 'category-1');
    expect(edition.description, 'A field guide to quiet places.');
    expect(edition.coverKey, 'covers/edition-1.jpg');
    expect(edition.matches('quiet'), isTrue);
    expect(edition.matches('9780000000001'), isTrue);
    expect(edition.matches('travel'), isTrue);
    expect(edition.matches('writer'), isTrue);
    expect(edition.matches('nonexistent'), isFalse);
  });

  test('edition parser rejects incomplete or malformed records', () {
    expect(
      () => CatalogEdition.fromRecord({...editionRecord(), 'revision': 0}),
      throwsFormatException,
    );
    expect(
      () => CatalogEdition.fromRecord({
        ...editionRecord(),
        'contributors': [
          {'name': 'Missing role'},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => CatalogEdition.fromRecord('not an edition'),
      throwsFormatException,
    );
  });

  test('role parsing denies unknown and missing memberships', () {
    expect(CatalogRole.parse('editor'), CatalogRole.editor);
    expect(() => CatalogRole.parse(null), throwsA(isA<CatalogAccessDenied>()));
    expect(
      () => CatalogRole.parse('owner'),
      throwsA(isA<CatalogAccessDenied>()),
    );
  });

  test('offline catalog browsing never grants edit permissions', () {
    expect(canEditCatalog(CatalogRole.editor, connected: true), isTrue);
    expect(canEditCatalog(CatalogRole.administrator, connected: true), isTrue);
    expect(canEditCatalog(CatalogRole.viewer, connected: true), isFalse);
    expect(canEditCatalog(CatalogRole.editor, connected: false), isFalse);
    expect(canEditCatalog(null, connected: false), isFalse);
  });

  test(
    'only temporary connectivity failures allow verified cache recovery',
    () {
      expect(
        isTemporaryCatalogConnectivityFailure(
          const SocketException('network unavailable'),
        ),
        isTrue,
      );
      expect(
        isTemporaryCatalogConnectivityFailure(
          AuthRetryableFetchException(message: 'temporarily unavailable'),
        ),
        isTrue,
      );
      expect(
        isTemporaryCatalogConnectivityFailure(const AuthException('revoked')),
        isFalse,
      );
      expect(
        isTemporaryCatalogConnectivityFailure(TimeoutException('timed out')),
        isTrue,
      );
      expect(
        isTemporaryCatalogConnectivityFailure(
          const CatalogAccessDenied('membership revoked'),
        ),
        isFalse,
      );
      expect(
        isTemporaryCatalogConnectivityFailure(
          const FormatException('invalid response'),
        ),
        isFalse,
      );
    },
  );

  test('membership records preserve email, role, and active state', () {
    final member = CatalogMember.fromRecord({
      'user_id': 'member-1',
      'email': 'reader@example.com',
      'role': 'viewer',
      'active': false,
    });

    expect(member.userId, 'member-1');
    expect(member.email, 'reader@example.com');
    expect(member.role, CatalogRole.viewer);
    expect(member.active, isFalse);
    expect(
      () => CatalogMember.fromRecord({
        'user_id': 'member-2',
        'email': 'reader@example.com',
        'role': 'owner',
        'active': true,
      }),
      throwsA(isA<CatalogAccessDenied>()),
    );
  });

  test(
    'catalog filters combine across views without losing date precision',
    () {
      final edition = CatalogEdition.fromRecord(editionRecord());
      const filters = CatalogFilters(
        categoryQuery: 'trav',
        contributorQuery: 'writer',
        publicationStatus: 'announced',
        releaseDatePrefix: '2026-04',
      );

      expect(filters.matches(edition), isTrue);
      expect(
        const CatalogFilters(releaseDatePrefix: '2026-04-15').matches(edition),
        isFalse,
      );
      expect(isValidReleaseDate('2026'), isTrue);
      expect(isValidReleaseDate('2026-04'), isTrue);
      expect(isValidReleaseDate('2024-02-29'), isTrue);
      expect(isValidReleaseDate('2026-02-29'), isFalse);
      expect(const CatalogFilters().isEmpty, isTrue);
    },
  );

  test('relationship filters use identity rather than matching names', () {
    final first = CatalogEdition.fromRecord(editionRecord());
    final namesake = CatalogEdition.fromRecord({
      ...editionRecord(id: 'edition-2'),
      'contributors': [
        {'id': 'contributor-2', 'name': 'A. Writer', 'role': 'author'},
      ],
    });
    const filter = CatalogFilters(
      contributorId: 'contributor-1',
      contributorQuery: 'A. Writer',
      categoryId: 'category-1',
      categoryQuery: 'Travel',
      workId: 'work-1',
    );
    expect(filter.matches(first), isTrue);
    expect(filter.matches(namesake), isFalse);
    expect(
      filter.without(CatalogFilterField.contributor).matches(namesake),
      isTrue,
    );
    expect(
      filter.without(CatalogFilterField.category).contributorId,
      'contributor-1',
    );
    expect(
      const CatalogFilters(workId: 'another-work').matches(first),
      isFalse,
    );
    expect(const CatalogFilters(workId: 'work-1').isEmpty, isFalse);
  });

  test(
    'relationship drafts retain existing IDs and explicit new identities',
    () {
      final credit = CatalogEdition.fromRecord(editionRecord()).credits.single;
      expect(credit.toInput(), {'id': 'contributor-1', 'role': 'author'});
      expect(
        const CatalogCredit(
          contributor: CatalogReference(id: null, name: ' New person '),
          role: ' translator ',
        ).toInput(),
        {'name': 'New person', 'role': 'translator'},
      );
      expect(
        () => CatalogEdition.fromRecord({
          ...editionRecord(),
          'category_refs': [
            {'id': 'category-1', 'name': 'Wrong name'},
          ],
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'release ranges use interval overlap without inventing precise dates',
    () {
      const filter = CatalogFilters(
        releaseFrom: '2026-04-15',
        releaseThrough: '2026-05-04',
      );
      CatalogEdition dated(String? value) => CatalogEdition.fromRecord({
        ...editionRecord(),
        'release_date': value,
      });
      expect(filter.matches(dated('2026')), isTrue);
      expect(filter.matches(dated('2026-04')), isTrue);
      expect(filter.matches(dated('2026-05-04')), isTrue);
      expect(filter.matches(dated('2026-04-14')), isFalse);
      expect(filter.matches(dated('2026-03')), isFalse);
      expect(filter.matches(dated(null)), isFalse);
      expect(releaseDateBounds('2024-02').end, DateTime.utc(2024, 2, 29));
      expect(
        sixMonthsAfter(DateTime.utc(2023, 8, 31)),
        DateTime.utc(2024, 2, 29),
      );
      expect(
        sixMonthsAfter(DateTime.utc(2024, 8, 31)),
        DateTime.utc(2025, 2, 28),
      );
      expect(filter.without(CatalogFilterField.releaseRange).isEmpty, isTrue);
    },
  );

  test(
    'sorting is deterministic and keeps unknown dates last in both directions',
    () {
      final earlier = CatalogEdition.fromRecord(editionRecord(id: 'a'));
      final later = CatalogEdition.fromRecord({
        ...editionRecord(id: 'b'),
        'release_date': '2027',
      });
      final undated = CatalogEdition.fromRecord({
        ...editionRecord(id: 'c'),
        'release_date': null,
      });
      final records = [undated, later, earlier];
      expect(
        sortedCatalog(records, CatalogSort.releaseDate, true).map((e) => e.id),
        ['a', 'b', 'c'],
      );
      expect(
        sortedCatalog(records, CatalogSort.releaseDate, false).map((e) => e.id),
        ['b', 'a', 'c'],
      );
      expect(
        sortedCatalog(records, CatalogSort.title, false).map((e) => e.id),
        ['a', 'b', 'c'],
      );
      expect(records.first.id, 'c');
    },
  );

  test('cover uploads accept only recognized image signatures', () {
    expect(detectCoverFormat(Uint8List.fromList([0xff, 0xd8, 0xff])), 'jpg');
    expect(
      detectCoverFormat(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      ),
      'png',
    );
    expect(
      detectCoverFormat(
        Uint8List.fromList([
          ...'RIFF'.codeUnits,
          0x00,
          0x00,
          0x00,
          0x00,
          ...'WEBP'.codeUnits,
        ]),
      ),
      'webp',
    );
    expect(
      detectCoverFormat(Uint8List.fromList('not an image'.codeUnits)),
      isNull,
    );
  });

  test('snapshot replaces a saved edition without changing other records', () {
    final first = CatalogEdition.fromRecord(editionRecord());
    final second = CatalogEdition.fromRecord(
      editionRecord(id: 'edition-2', title: 'Second edition'),
    );
    final snapshot = CatalogSnapshot(
      role: CatalogRole.editor,
      editions: [first, second],
    );

    final updated = first.withRecord(
      editionRecord(title: 'New title', revision: 2),
    );
    final next = snapshot.replace(updated);

    expect(next.editions.first.title, 'New title');
    expect(next.editions.first.revision, 2);
    expect(next.editions.last.title, 'Second edition');
    expect(snapshot.editions.first.title, 'The Quiet Atlas');
  });

  testWidgets(
    'release calendar preserves partial dates and separates unknowns',
    (tester) async {
      final year = CatalogEdition.fromRecord({
        ...editionRecord(id: 'year'),
        'title': 'Year only release',
        'release_date': '2027',
      });
      final month = CatalogEdition.fromRecord({
        ...editionRecord(id: 'month'),
        'title': 'Month release',
        'release_date': '2027-03',
      });
      final unknown = CatalogEdition.fromRecord({
        ...editionRecord(id: 'unknown'),
        'title': 'Undated release',
        'release_date': null,
      });
      final selected = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 800,
              child: ReleaseCalendarView(
                records: [month, unknown, year],
                selectedId: null,
                onSelect: (edition) => selected.add(edition.id),
              ),
            ),
          ),
        ),
      );

      expect(find.text('March 2027'), findsOneWidget);
      expect(find.text('2027 · month not set'), findsOneWidget);
      expect(find.text('Date not set'), findsOneWidget);
      await tester.tap(find.text('Month release'));
      expect(selected, ['month']);
    },
  );
}
