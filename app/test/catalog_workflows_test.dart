import 'dart:convert';
import 'dart:io';

import 'package:bookalog_catalog/appearance.dart';
import 'package:bookalog_catalog/catalog.dart';
import 'package:bookalog_catalog/design.dart';
import 'package:bookalog_catalog/main.dart';
import 'package:bookalog_catalog/relationships.dart';
import 'package:bookalog_catalog/offline_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'widget_test.dart' show editionRecord;
import 'offline_fixtures.dart';

class _Repository extends CatalogRepository {
  _Repository(this.client) : super(client);

  final SupabaseClient client;
  Object? loadError;
  Object? createError;
  String? offlineLeaseToken;
  String? createdWorkId;
  List<CatalogCredit>? savedCredits;
  List<CatalogReference>? savedCategories;
  CatalogRole role = CatalogRole.administrator;
  final records = [
    CatalogEdition.fromRecord({...editionRecord(), 'cover_key': null}),
    CatalogEdition.fromRecord({
      ...editionRecord(id: 'edition-2', title: 'The Other Atlas'),
      'work_id': 'work-2',
      'cover_key': null,
      'contributors': [
        {'id': 'contributor-2', 'name': 'A. Writer', 'role': 'author'},
      ],
    }),
  ];

  @override
  Future<CatalogSnapshot> loadCatalog() async {
    if (loadError case final error?) throw error;
    return CatalogSnapshot(role: role, editions: List.unmodifiable(records));
  }

  @override
  Future<List<CatalogMember>> loadMembers() async => const [
    CatalogMember(
      userId: 'other-member',
      email: 'editor@example.invalid',
      role: CatalogRole.editor,
      active: true,
    ),
  ];

  @override
  Future<String> requestOfflineLease() async => offlineLeaseToken!;

  @override
  Future<CatalogRelationOptions> loadRelationOptions() async =>
      CatalogRelationOptions(
        contributors: records
            .map((record) => record.credits.single.contributor)
            .toList(),
        categories: records.first.categoryReferences,
      );

  @override
  Future<CatalogEdition> createEdition({
    String? workId,
    required String title,
    required String format,
    required String language,
    required String? isbn,
    required String publicationStatus,
    required String? releaseDate,
    required String description,
  }) async {
    if (createError case final error?) throw error;
    createdWorkId = workId;
    return CatalogEdition.fromRecord({
      ...editionRecord(id: 'created-edition', title: title),
      'work_id': workId ?? 'created-work',
      'format': format,
      'language': language,
      'isbn13': isbn,
      'publication_status': publicationStatus,
      'release_date': releaseDate,
      'description': description,
      'cover_key': null,
      'contributors': <Object>[],
      'categories': <Object>[],
      'category_refs': <Object>[],
    });
  }

  @override
  Future<CatalogEdition> updateRelations(
    CatalogEdition edition, {
    required List<CatalogCredit> credits,
    required List<CatalogReference> categories,
  }) async {
    savedCredits = List.of(credits);
    savedCategories = List.of(categories);
    final sorted = [...categories]..sort((a, b) => a.name.compareTo(b.name));
    return CatalogEdition.fromRecord({
      ...edition.record,
      'revision': edition.revision + 1,
      'contributors': [
        for (final (index, credit) in credits.indexed)
          {
            'id': credit.contributor.id ?? 'new-contributor-$index',
            'name': credit.contributor.name,
            'role': credit.role,
          },
      ],
      'categories': sorted.map((category) => category.name).toList(),
      'category_refs': [
        for (final (index, category) in sorted.indexed)
          {'id': category.id ?? 'new-category-$index', 'name': category.name},
      ],
    });
  }
}

void main() {
  late _Repository repository;

  setUp(() async {
    final client = SupabaseClient(
      'https://catalog.invalid',
      'test-publishable-key',
    );
    repository = _Repository(client);
    await client.auth.setInitialSession(
      jsonEncode({
        'access_token': 'disposable-test-token',
        'refresh_token': 'disposable-refresh-token',
        'expires_in': 3600,
        'token_type': 'bearer',
        'user': {
          'id': offlineTestSubject,
          'aud': 'authenticated',
          'app_metadata': <String, Object>{},
          'user_metadata': <String, Object>{},
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      }),
    );
    addTearDown(client.dispose);
  });

  Future<void> openCatalog(
    WidgetTester tester, {
    double width = 1280,
    double height = 1000,
    OfflineCatalogCache? offlineCache,
    AppearanceController? appearance,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final screen = CatalogScreen(
      client: repository.client,
      repository: repository,
      offlineCache: offlineCache,
    );
    await tester.pumpWidget(
      appearance == null
          ? MaterialApp(theme: theme, home: screen)
          : AppearanceScope(
              controller: appearance,
              child: ValueListenableBuilder(
                valueListenable: appearance,
                builder: (context, mode, _) => MaterialApp(
                  theme: ThemeData(brightness: Brightness.light),
                  darkTheme: ThemeData(brightness: Brightness.dark),
                  themeMode: mode,
                  home: screen,
                ),
              ),
            ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sidebar appearance switch applies and saves the choice', (
    tester,
  ) async {
    final saved = <ThemeMode>[];
    final appearance = AppearanceController(
      ThemeMode.light,
      (mode) async => saved.add(mode),
    );
    await openCatalog(tester, appearance: appearance);
    BuildContext screen() => tester.element(find.byType(CatalogScreen));
    expect(Theme.of(screen()).brightness, Brightness.light);

    await tester.tap(find.byTooltip('Dark appearance'));
    await tester.pumpAndSettle();

    expect(appearance.value, ThemeMode.dark);
    expect(saved, [ThemeMode.dark]);
    expect(Theme.of(screen()).brightness, Brightness.dark);
  });

  testWidgets('compact tools menu offers appearance choices', (tester) async {
    final appearance = AppearanceController();
    await openCatalog(tester, width: 1020, appearance: appearance);
    expect(find.byTooltip('Dark appearance'), findsNothing);

    await tester.tap(find.byTooltip('Catalog tools'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Light'),
    );
    await tester.pumpAndSettle();

    expect(appearance.value, ThemeMode.light);
  });

  testWidgets('appearance controls stay hidden without a scope', (
    tester,
  ) async {
    await openCatalog(tester);
    expect(find.text('Appearance'), findsNothing);
    expect(find.byTooltip('Dark appearance'), findsNothing);
  });

  testWidgets('edition form groups fields with space for labels and helpers', (
    tester,
  ) async {
    await openCatalog(tester, theme: buildBookalogTheme(Brightness.light));
    await tester.tap(find.byTooltip('Add edition'));
    await tester.pumpAndSettle();

    final title = tester.getRect(find.widgetWithText(TextField, 'Title'));
    final format = tester.getRect(
      find.widgetWithText(DropdownButtonFormField<String>, 'Format'),
    );
    final language = tester.getRect(
      find.widgetWithText(TextField, 'Language code'),
    );
    final isbn = tester.getRect(find.widgetWithText(TextField, 'ISBN-13'));
    final status = tester.getRect(
      find.widgetWithText(
        DropdownButtonFormField<String>,
        'Publication status',
      ),
    );
    final release = tester.getRect(
      find.widgetWithText(TextField, 'Release date'),
    );
    final description = tester.getRect(
      find.widgetWithText(TextField, 'Description'),
    );

    expect(format.top - title.bottom, greaterThanOrEqualTo(16));
    expect(format.top, closeTo(language.top, 0.1));
    expect(language.left - format.right, greaterThanOrEqualTo(16));
    expect(isbn.top - format.bottom, greaterThanOrEqualTo(16));
    expect(isbn.top, closeTo(status.top, 0.1));
    expect(status.left - isbn.right, greaterThanOrEqualTo(16));
    expect(release.top - isbn.bottom, greaterThanOrEqualTo(16));
    expect(description.top - release.bottom, greaterThanOrEqualTo(16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('edition form stacks and stays usable with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 600);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    CatalogEdition? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildBookalogTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showDialog<CatalogEdition>(
                  context: context,
                  builder: (context) => EditionMetadataDialog(
                    repository: repository,
                    edition: null,
                  ),
                );
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    final format = tester.getRect(
      find.widgetWithText(DropdownButtonFormField<String>, 'Format'),
    );
    final language = tester.getRect(
      find.widgetWithText(TextField, 'Language code'),
    );
    expect(language.top - format.bottom, greaterThanOrEqualTo(16));
    final scrollbar = find.descendant(
      of: find.byType(EditionMetadataDialog),
      matching: find.byType(Scrollbar),
    );
    expect(scrollbar, findsOneWidget);
    expect(tester.widget<Scrollbar>(scrollbar).thumbVisibility, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Create edition'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a title between 1 and 500 characters.').hitTestable(),
      findsOneWidget,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'A usable catalog form',
    );
    await tester.ensureVisible(find.widgetWithText(TextField, 'Description'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'The draft remains editable in a short window.',
    );
    repository.createError = StateError('Unable to save. ${'details ' * 150}');
    await tester.tap(find.text('Create edition'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unable to save.'), findsOneWidget);
    expect(find.text('Create edition').hitTestable(), findsOneWidget);
    final errorScroll = find.descendant(
      of: find.byType(ShelfDialogTitle),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(errorScroll).position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(errorScroll, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    expect(tester.takeException(), isNull);

    repository.createError = null;
    await tester.tap(find.text('Create edition'));
    await tester.pumpAndSettle();
    expect(saved?.title, 'A usable catalog form');
    expect(saved?.description, 'The draft remains editable in a short window.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter validation stays visible in a short dialog', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openCatalog(
      tester,
      width: 1280,
      height: 600,
      theme: buildBookalogTheme(Brightness.light),
    );
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Release date starts with'),
      'not-a-date',
    );
    await tester.tap(find.text('Apply filters'));
    await tester.pumpAndSettle();
    expect(
      find
          .text('Use a real date in YYYY, YYYY-MM, or YYYY-MM-DD format.')
          .hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter fields use the same spacing and logical groups', (
    tester,
  ) async {
    await openCatalog(tester, theme: buildBookalogTheme(Brightness.light));
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();

    final category = tester.getRect(
      find.widgetWithText(TextField, 'Category contains'),
    );
    final contributor = tester.getRect(
      find.widgetWithText(TextField, 'Contributor contains'),
    );
    final from = tester.getRect(
      find.widgetWithText(TextField, 'Release range: from'),
    );
    final through = tester.getRect(
      find.widgetWithText(TextField, 'Release range: through'),
    );
    expect(category.top, closeTo(contributor.top, 0.1));
    expect(contributor.left - category.right, greaterThanOrEqualTo(16));
    expect(from.top, closeTo(through.top, 0.1));
    expect(through.left - from.right, greaterThanOrEqualTo(16));

    await tester.enterText(
      find.widgetWithText(TextField, 'Release range: from'),
      '2030-01-01',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Release range: through'),
      '2030-12-31',
    );
    await tester.tap(find.text('Apply filters'));
    await tester.pumpAndSettle();
    expect(find.text('Filter catalog'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('membership dialogs separate controls and fit short windows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 520);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildBookalogTheme(Brightness.light),
        home: MembershipManagementScreen(
          repository: repository,
          currentUserId: 'current-user',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add member'));
    await tester.pumpAndSettle();

    final email = tester.getRect(
      find.widgetWithText(TextField, 'Account email'),
    );
    final role = tester.getRect(
      find.widgetWithText(DropdownButtonFormField<CatalogRole>, 'Catalog role'),
    );
    expect(role.top - email.bottom, greaterThanOrEqualTo(16));
    await tester.tap(find.text('Grant access'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a valid account email address.').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change editor@example.invalid access'));
    await tester.pumpAndSettle();
    expect(find.text('Member access'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'network fallback is read-only and denied access cannot resurface',
    (tester) async {
      final fixture = await OfflineFixture.create(
        now: DateTime.now,
        role: CatalogRole.administrator,
      );
      repository.offlineLeaseToken = fixture.token;
      await openCatalog(tester, offlineCache: fixture.cache);
      expect(find.text('2 matching editions'), findsOneWidget);
      repository.loadError = const SocketException('disconnected');
      await tester.tap(find.byTooltip('Reload catalog'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('verified saved catalog read-only'),
        findsOneWidget,
      );
      expect(find.text('2 matching editions'), findsOneWidget);
      expect(find.byTooltip('Add edition'), findsNothing);
      expect(find.byTooltip('Manage members'), findsNothing);
      await tester.tap(find.text('The Quiet Atlas'));
      await tester.pumpAndSettle();
      expect(find.text('Edit edition'), findsNothing);
      expect(find.text('Add another edition'), findsNothing);
      repository.loadError = const CatalogAccessDenied('Membership revoked.');
      await tester.tap(find.byTooltip('Reload catalog'));
      await tester.pumpAndSettle();
      expect(find.text('The Quiet Atlas'), findsNothing);
      expect(find.text('Catalog access is not approved'), findsOneWidget);
      repository.loadError = const SocketException('disconnected again');
      await tester.tap(find.byTooltip('Reload catalog'));
      await tester.pumpAndSettle();
      expect(find.text('The Quiet Atlas'), findsNothing);
      expect(
        find.textContaining('verified saved catalog read-only'),
        findsNothing,
      );
    },
  );

  testWidgets('offline startup restores only a verified saved catalog', (
    tester,
  ) async {
    final fixture = await OfflineFixture.create(
      now: DateTime.now,
      role: CatalogRole.administrator,
    );
    await fixture.cache.save(
      subject: offlineTestSubject,
      snapshot: CatalogSnapshot(
        role: repository.role,
        editions: repository.records,
      ),
      leaseToken: fixture.token,
      generation: fixture.cache.generation,
    );
    repository.loadError = const SocketException('offline at startup');
    await openCatalog(tester, offlineCache: fixture.cache);
    expect(find.text('2 matching editions'), findsOneWidget);
    expect(
      find.textContaining('verified saved catalog read-only'),
      findsOneWidget,
    );
    expect(find.byTooltip('Add edition'), findsNothing);
  });

  testWidgets('expired offline access clears the stored copy', (tester) async {
    var clock = DateTime.now().subtract(const Duration(hours: 24));
    final fixture = await OfflineFixture.create(
      now: () => clock,
      role: CatalogRole.administrator,
    );
    await fixture.cache.save(
      subject: offlineTestSubject,
      snapshot: CatalogSnapshot(
        role: repository.role,
        editions: repository.records,
      ),
      leaseToken: fixture.token,
      generation: fixture.cache.generation,
    );
    clock = DateTime.now();
    repository.loadError = const SocketException('offline at startup');
    await openCatalog(tester, offlineCache: fixture.cache);
    expect(find.text('Offline access unavailable'), findsOneWidget);
    expect(find.text('The Quiet Atlas'), findsNothing);
    expect(fixture.storage.files, isEmpty);
    expect(fixture.storage.protected, isEmpty);
  });

  testWidgets(
    'an unsigned in-memory snapshot is not an offline authorization',
    (tester) async {
      await openCatalog(tester);
      repository.loadError = const SocketException('disconnected');
      await tester.tap(find.byTooltip('Reload catalog'));
      await tester.pumpAndSettle();
      expect(find.text('Offline access unavailable'), findsOneWidget);
      expect(find.text('The Quiet Atlas'), findsNothing);
    },
  );

  testWidgets('details filter exact contributor identity across views', (
    tester,
  ) async {
    await openCatalog(tester);
    await tester.tap(find.text('The Quiet Atlas'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('A. Writer · author'));
    await tester.tap(find.text('A. Writer · author'));
    await tester.pumpAndSettle();
    expect(find.text('1 matching edition'), findsOneWidget);
    expect(find.text('The Other Atlas'), findsNothing);
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    expect(find.text('1 matching edition'), findsOneWidget);
    expect(find.text('The Quiet Atlas'), findsWidgets);
    expect(find.text('The Other Atlas'), findsNothing);
    await tester.tap(find.text('Release calendar'));
    await tester.pumpAndSettle();
    expect(find.text('The Other Atlas'), findsNothing);
  });

  testWidgets(
    'intermediate width opens details rather than losing the selection',
    (tester) async {
      await openCatalog(tester, width: 1020);
      await tester.tap(find.text('The Quiet Atlas'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('The Quiet Atlas'),
        ),
        findsWidgets,
      );
      expect(find.text('Edit edition'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('additional edition retains work identity without copying ISBN', (
    tester,
  ) async {
    await openCatalog(tester);
    await tester.tap(find.text('The Quiet Atlas'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add another edition'));
    await tester.tap(find.text('Add another edition'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Adds an edition to the selected work'),
      findsOneWidget,
    );
    final isbn = tester.widget<TextField>(
      find.widgetWithText(TextField, 'ISBN-13'),
    );
    expect(isbn.controller!.text, isEmpty);
    await tester.tap(find.text('Create edition'));
    await tester.pumpAndSettle();
    expect(repository.createdWorkId, 'work-1');
    expect(find.text('3 matching editions'), findsOneWidget);
  });

  testWidgets('table headers sort without changing the catalog selection', (
    tester,
  ) async {
    await openCatalog(tester);
    expect(
      tester.getTopLeft(find.text('The Other Atlas')).dy,
      lessThan(tester.getTopLeft(find.text('The Quiet Atlas')).dy),
    );
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('The Quiet Atlas')).dy,
      lessThan(tester.getTopLeft(find.text('The Other Atlas')).dy),
    );
  });

  testWidgets(
    'relationship editor preserves IDs and saves explicit new references',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      CatalogEdition? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<CatalogEdition>(
                    context: context,
                    builder: (context) => CatalogRelationshipsDialog(
                      repository: repository,
                      edition: repository.records.first,
                    ),
                  );
                },
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      final role = tester.getRect(
        find.widgetWithText(TextField, 'Role for the next credit'),
      );
      final contributor = tester.getRect(
        find.widgetWithText(TextField, 'Contributor name'),
      );
      expect(contributor.top - role.bottom, greaterThanOrEqualTo(16));
      await tester.enterText(
        find.widgetWithText(TextField, 'Contributor name'),
        'New Writer',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create new contributor'));
      await tester.tap(find.text('Create new contributor'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              widget.data == '2. New Writer - author',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.widgetWithText(TextField, 'Category name'),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Category name'),
        'Fiction',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create new category'));
      await tester.tap(find.text('Create new category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save relationships'));
      await tester.pumpAndSettle();
      expect(repository.savedCredits!.first.contributor.id, 'contributor-1');
      expect(repository.savedCredits!.last.contributor.id, isNull);
      expect(repository.savedCredits!.last.contributor.name, 'New Writer');
      expect(repository.savedCategories!.map((category) => category.name), [
        'Travel',
        'Fiction',
      ]);
      expect(saved!.revision, 2);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
