import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

enum CatalogRole {
  administrator,
  editor,
  viewer;

  String get label => switch (this) {
    administrator => 'Administrator',
    editor => 'Editor',
    viewer => 'Viewer',
  };

  static CatalogRole parse(Object? value) => switch (value) {
    'administrator' => CatalogRole.administrator,
    'editor' => CatalogRole.editor,
    'viewer' => CatalogRole.viewer,
    _ => throw const CatalogAccessDenied(
      'An active catalog membership is required.',
    ),
  };
}

bool canEditCatalog(CatalogRole? role, {required bool connected}) =>
    connected &&
    (role == CatalogRole.editor || role == CatalogRole.administrator);

bool isTemporaryCatalogConnectivityFailure(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is AuthRetryableFetchException;

String? validateCatalogIsbn(String value) {
  if (value.isEmpty) return null;
  if (!RegExp(r'^97[89]\d{10}$').hasMatch(value)) {
    return 'Enter 13 digits beginning with 978 or 979.';
  }
  final checksum = value.codeUnits.indexed.fold<int>(
    0,
    (sum, entry) => sum + (entry.$2 - 48) * (entry.$1.isEven ? 1 : 3),
  );
  return checksum % 10 == 0 ? null : 'Check the ISBN-13 checksum.';
}

class CatalogMember {
  const CatalogMember({
    required this.userId,
    required this.email,
    required this.role,
    required this.active,
  });

  final String userId;
  final String email;
  final CatalogRole role;
  final bool active;

  factory CatalogMember.fromRecord(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['user_id'] is! String ||
        value['email'] is! String ||
        value['active'] is! bool) {
      throw const FormatException(
        'The membership service returned invalid data.',
      );
    }
    return CatalogMember(
      userId: value['user_id'] as String,
      email: value['email'] as String,
      role: CatalogRole.parse(value['role']),
      active: value['active'] as bool,
    );
  }
}

class CatalogAccessDenied implements Exception {
  const CatalogAccessDenied(this.message);

  final String message;

  @override
  String toString() => message;
}

bool isValidReleaseDate(String value) {
  final match = RegExp(
    r'^([1-9]\d{3})(?:-(0[1-9]|1[0-2])(?:-(0[1-9]|[12]\d|3[01]))?)?$',
  ).firstMatch(value);
  if (match == null) return false;
  final day = match.group(3);
  if (day == null) return true;
  final date = DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(day),
  );
  return date.day == int.parse(day);
}

({DateTime start, DateTime end}) releaseDateBounds(String value) {
  if (!isValidReleaseDate(value)) {
    throw const FormatException('Invalid catalog release date.');
  }
  final parts = value.split('-').map(int.parse).toList();
  final start = DateTime.utc(
    parts[0],
    parts.length > 1 ? parts[1] : 1,
    parts.length > 2 ? parts[2] : 1,
  );
  final end = switch (parts.length) {
    1 => DateTime.utc(parts[0], 12, 31),
    2 => DateTime.utc(parts[0], parts[1] + 1, 0),
    _ => start,
  };
  return (start: start, end: end);
}

String catalogDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime sixMonthsAfter(DateTime date) {
  final lastDay = DateTime.utc(date.year, date.month + 7, 0).day;
  return DateTime.utc(date.year, date.month + 6, min(date.day, lastDay));
}

String? detectCoverFormat(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'jpg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return 'png';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return 'webp';
  }
  return null;
}

class CatalogReference {
  const CatalogReference({required this.id, required this.name});

  final String? id;
  final String name;

  factory CatalogReference.fromRecord(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['name'] is! String ||
        (value['name'] as String).trim().isEmpty) {
      throw const FormatException('The catalog returned an invalid reference.');
    }
    return CatalogReference(
      id: value['id'] as String,
      name: value['name'] as String,
    );
  }

  Map<String, dynamic> toInput() =>
      id == null ? {'name': name.trim()} : {'id': id};
}

class CatalogCredit {
  const CatalogCredit({required this.contributor, required this.role});

  final CatalogReference contributor;
  final String role;

  factory CatalogCredit.fromRecord(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['role'] is! String ||
        (value['role'] as String).trim().isEmpty) {
      throw const FormatException('The catalog returned an invalid credit.');
    }
    return CatalogCredit(
      contributor: CatalogReference.fromRecord(value),
      role: value['role'] as String,
    );
  }

  Map<String, dynamic> toInput() => {
    ...contributor.toInput(),
    'role': role.trim(),
  };
}

class CatalogRelationOptions {
  const CatalogRelationOptions({
    required this.contributors,
    required this.categories,
  });

  final List<CatalogReference> contributors;
  final List<CatalogReference> categories;
}

class CatalogEdition {
  const CatalogEdition({
    required this.id,
    required this.workId,
    required this.title,
    required this.format,
    required this.language,
    required this.publicationStatus,
    required this.revision,
    required this.isbn,
    required this.releaseDate,
    required this.description,
    required this.coverKey,
    required this.categories,
    required this.contributors,
    required this.credits,
    required this.categoryReferences,
    required this.record,
  });

  final String id;
  final String workId;
  final String title;
  final String format;
  final String language;
  final String publicationStatus;
  final int revision;
  final String? isbn;
  final String? releaseDate;
  final String description;
  final String? coverKey;
  final List<String> categories;
  final List<String> contributors;
  final List<CatalogCredit> credits;
  final List<CatalogReference> categoryReferences;
  final Map<String, dynamic> record;

  factory CatalogEdition.fromRecord(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('The catalog returned an invalid edition.');
    }
    final id = value['id'];
    final workId = value['work_id'];
    final title = value['title'];
    final format = value['format'];
    final language = value['language'];
    final publicationStatus = value['publication_status'];
    final revision = value['revision'];
    final isbn = value['isbn13'];
    final releaseDate = value['release_date'];
    final description = value['description'];
    final coverKey = value['cover_key'];
    final categories = value['categories'];
    final credits = value['contributors'];
    final categoryReferences = value['category_refs'];
    if (id is! String ||
        id.isEmpty ||
        workId is! String ||
        workId.isEmpty ||
        title is! String ||
        title.trim().isEmpty ||
        format is! String ||
        language is! String ||
        publicationStatus is! String ||
        revision is! int ||
        revision < 1 ||
        (isbn != null && isbn is! String) ||
        (releaseDate != null &&
            (releaseDate is! String || !isValidReleaseDate(releaseDate))) ||
        (description != null && description is! String) ||
        (coverKey != null && coverKey is! String) ||
        categories is! List ||
        !categories.every((item) => item is String) ||
        categoryReferences is! List ||
        credits is! List ||
        !credits.every(
          (credit) =>
              credit is Map &&
              credit['name'] is String &&
              credit['role'] is String,
        )) {
      throw const FormatException('The catalog returned an invalid edition.');
    }
    final parsedCredits = credits.map(CatalogCredit.fromRecord).toList();
    final parsedCategories = categoryReferences
        .map(CatalogReference.fromRecord)
        .toList();
    if (parsedCategories.length != categories.length ||
        !parsedCategories.indexed.every(
          (entry) => entry.$2.name == categories[entry.$1],
        ) ||
        parsedCategories.map((entry) => entry.id).toSet().length !=
            parsedCategories.length ||
        parsedCredits
                .map((entry) => (entry.contributor.id, entry.role))
                .toSet()
                .length !=
            parsedCredits.length) {
      throw const FormatException(
        'The catalog returned inconsistent relationships.',
      );
    }
    return CatalogEdition(
      id: id,
      workId: workId,
      title: title,
      format: format,
      language: language,
      publicationStatus: publicationStatus,
      revision: revision,
      isbn: isbn as String?,
      releaseDate: releaseDate as String?,
      description: description as String? ?? '',
      coverKey: coverKey as String?,
      categories: List<String>.unmodifiable(categories.cast<String>()),
      contributors: List<String>.unmodifiable(
        parsedCredits.map((credit) => credit.contributor.name),
      ),
      credits: List.unmodifiable(parsedCredits),
      categoryReferences: List.unmodifiable(parsedCategories),
      record: Map<String, dynamic>.unmodifiable(value),
    );
  }

  bool matches(String query) {
    final term = query.trim().toLowerCase();
    return term.isEmpty ||
        <String>[
          title,
          isbn ?? '',
          ...categories,
          ...contributors,
        ].any((value) => value.toLowerCase().contains(term));
  }

  CatalogEdition withRecord(Map<String, dynamic> next) =>
      CatalogEdition.fromRecord(next);
}

enum CatalogSort {
  title('Title'),
  format('Format'),
  isbn('ISBN'),
  releaseDate('Release date');

  const CatalogSort(this.label);
  final String label;
}

List<CatalogEdition> sortedCatalog(
  Iterable<CatalogEdition> records,
  CatalogSort field,
  bool ascending,
) {
  String? value(CatalogEdition record) => switch (field) {
    CatalogSort.title => record.title.toLowerCase(),
    CatalogSort.format => record.format,
    CatalogSort.isbn => record.isbn,
    CatalogSort.releaseDate => record.releaseDate,
  };
  return records.toList()..sort((left, right) {
    final a = value(left);
    final b = value(right);
    if (a == null && b != null) return 1;
    if (a != null && b == null) return -1;
    final compared = a == null ? 0 : a.compareTo(b!);
    return compared == 0
        ? left.id.compareTo(right.id)
        : ascending
        ? compared
        : -compared;
  });
}

enum CatalogFilterField {
  category,
  contributor,
  status,
  releaseDate,
  releaseRange,
  work,
}

class CatalogFilters {
  const CatalogFilters({
    this.categoryQuery,
    this.contributorQuery,
    this.publicationStatus,
    this.releaseDatePrefix,
    this.categoryId,
    this.contributorId,
    this.workId,
    this.releaseFrom,
    this.releaseThrough,
  });

  final String? categoryQuery;
  final String? contributorQuery;
  final String? publicationStatus;
  final String? releaseDatePrefix;
  final String? categoryId;
  final String? contributorId;
  final String? workId;
  final String? releaseFrom;
  final String? releaseThrough;

  bool get isEmpty =>
      (categoryQuery == null || categoryQuery!.isEmpty) &&
      (contributorQuery == null || contributorQuery!.isEmpty) &&
      publicationStatus == null &&
      releaseDatePrefix == null &&
      categoryId == null &&
      contributorId == null &&
      workId == null &&
      releaseFrom == null &&
      releaseThrough == null;

  CatalogFilters copyWith({
    String? categoryQuery,
    String? contributorQuery,
    String? categoryId,
    String? contributorId,
    String? workId,
  }) => CatalogFilters(
    categoryQuery: categoryQuery ?? this.categoryQuery,
    contributorQuery: contributorQuery ?? this.contributorQuery,
    categoryId: categoryId ?? this.categoryId,
    contributorId: contributorId ?? this.contributorId,
    workId: workId ?? this.workId,
    publicationStatus: publicationStatus,
    releaseDatePrefix: releaseDatePrefix,
    releaseFrom: releaseFrom,
    releaseThrough: releaseThrough,
  );

  CatalogFilters without(CatalogFilterField field) => CatalogFilters(
    categoryQuery: field == CatalogFilterField.category ? null : categoryQuery,
    categoryId: field == CatalogFilterField.category ? null : categoryId,
    contributorQuery: field == CatalogFilterField.contributor
        ? null
        : contributorQuery,
    contributorId: field == CatalogFilterField.contributor
        ? null
        : contributorId,
    publicationStatus: field == CatalogFilterField.status
        ? null
        : publicationStatus,
    releaseDatePrefix: field == CatalogFilterField.releaseDate
        ? null
        : releaseDatePrefix,
    workId: field == CatalogFilterField.work ? null : workId,
    releaseFrom: field == CatalogFilterField.releaseRange ? null : releaseFrom,
    releaseThrough: field == CatalogFilterField.releaseRange
        ? null
        : releaseThrough,
  );

  bool _matchesDateRange(String? releaseDate) {
    if (releaseFrom == null && releaseThrough == null) return true;
    if (releaseDate == null) return false;
    final bounds = releaseDateBounds(releaseDate);
    return (releaseFrom == null ||
            !bounds.end.isBefore(releaseDateBounds(releaseFrom!).start)) &&
        (releaseThrough == null ||
            !bounds.start.isAfter(releaseDateBounds(releaseThrough!).end));
  }

  bool matches(CatalogEdition edition) {
    final category = categoryQuery?.toLowerCase();
    final contributor = contributorQuery?.toLowerCase();
    final date = releaseDatePrefix;
    return (categoryId != null
            ? edition.categoryReferences.any((value) => value.id == categoryId)
            : category == null ||
                  edition.categories.any(
                    (value) => value.toLowerCase().contains(category),
                  )) &&
        (contributorId != null
            ? edition.credits.any(
                (value) => value.contributor.id == contributorId,
              )
            : contributor == null ||
                  edition.contributors.any(
                    (value) => value.toLowerCase().contains(contributor),
                  )) &&
        (workId == null || edition.workId == workId) &&
        (publicationStatus == null ||
            edition.publicationStatus == publicationStatus) &&
        (date == null || edition.releaseDate?.startsWith(date) == true) &&
        _matchesDateRange(edition.releaseDate);
  }
}

class CatalogSnapshot {
  const CatalogSnapshot({required this.role, required this.editions});

  final CatalogRole role;
  final List<CatalogEdition> editions;

  CatalogSnapshot replace(CatalogEdition saved) => CatalogSnapshot(
    role: role,
    editions: List.unmodifiable(
      editions.map((edition) => edition.id == saved.id ? saved : edition),
    ),
  );

  CatalogSnapshot add(CatalogEdition created) => CatalogSnapshot(
    role: role,
    editions: List.unmodifiable([...editions, created]),
  );
}

class CatalogRepository {
  CatalogRepository(this._client);

  final SupabaseClient _client;
  final Map<String, ({String url, DateTime expiresAt})> _coverUrlCache = {};
  final Map<String, Future<String>> _pendingCoverUrls = {};
  static const _pageSize = 500;
  static const _maximumRecords = 10000;
  static const maximumCoverBytes = 10 * 1024 * 1024;

  Future<CatalogRole> _currentRole() async =>
      CatalogRole.parse(await _client.rpc('current_catalog_role'));

  Future<String> requestOfflineLease() async {
    try {
      final response = await _client.functions.invoke('offline-lease');
      final data = response.data;
      if (data is! Map<String, dynamic> || data['lease'] is! String) {
        throw const FormatException(
          'The offline service returned an invalid lease.',
        );
      }

      return data['lease'] as String;
    } on FunctionException catch (error) {
      if (error.status == 401 || error.status == 403) {
        throw const CatalogAccessDenied(
          'Membership could not be verified for offline access.',
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> importMetadata({
    required String requestId,
    required String sourceName,
    required String sourceSha256,
    required List<Map<String, dynamic>> rows,
  }) async {
    final result = await _client
        .rpc(
          'import_catalog_metadata',
          params: {
            'p_request_id': requestId,
            'p_source_name': sourceName,
            'p_source_sha256': sourceSha256,
            'p_rows': rows,
          },
        )
        .timeout(const Duration(seconds: 60));
    if (result is! Map<String, dynamic>) {
      throw const FormatException(
        'The import response could not be confirmed. Retry the same request.',
      );
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> loadImportReports() async {
    final records = await _client
        .from('catalog_imports')
        .select('report')
        .order('occurred_at', ascending: false)
        .limit(50)
        .timeout(const Duration(seconds: 30));
    return records.map((row) {
      final report = row['report'];
      if (report is! Map<String, dynamic>) {
        throw const FormatException(
          'Import history returned an invalid report.',
        );
      }
      return report;
    }).toList();
  }

  Future<CatalogSnapshot> loadCatalog() async {
    final role = await _currentRole();
    final editions = <CatalogEdition>[];
    final ids = <String>{};
    for (var offset = 0; ; offset += _pageSize) {
      final page = await _client
          .from('catalog_editions')
          .select('record')
          .order('id')
          .range(offset, offset + _pageSize - 1);
      if (page.isEmpty) break;
      for (final row in page) {
        final edition = CatalogEdition.fromRecord(row['record']);
        if (!ids.add(edition.id)) {
          throw const FormatException(
            'The catalog returned a duplicate edition. Reload before continuing.',
          );
        }
        editions.add(edition);
      }
      if (editions.length > _maximumRecords) {
        throw StateError(
          'The catalog exceeds the comparison limit of $_maximumRecords editions.',
        );
      }
    }
    if (await _currentRole() != role) {
      throw const CatalogAccessDenied(
        'Catalog membership changed while loading. Reload to verify access.',
      );
    }
    return CatalogSnapshot(role: role, editions: List.unmodifiable(editions));
  }

  Future<CatalogEdition> updateMetadata(
    CatalogEdition edition, {
    required String title,
    required String format,
    required String language,
    required String? isbn,
    required String publicationStatus,
    required String? releaseDate,
    required String description,
    required String? coverKey,
  }) async {
    final updated = await _client.rpc(
      'update_edition_metadata',
      params: {
        'p_edition_id': edition.id,
        'p_expected_revision': edition.revision,
        'p_title': title,
        'p_format': format,
        'p_language': language,
        'p_isbn13': isbn,
        'p_publication_status': publicationStatus,
        'p_release_date': releaseDate,
        'p_description': description,
        'p_cover_key': coverKey,
      },
    );
    final saved = CatalogEdition.fromRecord(updated);
    if (saved.id != edition.id || saved.revision != edition.revision + 1) {
      throw const FormatException(
        'The save response could not be confirmed. Reload before retrying.',
      );
    }
    return saved;
  }

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
    final created = await _client.rpc(
      'create_catalog_edition',
      params: {
        'p_work_id': workId,
        'p_title': title,
        'p_format': format,
        'p_language': language,
        'p_isbn13': isbn,
        'p_publication_status': publicationStatus,
        'p_release_date': releaseDate,
        'p_description': description,
      },
    );
    final edition = CatalogEdition.fromRecord(created);
    if (edition.revision != 1 || (workId != null && edition.workId != workId)) {
      throw const FormatException(
        'The new edition could not be confirmed. Reload before continuing.',
      );
    }
    return edition;
  }

  Future<CatalogRelationOptions> loadRelationOptions() async {
    final role = await _currentRole();
    if (!canEditCatalog(role, connected: true)) {
      throw const CatalogAccessDenied('Catalog editing is not permitted.');
    }
    final contributors = await _loadReferences('contributors');
    final categories = await _loadReferences('categories');
    if (await _currentRole() != role) {
      throw const CatalogAccessDenied(
        'Membership changed. Reload to verify access.',
      );
    }
    return CatalogRelationOptions(
      contributors: contributors,
      categories: categories,
    );
  }

  Future<List<CatalogReference>> _loadReferences(String table) async {
    final references = <CatalogReference>[];
    final ids = <String?>{};
    for (var offset = 0; ; offset += _pageSize) {
      final page = await _client
          .from(table)
          .select('id,name')
          .order('id')
          .range(offset, offset + _pageSize - 1);
      if (page.isEmpty) break;
      for (final row in page) {
        final reference = CatalogReference.fromRecord(row);
        if (!ids.add(reference.id)) {
          throw const FormatException(
            'The catalog returned duplicate references.',
          );
        }
        references.add(reference);
      }
      if (references.length > _maximumRecords) {
        throw StateError(
          'Too many $table to load safely. Contact an administrator.',
        );
      }
    }
    references.sort((left, right) => left.name.compareTo(right.name));
    return List.unmodifiable(references);
  }

  Future<CatalogEdition> updateRelations(
    CatalogEdition edition, {
    required List<CatalogCredit> credits,
    required List<CatalogReference> categories,
  }) async {
    final response = await _client.rpc(
      'update_edition_relations',
      params: {
        'p_edition_id': edition.id,
        'p_expected_revision': edition.revision,
        'p_credits': credits.map((credit) => credit.toInput()).toList(),
        'p_categories': categories
            .map((category) => category.toInput())
            .toList(),
      },
    );
    final saved = CatalogEdition.fromRecord(response);
    if (saved.id != edition.id ||
        saved.workId != edition.workId ||
        saved.revision != edition.revision + 1) {
      throw const FormatException(
        'The relationship save could not be confirmed. Reload before retrying.',
      );
    }
    return saved;
  }

  Future<String> uploadCover({
    required String editionId,
    required Uint8List bytes,
    required String extension,
    required String contentType,
  }) async {
    if (bytes.isEmpty || bytes.length > maximumCoverBytes) {
      throw const FormatException(
        'Cover images must be between 1 byte and 10 MiB.',
      );
    }
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(editionId)) {
      throw const FormatException('The edition ID cannot be used for a cover.');
    }
    const formats = {
      'jpg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
    };
    if (formats[extension] != contentType) {
      throw const FormatException('Choose a JPEG, PNG, or WebP cover image.');
    }
    if (detectCoverFormat(bytes) != extension) {
      throw const FormatException(
        'The cover image content does not match its format.',
      );
    }
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final key = '$editionId/$nonce.$extension';
    await _client.storage
        .from('book-covers')
        .uploadBinary(
          key,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    return key;
  }

  Future<String> signedCoverUrl(String key) {
    final cached = _coverUrlCache[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return Future.value(cached.url);
    }
    return _pendingCoverUrls.putIfAbsent(key, () async {
      try {
        final url = await _client.storage
            .from('book-covers')
            .createSignedUrl(key, 300);
        _coverUrlCache[key] = (
          url: url,
          expiresAt: DateTime.now().add(const Duration(minutes: 4)),
        );
        return url;
      } finally {
        _pendingCoverUrls.remove(key);
      }
    });
  }

  Future<void> removeCover(String key) async {
    final removed = await _client.storage.from('book-covers').remove([key]);
    if (removed.length != 1 || removed.single.name != key) {
      throw const FormatException(
        'Cover removal was not confirmed. Ask an administrator to check the stored object.',
      );
    }
    _coverUrlCache.remove(key);
    _pendingCoverUrls.remove(key);
  }

  Future<List<CatalogMember>> loadMembers() async {
    final response = await _client.rpc('list_catalog_members');
    if (response is! List) {
      throw const FormatException(
        'The membership service returned an invalid list.',
      );
    }
    final members = response.map(CatalogMember.fromRecord).toList();
    if (members.map((member) => member.userId).toSet().length !=
        members.length) {
      throw const FormatException(
        'The membership service returned duplicate accounts.',
      );
    }
    return List.unmodifiable(members);
  }

  Future<CatalogMember> addMember(String email, CatalogRole role) async =>
      CatalogMember.fromRecord(
        await _client.rpc(
          'add_catalog_member',
          params: {'p_email': email, 'p_role': role.name},
        ),
      );

  Future<CatalogMember> updateMember({
    required String userId,
    required CatalogRole role,
    required bool active,
  }) async => CatalogMember.fromRecord(
    await _client.rpc(
      'update_catalog_member',
      params: {'p_user_id': userId, 'p_role': role.name, 'p_active': active},
    ),
  );
}
