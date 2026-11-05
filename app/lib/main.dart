import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_storage.dart';
import 'catalog.dart';
import 'relationships.dart';
import 'offline_cache.dart';
import 'exchange_screen.dart';
import 'design.dart';

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabasePublishableKey = String.fromEnvironment(
  'SUPABASE_PUBLISHABLE_KEY',
);
const authRedirect = 'com.bookalog.catalog://login-callback/';
const offlineLeasePublicKey = String.fromEnvironment(
  'OFFLINE_LEASE_PUBLIC_KEY',
);

enum _CatalogView { gallery, table, calendar }

String _statusLabel(String status) => switch (status) {
  'planned' => 'Planned',
  'announced' => 'Announced',
  'released' => 'Released',
  'out_of_print' => 'Out of print',
  _ => status,
};

bool get isSupabaseConfigured =>
    Uri.tryParse(supabaseUrl)?.scheme == 'https' &&
    Uri.tryParse(supabaseUrl)?.host.isNotEmpty == true &&
    supabasePublishableKey.isNotEmpty;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Object? startupError;
  OfflineCatalogCache? offlineCache;
  if (isSupabaseConfigured) {
    try {
      if (offlineLeasePublicKey.isNotEmpty) {
        offlineCache = OfflineCatalogCache(
          issuer: Uri.parse(supabaseUrl).origin,
          publicKey: offlineLeasePublicKey,
          storage: const DeviceOfflineCacheStorage(),
        );
      }
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabasePublishableKey,
        authOptions: FlutterAuthClientOptions(
          localStorage: SecureSupabaseLocalStorage(
            issuer: Uri.parse(supabaseUrl).origin,
            onSessionRemoved: () async {
              PaintingBinding.instance.imageCache.clear();
              PaintingBinding.instance.imageCache.clearLiveImages();
              await offlineCache?.clearAll();
            },
          ),
        ),
      );
    } catch (error) {
      startupError = error;
    }
  }
  runApp(BookalogApp(startupError: startupError, offlineCache: offlineCache));
}

class BookalogApp extends StatelessWidget {
  const BookalogApp({super.key, this.startupError, this.offlineCache});

  final Object? startupError;
  final OfflineCatalogCache? offlineCache;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bookalog',
      theme: buildBookalogTheme(Brightness.light),
      darkTheme: buildBookalogTheme(Brightness.dark),
      home: AuthGate(startupError: startupError, offlineCache: offlineCache),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key, this.startupError, this.offlineCache});

  final Object? startupError;
  final OfflineCatalogCache? offlineCache;

  @override
  Widget build(BuildContext context) {
    if (startupError != null) {
      return SetupMessage(
        title: 'Bookalog could not start',
        message: 'Check the project URL, publishable key, offline verification key, and OS secure-storage access, then restart. No catalog data was loaded.',
      );
    }
    if (!isSupabaseConfigured) {
      return const SetupMessage(
        title: 'Bookalog catalog',
        message: 'The selected app stack is Flutter and Supabase. Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY with --dart-define to connect. No service-role key belongs in this app.',
      );
    }
    final client = Supabase.instance.client;
    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      initialData: AuthState(
        AuthChangeEvent.initialSession,
        client.auth.currentSession,
      ),
      builder: (context, snapshot) {
        final temporaryError =
            snapshot.hasError &&
            isTemporaryCatalogConnectivityFailure(snapshot.error!);
        if (snapshot.hasError && !temporaryError) {
          return SetupMessage(
            title: 'Sign-in state unavailable',
            message: 'Restart the app to retry. ${snapshot.error}',
          );
        }
        final session =
            snapshot.data?.session ??
            (temporaryError ? client.auth.currentSession : null);
        if (session == null) {
          if (snapshot.data?.event == AuthChangeEvent.signedOut) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted && client.auth.currentSession == null) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            });
          }
          return const SignInScreen();
        }
        return CatalogScreen(
          key: ValueKey(session.user.id),
          client: client,
          offlineCache: offlineCache,
          authConnectivityError: temporaryError ? snapshot.error : null,
        );
      },
    );
  }
}

class SetupMessage extends StatelessWidget {
  const SetupMessage({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => _EntryPanel(
    children: [
      Text(title, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      SelectableText(message),
    ],
  );
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const ShelfMark(),
      const SizedBox(width: 10),
      Text(
        'Bookalog',
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      ),
    ],
  );
}

class _EntryPanel extends StatelessWidget {
  const _EntryPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.paper,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  border: Border.all(color: palette.hairline),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      offset: Offset(0, 8),
                      blurRadius: 24,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: _Wordmark(),
                      ),
                      const SizedBox(height: 28),
                      ...children,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final launched = await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: authRedirect,
      );
      if (!launched && mounted) {
        setState(() => _error = 'Google sign-in was not opened.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _EntryPanel(
    children: [
      Text(
        'Publishing catalog',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 10),
      Text(
        'Sign in with your Google Workspace account. Access is granted only to approved catalog members.',
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: ShelfPalette.of(context).inkMuted),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
        onPressed: _busy ? null : _signIn,
        icon: const Icon(Icons.open_in_browser, size: 18),
        label: Text(_busy ? 'Opening Google sign-in…' : 'Continue with Google'),
      ),
      if (_error case final error?) ...[
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    ],
  );
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.client,
    this.repository,
    this.offlineCache,
    this.authConnectivityError,
  });

  final SupabaseClient client;
  final CatalogRepository? repository;
  final OfflineCatalogCache? offlineCache;
  final Object? authConnectivityError;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen>
    with WidgetsBindingObserver {
  late final CatalogRepository _repository =
      widget.repository ?? CatalogRepository(widget.client);
  final _search = TextEditingController();
  CatalogSnapshot? _snapshot;
  CatalogEdition? _selected;
  CatalogFilters _filters = const CatalogFilters();
  _CatalogView _view = _CatalogView.table;
  CatalogSort _sort = CatalogSort.title;
  bool _sortAscending = true;
  Object? _error;
  bool _showingCachedSnapshot = false;
  bool _busy = true;
  bool _coverBusy = false;
  OfflineCatalogEntry? _offlineEntry;
  String? _offlineWarning;
  Timer? _leaseExpiry;
  Timer? _clockTimer;
  bool _checkingLease = false;
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    _leaseExpiry?.cancel();
    _clockTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _reload() async {
    final epoch = ++_loadEpoch;
    final cache = widget.offlineCache;
    final generation = cache?.generation;
    final subject = widget.client.auth.currentUser?.id;
    setState(() {
      _busy = true;
      _error = null;
      _offlineWarning = null;
      _showingCachedSnapshot = false;
      _selected = null;
    });
    try {
      final snapshot = await _repository.loadCatalog().timeout(
        const Duration(seconds: 30),
      );
      if (!mounted || epoch != _loadEpoch) return;
      if (cache != null && subject != null) {
        try {
          final token = await _repository.requestOfflineLease().timeout(
            const Duration(seconds: 25),
          );
          if (!mounted || epoch != _loadEpoch) return;
          final entry = await cache.save(
            subject: subject,
            snapshot: snapshot,
            leaseToken: token,
            generation: generation!,
          );
          if (!mounted || epoch != _loadEpoch) return;
          _installOfflineEntry(entry);
        } on CatalogAccessDenied {
          rethrow;
        } catch (error) {
          final cleanup = await _clearOfflineCopy();
          _offlineWarning =
              'Catalog loaded, but offline access is unavailable: $error'
              '${cleanup == null ? '' : '. $cleanup'}';
        }
      } else {
        _offlineWarning =
            'Offline access is not configured for this installation.';
      }
      if (mounted && epoch == _loadEpoch) setState(() => _snapshot = snapshot);
    } catch (error) {
      await _useOfflineOrDeny(error, epoch);
    } finally {
      if (mounted && epoch == _loadEpoch) setState(() => _busy = false);
    }
  }

  void _markConnectivityFailure(Object error) {
    if (mounted && isTemporaryCatalogConnectivityFailure(error)) {
      final epoch = ++_loadEpoch;
      setState(() {
        _busy = true;
        _error = error;
        _selected = null;
      });
      unawaited(_useOfflineOrDeny(error, epoch));
    }
  }

  Future<void> _useOfflineOrDeny(Object error, int epoch) async {
    if (!mounted || epoch != _loadEpoch) return;
    Object reported = error;
    final cache = widget.offlineCache;
    final subject = widget.client.auth.currentUser?.id;
    if (isTemporaryCatalogConnectivityFailure(error) &&
        cache != null &&
        subject != null) {
      try {
        final entry = await cache.read(subject);
        if (entry == null) {
          throw const OfflineAccessUnavailable(
            'No verified offline copy is available. Reconnect and reload the catalog.',
          );
        }
        if (!mounted || epoch != _loadEpoch) return;
        _installOfflineEntry(entry);
        setState(() {
          _snapshot = entry.snapshot;
          _error = error;
          _showingCachedSnapshot = true;
          _busy = false;
        });
        return;
      } catch (cacheError) {
        reported = cacheError;
      }
    } else if (isTemporaryCatalogConnectivityFailure(error)) {
      reported = const OfflineAccessUnavailable(
        'A server-verified saved copy is required for offline browsing. Reconnect to load the catalog.',
      );
    }
    final cleanup = await _clearOfflineCopy();
    if (!mounted || epoch != _loadEpoch) return;
    setState(() {
      _snapshot = null;
      _selected = null;
      _showingCachedSnapshot = false;
      _busy = false;
      _error = cleanup == null ? reported : StateError('$reported. $cleanup');
    });
  }

  void _installOfflineEntry(OfflineCatalogEntry entry) {
    _offlineEntry = entry;
    _leaseExpiry?.cancel();
    _clockTimer?.cancel();
    final remaining = entry.lease.expiresAt.difference(DateTime.now());
    _leaseExpiry = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => unawaited(_checkOfflineAccess()),
    );
    _clockTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_checkOfflineAccess()),
    );
  }

  Future<String?> _clearOfflineCopy() async {
    _leaseExpiry?.cancel();
    _clockTimer?.cancel();
    _offlineEntry = null;
    try {
      await widget.offlineCache?.clearAll();
      return null;
    } catch (error) {
      return 'The stored offline copy could not be removed: $error';
    }
  }

  Future<void> _checkOfflineAccess() async {
    final entry = _offlineEntry;
    if (_checkingLease || entry == null || !mounted) return;
    _checkingLease = true;
    try {
      if (!entry.isUsable(DateTime.now())) {
        throw const OfflineAccessUnavailable(
          'Offline access expired or the device clock changed. Reconnect and reload.',
        );
      }
      await widget.offlineCache?.recordUse(entry.lease.subject);
    } catch (error) {
      final cleanup = await _clearOfflineCopy();
      if (!mounted) return;
      setState(() {
        if (_showingCachedSnapshot) {
          _snapshot = null;
          _selected = null;
          _showingCachedSnapshot = false;
          _error = error;
        }
        _offlineWarning = '$error${cleanup == null ? '' : '. $cleanup'}';
      });
    } finally {
      _checkingLease = false;
    }
  }

  Future<void> _persistCurrentSnapshot() async {
    final cache = widget.offlineCache;
    final snapshot = _snapshot;
    final entry = _offlineEntry;
    if (cache == null || snapshot == null || entry == null) return;
    try {
      final updated = await cache.save(
        subject: entry.lease.subject,
        snapshot: snapshot,
        leaseToken: entry.lease.token,
        generation: cache.generation,
      );
      if (mounted && identical(snapshot, _snapshot)) {
        _installOfflineEntry(updated);
      }
    } catch (error) {
      final cleanup = await _clearOfflineCopy();
      if (mounted) {
        setState(() {
          _offlineWarning =
              'Your change was saved online, but the offline copy was not updated: '
              '$error${cleanup == null ? '' : '. $cleanup'}';
        });
      }
    }
  }

  @override
  void didUpdateWidget(CatalogScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final error = widget.authConnectivityError;
    if (!_busy && error != null && error != oldWidget.authConnectivityError) {
      _markConnectivityFailure(error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      unawaited(_checkOfflineAccess());
    }
  }

  Future<void> _signOut() async {
    final messenger = ScaffoldMessenger.of(context);
    _loadEpoch++;
    setState(() {
      _busy = true;
      _snapshot = null;
      _selected = null;
    });
    final cleanup = await _clearOfflineCopy();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    String? signOutError;
    try {
      await widget.client.auth.signOut();
    } catch (error) {
      signOutError = 'Remote sign-out could not be confirmed: $error';
    }
    final messages = [cleanup, signOutError].whereType<String>().join(' ');
    if (messages.isNotEmpty && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(messages)));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _edit(CatalogEdition edition) async {
    final saved = await showDialog<CatalogEdition>(
      context: context,
      barrierDismissible: false,
      builder: (context) => EditionMetadataDialog(
        repository: _repository,
        edition: edition,
        onConnectivityFailure: _markConnectivityFailure,
      ),
    );
    if (saved == null || !mounted || _snapshot == null) return;
    setState(() {
      _snapshot = _snapshot!.replace(saved);
      if (_selected?.id == saved.id) _selected = saved;
    });
    await _persistCurrentSnapshot();
  }

  Future<void> _editRelations(CatalogEdition edition) async {
    final saved = await showDialog<CatalogEdition>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CatalogRelationshipsDialog(
        repository: _repository,
        edition: edition,
        onConnectivityFailure: _markConnectivityFailure,
      ),
    );
    if (saved == null || !mounted || _snapshot == null) return;
    setState(() {
      _snapshot = _snapshot!.replace(saved);
      if (_selected?.id == saved.id) _selected = saved;
    });
    await _persistCurrentSnapshot();
  }

  Future<void> _createEdition({CatalogEdition? relatedEdition}) async {
    final created = await showDialog<CatalogEdition>(
      context: context,
      barrierDismissible: false,
      builder: (context) => EditionMetadataDialog(
        repository: _repository,
        edition: null,
        workId: relatedEdition?.workId,
        initialTitle: relatedEdition?.title,
        onConnectivityFailure: _markConnectivityFailure,
      ),
    );
    if (created == null || !mounted || _snapshot == null) return;
    setState(() {
      _search.clear();
      _filters = const CatalogFilters();
      _snapshot = _snapshot!.add(created);
      _selected = created;
    });
    await _persistCurrentSnapshot();
  }

  void _filterByContributor(CatalogReference contributor) => setState(() {
    _filters = _filters.copyWith(
      contributorId: contributor.id,
      contributorQuery: contributor.name,
    );
  });

  void _filterByCategory(CatalogReference category) => setState(() {
    _filters = _filters.copyWith(
      categoryId: category.id,
      categoryQuery: category.name,
    );
  });

  void _filterToWork(CatalogEdition edition) => setState(() {
    _filters = _filters.copyWith(workId: edition.workId);
  });

  Future<void> _manageMembers() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => MembershipManagementScreen(
          repository: _repository,
          currentUserId: widget.client.auth.currentUser?.id ?? '',
        ),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _exchange() async {
    final snapshot = _snapshot;
    if (snapshot == null || _showingCachedSnapshot || _error != null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => CatalogExchangeScreen(
          repository: _repository,
          role: snapshot.role,
          onApplied: _reload,
        ),
      ),
    );
  }

  Future<void> _configureFilters() async {
    final filters = await showDialog<CatalogFilters>(
      context: context,
      builder: (context) => _CatalogFilterDialog(current: _filters),
    );
    if (filters == null || !mounted) return;
    setState(() {
      _filters = filters;
      if (_selected != null &&
          (!_selected!.matches(_search.text) || !filters.matches(_selected!))) {
        _selected = null;
      }
    });
  }

  void _showCoverMessage(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<CatalogEdition?> _selectCover(CatalogEdition edition) async {
    setState(() => _coverBusy = true);
    String? uploadedKey;
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Cover images',
            extensions: ['jpg', 'jpeg', 'png', 'webp'],
          ),
        ],
      );
      if (file == null) return null;
      final size = await file.length();
      if (size == 0 || size > CatalogRepository.maximumCoverBytes) {
        throw const FormatException('Choose an image no larger than 10 MiB.');
      }
      final extension = file.name.split('.').last.toLowerCase();
      final normalizedExtension = extension == 'jpeg' ? 'jpg' : extension;
      final bytes = await file.readAsBytes();
      if (detectCoverFormat(bytes) != normalizedExtension) {
        throw const FormatException(
          'The selected file is not a supported JPEG, PNG, or WebP image.',
        );
      }
      final contentType = switch (normalizedExtension) {
        'jpg' => 'image/jpeg',
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => throw const FormatException(
          'Choose a JPEG, PNG, or WebP cover image.',
        ),
      };
      uploadedKey = await _repository.uploadCover(
        editionId: edition.id,
        bytes: bytes,
        extension: normalizedExtension,
        contentType: contentType,
      );
      final saved = await _repository.updateMetadata(
        edition,
        title: edition.title,
        format: edition.format,
        language: edition.language,
        isbn: edition.isbn,
        publicationStatus: edition.publicationStatus,
        releaseDate: edition.releaseDate,
        description: edition.description,
        coverKey: uploadedKey,
      );
      final previousKey = edition.coverKey;
      uploadedKey = null;
      if (mounted && _snapshot != null) {
        setState(() {
          _snapshot = _snapshot!.replace(saved);
          if (_selected?.id == saved.id) _selected = saved;
        });
        await _persistCurrentSnapshot();
      }
      if (previousKey != null) {
        try {
          await _repository.removeCover(previousKey);
        } catch (error) {
          if (mounted) {
            _showCoverMessage(
              'Cover updated, but the previous file could not be removed: $error',
            );
          }
        }
      }
      return saved;
    } catch (error) {
      _markConnectivityFailure(error);
      var message = error.toString();
      if (uploadedKey != null) {
        try {
          await _repository.removeCover(uploadedKey);
        } catch (cleanupError) {
          message =
              '$message. Uploaded cover cleanup also failed: $cleanupError';
        }
      }
      if (mounted) _showCoverMessage('Cover was not updated: $message');
      return null;
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  Future<CatalogEdition?> _removeCover(CatalogEdition edition) async {
    final key = edition.coverKey;
    if (key == null) return edition;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this cover?'),
        content: const Text(
          'The private image will be unlinked from this edition and deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove cover'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;
    setState(() => _coverBusy = true);
    try {
      final saved = await _repository.updateMetadata(
        edition,
        title: edition.title,
        format: edition.format,
        language: edition.language,
        isbn: edition.isbn,
        publicationStatus: edition.publicationStatus,
        releaseDate: edition.releaseDate,
        description: edition.description,
        coverKey: null,
      );
      if (mounted && _snapshot != null) {
        setState(() {
          _snapshot = _snapshot!.replace(saved);
          if (_selected?.id == saved.id) _selected = saved;
        });
        await _persistCurrentSnapshot();
      }
      try {
        await _repository.removeCover(key);
      } catch (error) {
        if (mounted) {
          _showCoverMessage(
            'Cover removed from the edition, but its file could not be deleted: $error',
          );
        }
      }
      return saved;
    } catch (error) {
      _markConnectivityFailure(error);
      if (mounted) _showCoverMessage('Cover was not removed: $error');
      return null;
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  Future<void> _openEdition(
    CatalogEdition edition, {
    required bool inlineDetails,
  }) async {
    setState(() => _selected = edition);
    if (inlineDetails) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var currentEdition = edition;
        var coverBusy = false;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final canEdit =
                canEditCatalog(
                  _snapshot?.role,
                  connected: _error == null && !_showingCachedSnapshot,
                ) &&
                !coverBusy;
            return PopScope(
              canPop: !coverBusy,
              child: AlertDialog(
                title: Text(currentEdition.title),
                content: SizedBox(
                  width: 520,
                  child: _EditionDetails(
                    edition: currentEdition,
                    showTitle: false,
                    repository: _repository,
                    online: !_showingCachedSnapshot && _error == null,
                    onEdit: canEdit
                        ? () {
                            Navigator.pop(dialogContext);
                            _edit(currentEdition);
                          }
                        : null,
                    onEditRelationships: canEdit
                        ? () {
                            Navigator.pop(dialogContext);
                            _editRelations(currentEdition);
                          }
                        : null,
                    onAddEdition: canEdit
                        ? () {
                            Navigator.pop(dialogContext);
                            _createEdition(relatedEdition: currentEdition);
                          }
                        : null,
                    onContributor: (reference) {
                      Navigator.pop(dialogContext);
                      _filterByContributor(reference);
                    },
                    onCategory: (reference) {
                      Navigator.pop(dialogContext);
                      _filterByCategory(reference);
                    },
                    onShowWork: () {
                      Navigator.pop(dialogContext);
                      _filterToWork(currentEdition);
                    },
                    onChooseCover: canEdit
                        ? () async {
                            setDialogState(() => coverBusy = true);
                            final saved = await _selectCover(currentEdition);
                            if (!dialogContext.mounted) return;
                            setDialogState(() {
                              coverBusy = false;
                              if (saved != null) currentEdition = saved;
                            });
                          }
                        : null,
                    onRemoveCover: canEdit && currentEdition.coverKey != null
                        ? () async {
                            setDialogState(() => coverBusy = true);
                            final saved = await _removeCover(currentEdition);
                            if (!dialogContext.mounted) return;
                            setDialogState(() {
                              coverBusy = false;
                              if (saved != null) currentEdition = saved;
                            });
                          }
                        : null,
                    coverBusy: coverBusy,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: coverBusy
                        ? null
                        : () => Navigator.pop(dialogContext),
                    child: const Text('Close'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _catalogView(
    List<CatalogEdition> records,
    bool compact,
    bool inlineDetails,
  ) => switch (_view) {
    _CatalogView.gallery => _EditionGallery(
      records: records,
      repository: _repository,
      online: !_showingCachedSnapshot && _error == null,
      selectedId: _selected?.id,
      onSelect: (edition) =>
          _openEdition(edition, inlineDetails: inlineDetails),
    ),
    _CatalogView.table when compact => _EditionList(
      records: records,
      canEdit: canEditCatalog(
        _snapshot?.role,
        connected: _error == null && !_showingCachedSnapshot,
      ),
      selectedId: _selected?.id,
      onSelect: (edition) =>
          _openEdition(edition, inlineDetails: inlineDetails),
    ),
    _CatalogView.table => _EditionTable(
      records: records,
      selectedId: _selected?.id,
      sort: _sort,
      sortAscending: _sortAscending,
      onSort: (field, ascending) => setState(() {
        _sort = field;
        _sortAscending = ascending;
      }),
      onSelect: (edition) =>
          _openEdition(edition, inlineDetails: inlineDetails),
    ),
    _CatalogView.calendar => ReleaseCalendarView(
      records: records,
      selectedId: _selected?.id,
      repository: _repository,
      online: !_showingCachedSnapshot && _error == null,
      onSelect: (edition) =>
          _openEdition(edition, inlineDetails: inlineDetails),
    ),
  };

  void _setStatusFilter(String? status) => setState(() {
    final current = _filters.without(CatalogFilterField.status);
    _filters = CatalogFilters(
      categoryQuery: current.categoryQuery,
      contributorQuery: current.contributorQuery,
      categoryId: current.categoryId,
      contributorId: current.contributorId,
      workId: current.workId,
      releaseDatePrefix: current.releaseDatePrefix,
      releaseFrom: current.releaseFrom,
      releaseThrough: current.releaseThrough,
      publicationStatus: status,
    );
    if (_selected != null && !_filters.matches(_selected!)) _selected = null;
  });

  Future<void> _runTool(String action) async {
    switch (action) {
      case 'exchange':
        await _exchange();
      case 'members':
        await _manageMembers();
      case 'signout':
        await _signOut();
    }
  }

  List<Widget> _filterChips() => [
    if (_filters.categoryQuery case final category?)
      InputChip(
        label: Text('Category: $category'),
        onDeleted: () => setState(
          () => _filters = _filters.without(CatalogFilterField.category),
        ),
      ),
    if (_filters.contributorQuery case final contributor?)
      InputChip(
        label: Text('Contributor: $contributor'),
        onDeleted: () => setState(
          () => _filters = _filters.without(CatalogFilterField.contributor),
        ),
      ),
    if (_filters.publicationStatus case final status?)
      InputChip(
        label: Text('Status: ${_statusLabel(status)}'),
        onDeleted: () => setState(
          () => _filters = _filters.without(CatalogFilterField.status),
        ),
      ),
    if (_filters.releaseDatePrefix case final date?)
      InputChip(
        label: Text('Release: $date'),
        onDeleted: () => setState(
          () => _filters = _filters.without(CatalogFilterField.releaseDate),
        ),
      ),
    if (_filters.workId != null)
      InputChip(
        label: const Text('Same work'),
        tooltip: _filters.workId,
        onDeleted: () => setState(
          () => _filters = _filters.without(CatalogFilterField.work),
        ),
      ),
    if (_filters.releaseFrom != null || _filters.releaseThrough != null)
      InputChip(
        label: Text(
          '${_filters.releaseFrom ?? 'Any date'} to ${_filters.releaseThrough ?? 'Any date'}',
        ),
        tooltip: 'Includes partial dates that overlap this range.',
        onDeleted: () => setState(
          () => _filters = _filters.without(CatalogFilterField.releaseRange),
        ),
      ),
    if (!_filters.isEmpty)
      TextButton(
        onPressed: () => setState(() => _filters = const CatalogFilters()),
        child: const Text('Clear filters'),
      ),
  ];

  Widget _sidebar(CatalogSnapshot? snapshot, bool canEdit) {
    final palette = ShelfPalette.of(context);
    final editions = snapshot?.editions ?? const <CatalogEdition>[];
    int count(String status) =>
        editions.where((edition) => edition.publicationStatus == status).length;
    final online = !_showingCachedSnapshot && _error == null;
    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: palette.rail,
        border: Border(right: BorderSide(color: palette.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 22),
            child: _Wordmark(),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                const _RailHeading('Views'),
                _RailItem(
                  icon: Icons.grid_view_outlined,
                  label: 'Gallery',
                  selected: _view == _CatalogView.gallery,
                  onTap: () => setState(() => _view = _CatalogView.gallery),
                ),
                _RailItem(
                  icon: Icons.table_rows_outlined,
                  label: 'Table',
                  selected: _view == _CatalogView.table,
                  onTap: () => setState(() => _view = _CatalogView.table),
                ),
                _RailItem(
                  icon: Icons.calendar_month_outlined,
                  label: 'Release calendar',
                  selected: _view == _CatalogView.calendar,
                  onTap: () => setState(() => _view = _CatalogView.calendar),
                ),
                const SizedBox(height: 20),
                const _RailHeading('Publication status'),
                _RailItem(
                  label: 'All editions',
                  count: editions.length,
                  selected: _filters.publicationStatus == null,
                  onTap: snapshot == null ? null : () => _setStatusFilter(null),
                ),
                for (final status in const [
                  'planned',
                  'announced',
                  'released',
                  'out_of_print',
                ])
                  _RailItem(
                    label: _statusLabel(status),
                    count: count(status),
                    selected: _filters.publicationStatus == status,
                    onTap: snapshot == null
                        ? null
                        : () => _setStatusFilter(status),
                  ),
                const SizedBox(height: 20),
                const _RailHeading('Tools'),
                _RailItem(
                  icon: Icons.swap_horiz,
                  label: 'File exchange',
                  onTap: snapshot != null && online && !_busy
                      ? () => _runTool('exchange')
                      : null,
                ),
                if (snapshot?.role == CatalogRole.administrator && canEdit)
                  _RailItem(
                    icon: Icons.group_outlined,
                    label: 'Manage members',
                    onTap: _busy ? null : () => _runTool('members'),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: palette.hairline)),
            ),
            child: Row(
              children: [
                Icon(
                  online ? Icons.circle : Icons.cloud_off_outlined,
                  size: online ? 8 : 16,
                  color: online ? const Color(0xff2e9d57) : palette.inkMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    snapshot == null
                        ? (online ? 'Connecting…' : 'Offline')
                        : '${snapshot.role.label}${online ? '' : ' · read-only'}',
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _runTool('signout'),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final snapshot = _snapshot;
    final records = sortedCatalog(
      snapshot?.editions.where(
            (edition) =>
                edition.matches(_search.text) && _filters.matches(edition),
          ) ??
          const <CatalogEdition>[],
      _sort,
      _sortAscending,
    );
    final canEdit = canEditCatalog(
      snapshot?.role,
      connected: _error == null && !_showingCachedSnapshot,
    );
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1100;
    final chips = _filterChips();
    final ready =
        !_busy &&
        (_error == null || _showingCachedSnapshot) &&
        snapshot != null;
    final toolbar = Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!wide) ...[const _Wordmark(), const SizedBox(width: 20)],
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: TextField(
                    controller: _search,
                    onChanged: (query) => setState(() {
                      if (_selected != null &&
                          (!_selected!.matches(query) ||
                              !_filters.matches(_selected!))) {
                        _selected = null;
                      }
                    }),
                    decoration: InputDecoration(
                      hintText: 'Search title, ISBN, contributor, or category',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _search.clear();
                                setState(() {});
                              },
                              icon: const Icon(Icons.clear, size: 18),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _configureFilters,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Filters'),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Reload catalog',
                onPressed: _busy ? null : _reload,
                icon: const Icon(Icons.refresh, size: 20),
              ),
              if (!wide)
                PopupMenuButton<String>(
                  tooltip: 'Catalog tools',
                  enabled: !_busy,
                  icon: const Icon(Icons.more_horiz),
                  onSelected: _runTool,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'exchange',
                      enabled:
                          snapshot != null &&
                          !_showingCachedSnapshot &&
                          _error == null,
                      child: const Text('File exchange'),
                    ),
                    if (snapshot?.role == CatalogRole.administrator && canEdit)
                      const PopupMenuItem(
                        value: 'members',
                        child: Text('Manage members'),
                      ),
                    const PopupMenuItem(
                      value: 'signout',
                      child: Text('Sign out'),
                    ),
                  ],
                ),
              if (canEdit) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Add edition',
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _createEdition,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(width >= 760 ? 'New edition' : 'New'),
                  ),
                ),
              ],
            ],
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: chips,
            ),
          ],
          if (ready) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          '${records.length} matching ${records.length == 1 ? 'edition' : 'editions'}',
                          style: textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_offlineWarning != null && _error == null) ...[
                        const SizedBox(width: 14),
                        Icon(
                          Icons.cloud_off_outlined,
                          size: 15,
                          color: palette.inkMuted,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _offlineWarning!,
                              style: textTheme.bodySmall?.copyWith(
                                color: palette.inkMuted,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (!wide) ...[
                  SegmentedButton<_CatalogView>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: _CatalogView.gallery,
                        icon: const Icon(Icons.grid_view_outlined, size: 16),
                        tooltip: 'Gallery',
                      ),
                      ButtonSegment(
                        value: _CatalogView.table,
                        icon: const Icon(Icons.table_rows_outlined, size: 16),
                        tooltip: 'Table',
                      ),
                      ButtonSegment(
                        value: _CatalogView.calendar,
                        icon: const Icon(
                          Icons.calendar_month_outlined,
                          size: 16,
                        ),
                        tooltip: 'Release calendar',
                      ),
                    ],
                    selected: {_view},
                    onSelectionChanged: (selection) =>
                        setState(() => _view = selection.first),
                  ),
                  const SizedBox(width: 12),
                ],
                PopupMenuButton<CatalogSort>(
                  tooltip: 'Sort catalog',
                  initialValue: _sort,
                  onSelected: (field) => setState(() => _sort = field),
                  itemBuilder: (context) => [
                    for (final field in CatalogSort.values)
                      CheckedPopupMenuItem(
                        value: field,
                        checked: _sort == field,
                        child: Text(field.label),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sort, size: 18, color: palette.inkMuted),
                        const SizedBox(width: 6),
                        Text(
                          'Sorted by ${_sort.label.toLowerCase()}',
                          style: textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _sortAscending
                      ? 'Sort descending'
                      : 'Sort ascending',
                  onPressed: () =>
                      setState(() => _sortAscending = !_sortAscending),
                  icon: Icon(
                    _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
    final workspace = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolbar,
        if (_busy) ...[
          const SizedBox(height: 14),
          const LinearProgressIndicator(),
          const Expanded(child: _LoadingShelf()),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: _showingCachedSnapshot
                ? _CatalogError(
                    error: _error!,
                    onRetry: _reload,
                    showingCachedSnapshot: true,
                    lease: _offlineEntry?.lease,
                  )
                : null,
          ),
        if (_error != null && !_showingCachedSnapshot)
          _CatalogError(
            error: _error!,
            onRetry: _reload,
            lease: _offlineEntry?.lease,
          ),
        if (ready)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 560;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                        child: records.isEmpty
                            ? _EmptyResults(
                                query: _search.text,
                                filtered: !_filters.isEmpty,
                                onClear: () {
                                  _search.clear();
                                  setState(() {});
                                },
                                onClearFilters: () => setState(
                                  () => _filters = const CatalogFilters(),
                                ),
                              )
                            : _catalogView(records, compact, wide),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
    return Scaffold(
      body: SafeArea(
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sidebar(snapshot, canEdit),
                  Expanded(child: workspace),
                  if (ready)
                    Container(
                      width: 388,
                      decoration: BoxDecoration(
                        color: palette.paper,
                        border: Border(
                          left: BorderSide(color: palette.hairline),
                        ),
                      ),
                      child: _selected == null
                          ? const _DetailPrompt()
                          : _EditionDetails(
                              key: ValueKey(_selected!.id),
                              edition: _selected!,
                              repository: _repository,
                              online: !_showingCachedSnapshot && _error == null,
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                24,
                                24,
                                32,
                              ),
                              onEdit: canEdit ? () => _edit(_selected!) : null,
                              onEditRelationships: canEdit
                                  ? () => _editRelations(_selected!)
                                  : null,
                              onAddEdition: canEdit
                                  ? () => _createEdition(
                                      relatedEdition: _selected!,
                                    )
                                  : null,
                              onContributor: _filterByContributor,
                              onCategory: _filterByCategory,
                              onShowWork: () => _filterToWork(_selected!),
                              onChooseCover: canEdit
                                  ? () => _selectCover(_selected!)
                                  : null,
                              onRemoveCover:
                                  canEdit && _selected!.coverKey != null
                                  ? () => _removeCover(_selected!)
                                  : null,
                              coverBusy: _coverBusy,
                            ),
                    ),
                ],
              )
            : workspace,
      ),
    );
  }
}

class _RailHeading extends StatelessWidget {
  const _RailHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.label,
    this.icon,
    this.count,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final int? count;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final foreground = onTap == null && !selected
        ? palette.inkMuted.withAlpha(150)
        : selected
        ? palette.onAccent
        : palette.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? palette.accent : Colors.transparent,
          borderRadius: shelfRadius,
          child: InkWell(
            borderRadius: shelfRadius,
            onTap: onTap,
            child: SizedBox(
              height: 34,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: foreground),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: foreground,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (count != null)
                      Text(
                        '$count',
                        style: shelfMono.copyWith(
                          fontSize: 12,
                          color: selected ? palette.onAccent : palette.inkMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingShelf extends StatelessWidget {
  const _LoadingShelf();

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Semantics(
      label: 'Loading catalog',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = ((constraints.maxWidth + 20) / 196).floor().clamp(
                1,
                12,
              );
              return Wrap(
                spacing: 20,
                runSpacing: 24,
                children: [
                  for (var index = 0; index < columns; index++)
                    SizedBox(
                      width: 176,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AspectRatio(
                            aspectRatio: 2 / 3,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: palette.blankBoard,
                                borderRadius: shelfRadius,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            height: 10,
                            width: 130,
                            color: palette.blankBoard,
                          ),
                          const SizedBox(height: 6),
                          Container(
                            height: 10,
                            width: 80,
                            color: palette.blankBoard,
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _EditionList extends StatelessWidget {
  const _EditionList({
    required this.records,
    required this.canEdit,
    required this.selectedId,
    required this.onSelect,
  });

  final List<CatalogEdition> records;
  final bool canEdit;
  final String? selectedId;
  final ValueChanged<CatalogEdition> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: records.length,
      separatorBuilder: (context, index) =>
          Divider(height: 1, color: palette.hairline),
      itemBuilder: (context, index) {
        final edition = records[index];
        return ListTile(
          selected: edition.id == selectedId,
          title: Text(edition.title),
          subtitle: Text(
            '${edition.format} · ${edition.isbn ?? 'No ISBN'} · ${edition.releaseDate ?? 'Date unknown'}',
            style: shelfMono.copyWith(fontSize: 12, color: palette.inkMuted),
          ),
          onTap: () => onSelect(edition),
          trailing: canEdit
              ? const Icon(Icons.edit_outlined, size: 18)
              : const Icon(Icons.chevron_right),
        );
      },
    );
  }
}

class _EditionDataSource extends DataTableSource {
  _EditionDataSource({
    required this.records,
    required this.selectedId,
    required this.onSelect,
    required this.muted,
  });

  final List<CatalogEdition> records;
  final String? selectedId;
  final ValueChanged<CatalogEdition> onSelect;
  final Color muted;

  @override
  DataRow? getRow(int index) {
    if (index >= records.length) return null;
    final edition = records[index];
    final mono = shelfMono.copyWith(fontSize: 12.5);
    return DataRow.byIndex(
      index: index,
      selected: edition.id == selectedId,
      onSelectChanged: (_) => onSelect(edition),
      cells: [
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text(
              edition.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        DataCell(Text(edition.format)),
        DataCell(
          Text(
            edition.isbn ?? 'No ISBN',
            style: edition.isbn == null ? TextStyle(color: muted) : mono,
          ),
        ),
        DataCell(
          Text(
            edition.releaseDate ?? 'Date unknown',
            style: edition.releaseDate == null ? TextStyle(color: muted) : mono,
          ),
        ),
      ],
    );
  }

  @override
  bool get isRowCountApproximate => false;

  @override
  int get rowCount => records.length;

  @override
  int get selectedRowCount =>
      records.any((edition) => edition.id == selectedId) ? 1 : 0;
}

class _EditionTable extends StatelessWidget {
  const _EditionTable({
    required this.records,
    required this.selectedId,
    required this.onSelect,
    required this.sort,
    required this.sortAscending,
    required this.onSort,
  });

  final List<CatalogEdition> records;
  final String? selectedId;
  final ValueChanged<CatalogEdition> onSelect;
  final CatalogSort sort;
  final bool sortAscending;
  final void Function(CatalogSort, bool) onSort;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Theme(
        data: Theme.of(context).copyWith(
          cardTheme: CardThemeData(
            color: palette.paper,
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: shelfRadius,
              side: BorderSide(color: palette.hairline),
            ),
          ),
        ),
        child: PaginatedDataTable(
          showCheckboxColumn: false,
          headingRowHeight: 44,
          dataRowMinHeight: 44,
          dataRowMaxHeight: 48,
          horizontalMargin: 18,
          columnSpacing: 28,
          rowsPerPage: records.length < 25 ? records.length.clamp(1, 25) : 25,
          availableRowsPerPage: const [10, 25, 50, 100],
          sortColumnIndex: sort.index,
          sortAscending: sortAscending,
          columns: [
            for (final field in CatalogSort.values)
              DataColumn(
                label: Text(field.label),
                onSort: (_, ascending) => onSort(field, ascending),
              ),
          ],
          source: _EditionDataSource(
            records: records,
            selectedId: selectedId,
            onSelect: onSelect,
            muted: palette.inkMuted,
          ),
        ),
      ),
    );
  }
}

class _EditionGallery extends StatelessWidget {
  const _EditionGallery({
    required this.records,
    required this.repository,
    required this.online,
    required this.selectedId,
    required this.onSelect,
  });

  final List<CatalogEdition> records;
  final CatalogRepository repository;
  final bool online;
  final String? selectedId;
  final ValueChanged<CatalogEdition> onSelect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = 22.0;
      final columns = ((constraints.maxWidth + spacing) / (176 + spacing))
          .floor()
          .clamp(1, 12);
      final tileWidth =
          (constraints.maxWidth - spacing * (columns - 1)) / columns;
      return GridView.builder(
        padding: const EdgeInsets.only(top: 6, bottom: 32),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 28,
          mainAxisExtent: tileWidth * 1.5 + 92,
        ),
        itemCount: records.length,
        itemBuilder: (context, index) {
          final edition = records[index];
          return _GalleryTile(
            edition: edition,
            repository: repository,
            online: online,
            selected: edition.id == selectedId,
            onTap: () => onSelect(edition),
          );
        },
      );
    },
  );
}

class _GalleryTile extends StatefulWidget {
  const _GalleryTile({
    required this.edition,
    required this.repository,
    required this.online,
    required this.selected,
    required this.onTap,
  });

  final CatalogEdition edition;
  final CatalogRepository repository;
  final bool online;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<_GalleryTile> {
  bool _lifted = false;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final edition = widget.edition;
    final selected = widget.selected;
    final lifted = _lifted || selected;
    final contributor = edition.credits.isEmpty
        ? null
        : edition.credits.first.contributor.name;
    return Semantics(
      button: true,
      selected: selected,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _lifted = value),
        onShowFocusHighlight: (value) => setState(() => _lifted = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(0, lifted ? -3 : 0, 0),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(lifted ? 70 : 38),
                      offset: Offset(0, lifted ? 10 : 4),
                      blurRadius: lifted ? 22 : 10,
                    ),
                  ],
                ),
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(2)),
                    child: _CoverPreview(
                      edition: edition,
                      repository: widget.repository,
                      online: widget.online,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: EdgeInsets.symmetric(
                  horizontal: selected ? 8 : 0,
                  vertical: selected ? 6 : 0,
                ),
                decoration: BoxDecoration(
                  color: selected ? palette.accent : Colors.transparent,
                  borderRadius: shelfRadius,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      edition.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                        color: selected ? palette.onAccent : palette.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        ?contributor,
                        edition.format,
                        edition.releaseDate ?? 'Date unknown',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: selected ? palette.onAccent : palette.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

class ReleaseCalendarView extends StatelessWidget {
  const ReleaseCalendarView({
    super.key,
    required this.records,
    required this.selectedId,
    required this.onSelect,
    this.repository,
    this.online = false,
  });

  final List<CatalogEdition> records;
  final String? selectedId;
  final ValueChanged<CatalogEdition> onSelect;
  final CatalogRepository? repository;
  final bool online;

  static String _monthKey(String? date) {
    if (date == null || date.length < 4) return '~';
    if (date.length == 4) return '$date-13';
    return date.substring(0, 7);
  }

  static String monthHeading(String key) {
    if (key == '~') return 'Date not set';
    final year = key.substring(0, 4);
    final month = int.tryParse(key.substring(5, 7)) ?? 13;
    if (month < 1 || month > 12) return '$year · month not set';
    return '${_monthNames[month - 1]} $year';
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final grouped = <String, List<CatalogEdition>>{};
    for (final edition in records) {
      grouped
          .putIfAbsent(_monthKey(edition.releaseDate), () => [])
          .add(edition);
    }
    final keys = grouped.keys.toList()..sort();
    for (final list in grouped.values) {
      list.sort(
        (left, right) =>
            (left.releaseDate ?? '').compareTo(right.releaseDate ?? ''),
      );
    }
    final entries = <({String? heading, int count, CatalogEdition? edition})>[];
    for (final key in keys) {
      final group = grouped[key]!;
      entries.add((
        heading: monthHeading(key),
        count: group.length,
        edition: null,
      ));
      for (final edition in group) {
        entries.add((heading: null, count: 0, edition: edition));
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 32),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.heading case final heading?) {
          return Container(
            margin: EdgeInsets.only(top: index == 0 ? 4 : 28, bottom: 4),
            padding: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.ink, width: 1)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  heading,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${entry.count} ${entry.count == 1 ? 'edition' : 'editions'}',
                  style: textTheme.bodySmall?.copyWith(color: palette.inkMuted),
                ),
              ],
            ),
          );
        }
        final edition = entry.edition!;
        final date = edition.releaseDate;
        final day = date != null && date.length == 10
            ? date.substring(8, 10)
            : '—';
        final selected = edition.id == selectedId;
        return Material(
          color: selected ? palette.accent : Colors.transparent,
          borderRadius: shelfRadius,
          child: InkWell(
            borderRadius: shelfRadius,
            onTap: () => onSelect(edition),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selected ? Colors.transparent : palette.hairline,
                  ),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      day,
                      style: shelfMono.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: selected ? palette.onAccent : palette.ink,
                      ),
                    ),
                  ),
                  if (repository case final repository?) ...[
                    SizedBox(
                      width: 30,
                      height: 45,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(1),
                        ),
                        child: _CoverPreview(
                          edition: edition,
                          repository: repository,
                          online: online,
                          fit: BoxFit.cover,
                          compact: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          edition.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: selected ? palette.onAccent : null,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${edition.format} · ${edition.isbn ?? 'No ISBN'}',
                          style: textTheme.bodySmall?.copyWith(
                            color: selected
                                ? palette.onAccent
                                : palette.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  StatusTag(
                    status: edition.publicationStatus,
                    label: _statusLabel(edition.publicationStatus),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DetailPrompt extends StatelessWidget {
  const _DetailPrompt();

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(opacity: 0.5, child: const ShelfMark(size: 36)),
            const SizedBox(height: 22),
            Text(
              'Select an edition to review its details.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: palette.inkMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _EditionDetails extends StatelessWidget {
  const _EditionDetails({
    super.key,
    required this.edition,
    required this.repository,
    required this.online,
    this.showTitle = true,
    this.padding = EdgeInsets.zero,
    this.onEdit,
    this.onEditRelationships,
    this.onAddEdition,
    this.onContributor,
    this.onCategory,
    this.onShowWork,
    this.onChooseCover,
    this.onRemoveCover,
    this.coverBusy = false,
  });

  final CatalogEdition edition;
  final CatalogRepository repository;
  final bool online;
  final bool showTitle;
  final EdgeInsets padding;
  final VoidCallback? onEdit;
  final VoidCallback? onEditRelationships;
  final VoidCallback? onAddEdition;
  final ValueChanged<CatalogReference>? onContributor;
  final ValueChanged<CatalogReference>? onCategory;
  final VoidCallback? onShowWork;
  final VoidCallback? onChooseCover;
  final VoidCallback? onRemoveCover;
  final bool coverBusy;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final credits = edition.credits;
    final byline = credits
        .where((credit) => credit.role == 'author')
        .map((credit) => credit.contributor.name)
        .join(', ');
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: Text(
        title,
        style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
    return SingleChildScrollView(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 112,
                decoration: const BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x33000000),
                      offset: Offset(0, 4),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(2)),
                    child: _CoverPreview(
                      edition: edition,
                      repository: repository,
                      online: online,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showTitle) ...[
                      SelectableText(
                        edition.title,
                        style: textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (byline.isNotEmpty) ...[
                      Text(
                        byline,
                        style: textTheme.bodyMedium?.copyWith(
                          color: palette.inkMuted,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    StatusTag(
                      status: edition.publicationStatus,
                      label: _statusLabel(edition.publicationStatus),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Align(
            alignment: Alignment.centerLeft,
            child: IsbnLabel(isbn: edition.isbn),
          ),
          const SizedBox(height: 18),
          _FactGrid(
            facts: [
              ('Format', edition.format, false),
              ('Language', edition.language, true),
              (
                'Release date',
                edition.releaseDate ?? 'Not set',
                edition.releaseDate != null,
              ),
              ('ISBN-13', edition.isbn ?? 'Not assigned', edition.isbn != null),
            ],
          ),
          _DetailLine(label: 'Work ID', value: edition.workId, mono: true),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
              ),
              onPressed: onShowWork,
              child: const Text('Show all editions of this work'),
            ),
          ),
          if (onEdit != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: onEdit,
                    child: const Text('Edit edition'),
                  ),
                ),
                if (onAddEdition != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: coverBusy ? null : onAddEdition,
                      child: const Text(
                        'Add another edition',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (credits.isNotEmpty) ...[
            section('Contributors'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final credit in credits)
                  ActionChip(
                    label: Text('${credit.contributor.name} · ${credit.role}'),
                    onPressed: onContributor == null
                        ? null
                        : () => onContributor!(credit.contributor),
                  ),
              ],
            ),
          ],
          if (edition.categories.isNotEmpty) ...[
            section('Categories'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final category in edition.categoryReferences)
                  ActionChip(
                    label: Text(category.name),
                    onPressed: onCategory == null
                        ? null
                        : () => onCategory!(category),
                  ),
              ],
            ),
          ],
          if (onEditRelationships != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: coverBusy ? null : onEditRelationships,
                child: const Text('Edit contributors and categories'),
              ),
            ),
          if (edition.description.isNotEmpty) ...[
            section('Description'),
            SelectableText(
              edition.description,
              style: textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
          if (onChooseCover != null || onRemoveCover != null) ...[
            section('Cover'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (onChooseCover != null)
                  OutlinedButton.icon(
                    onPressed: coverBusy ? null : onChooseCover,
                    icon: coverBusy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 18,
                          ),
                    label: Text(
                      coverBusy
                          ? 'Uploading cover…'
                          : edition.coverKey == null
                          ? 'Add cover'
                          : 'Replace cover',
                    ),
                  ),
                if (onRemoveCover != null)
                  TextButton.icon(
                    onPressed: coverBusy ? null : onRemoveCover,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove cover'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FactGrid extends StatelessWidget {
  const _FactGrid({required this.facts});

  final List<(String, String, bool)> facts;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final rows = <TableRow>[];
    for (var index = 0; index < facts.length; index += 2) {
      rows.add(
        TableRow(
          children: [
            for (final fact in facts.skip(index).take(2))
              _DetailLine(label: fact.$1, value: fact.$2, mono: fact.$3),
            if (index + 1 >= facts.length) const SizedBox.shrink(),
          ],
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.hairline)),
      ),
      child: Table(children: rows),
    );
  }
}

class _CoverPreview extends StatelessWidget {
  const _CoverPreview({
    required this.edition,
    required this.repository,
    required this.fit,
    required this.online,
    this.compact = false,
  });

  final CatalogEdition edition;
  final CatalogRepository repository;
  final BoxFit fit;
  final bool online;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final key = edition.coverKey;
    return ColoredBox(
      color: ShelfPalette.of(context).blankBoard,
      child: key == null
          ? _blankBoard(context, null)
          : !online
          ? _blankBoard(context, 'Cover not cached')
          : FutureBuilder<String>(
              future: repository.signedCoverUrl(key),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return _blankBoard(
                    context,
                    snapshot.hasError ? 'Cover unavailable' : null,
                  );
                }
                return Image.network(
                  snapshot.data!,
                  fit: fit,
                  width: double.infinity,
                  height: double.infinity,
                  semanticLabel: 'Cover of ${edition.title}',
                  errorBuilder: (context, error, stackTrace) =>
                      _blankBoard(context, 'Cover unavailable'),
                );
              },
            ),
    );
  }

  Widget _blankBoard(BuildContext context, String? note) {
    if (compact) return const SizedBox.expand();
    final palette = ShelfPalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final small = constraints.maxWidth < 140;
        return Padding(
          padding: EdgeInsets.all(small ? 10 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(height: 2, width: 28, color: palette.inkMuted),
              SizedBox(height: small ? 8 : 12),
              Expanded(
                child: Text(
                  edition.title,
                  overflow: TextOverflow.fade,
                  style: TextStyle(
                    fontSize: small ? 11 : 16,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: palette.inkMuted,
                  ),
                ),
              ),
              Text(
                note ?? 'No cover',
                style: TextStyle(
                  fontSize: small ? 9 : 11,
                  color: palette.inkMuted,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(color: palette.inkMuted),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: mono
                ? shelfMono.copyWith(fontSize: 13, color: palette.ink)
                : textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class MembershipManagementScreen extends StatefulWidget {
  const MembershipManagementScreen({
    super.key,
    required this.repository,
    required this.currentUserId,
  });

  final CatalogRepository repository;
  final String currentUserId;

  @override
  State<MembershipManagementScreen> createState() =>
      _MembershipManagementScreenState();
}

class _MembershipManagementScreenState
    extends State<MembershipManagementScreen> {
  List<CatalogMember> _members = const [];
  Object? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final members = await widget.repository.loadMembers();
      if (mounted) setState(() => _members = members);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _report(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addMember() async {
    final addition = await showDialog<({String email, CatalogRole role})>(
      context: context,
      builder: (context) => const _AddMemberDialog(),
    );
    if (addition == null) return;
    setState(() => _saving = true);
    try {
      final member = await widget.repository.addMember(
        addition.email,
        addition.role,
      );
      if (!mounted) return;
      setState(() {
        _members = [..._members, member]
          ..sort((left, right) => left.email.compareTo(right.email));
      });
      _report('Access granted to ${member.email}.');
    } catch (error) {
      if (mounted) _report('Could not add member: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editMember(CatalogMember member) async {
    final changes = await showDialog<({CatalogRole role, bool active})>(
      context: context,
      builder: (context) => _EditMemberDialog(member: member),
    );
    if (changes == null) return;
    setState(() => _saving = true);
    try {
      final updated = await widget.repository.updateMember(
        userId: member.userId,
        role: changes.role,
        active: changes.active,
      );
      if (!mounted) return;
      setState(() {
        _members = _members
            .map(
              (current) => current.userId == updated.userId ? updated : current,
            )
            .toList();
      });
      _report('Access updated for ${updated.email}.');
    } catch (error) {
      if (mounted) _report('Could not update member: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Catalog members'),
      actions: [
        IconButton(
          tooltip: 'Reload members',
          onPressed: _loading || _saving ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Add member',
          onPressed: _loading || _saving ? null : _addMember,
          icon: const Icon(Icons.person_add_alt_1),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 16, 24, 12),
                child: Text(
                  'Only approved members can open the catalog. Add accounts after they have signed in once; account invitations remain with your identity administrator.',
                ),
              ),
              if (_saving) const LinearProgressIndicator(),
              if (_loading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Memberships could not be loaded.',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(_error.toString(), textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: _load,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_members.isEmpty)
                const Expanded(
                  child: Center(child: Text('No catalog memberships found.')),
                )
              else
                Expanded(
                  child: ListView.separated(
                    itemCount: _members.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1, indent: 24, endIndent: 24),
                    itemBuilder: (context, index) {
                      final member = _members[index];
                      final canChange = member.userId != widget.currentUserId;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 4,
                        ),
                        leading: CircleAvatar(
                          child: Text(
                            member.email.isEmpty
                                ? '?'
                                : member.email[0].toUpperCase(),
                          ),
                        ),
                        title: Text(
                          member.email.isEmpty ? member.userId : member.email,
                        ),
                        subtitle: Text(
                          '${member.role.label} · ${member.active ? 'Active' : 'Deactivated'}',
                        ),
                        trailing: canChange
                            ? IconButton(
                                tooltip: 'Change ${member.email} access',
                                onPressed: _saving
                                    ? null
                                    : () => _editMember(member),
                                icon: const Icon(Icons.edit_outlined),
                              )
                            : const Tooltip(
                                message: 'Ask another administrator to change your own access.',
                                child: Icon(Icons.lock_outline),
                              ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AddMemberDialog extends StatefulWidget {
  const _AddMemberDialog();

  @override
  State<_AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends State<_AddMemberDialog> {
  final _email = TextEditingController();
  CatalogRole _role = CatalogRole.viewer;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _add() {
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Enter a valid account email address.');
      return;
    }
    Navigator.pop(context, (email: email, role: _role));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add catalog member'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Account email'),
          ),
          DropdownButtonFormField<CatalogRole>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Catalog role'),
            items: CatalogRole.values
                .map(
                  (role) =>
                      DropdownMenuItem(value: role, child: Text(role.label)),
                )
                .toList(),
            onChanged: (role) {
              if (role != null) setState(() => _role = role);
            },
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _add, child: const Text('Grant access')),
    ],
  );
}

class _EditMemberDialog extends StatefulWidget {
  const _EditMemberDialog({required this.member});

  final CatalogMember member;

  @override
  State<_EditMemberDialog> createState() => _EditMemberDialogState();
}

class _EditMemberDialogState extends State<_EditMemberDialog> {
  late CatalogRole _role = widget.member.role;
  late bool _active = widget.member.active;

  void _save() {
    if (_role == widget.member.role && _active == widget.member.active) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, (role: _role, active: _active));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Member access'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(widget.member.email),
          ),
          DropdownButtonFormField<CatalogRole>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Catalog role'),
            items: CatalogRole.values
                .map(
                  (role) =>
                      DropdownMenuItem(value: role, child: Text(role.label)),
                )
                .toList(),
            onChanged: (role) {
              if (role != null) setState(() => _role = role);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active membership'),
            value: _active,
            onChanged: (value) => setState(() => _active = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save access')),
    ],
  );
}

class _CatalogFilterDialog extends StatefulWidget {
  const _CatalogFilterDialog({required this.current});

  final CatalogFilters current;

  @override
  State<_CatalogFilterDialog> createState() => _CatalogFilterDialogState();
}

class _CatalogFilterDialogState extends State<_CatalogFilterDialog> {
  late final _category = TextEditingController(
    text: widget.current.categoryQuery ?? '',
  );
  late final _contributor = TextEditingController(
    text: widget.current.contributorQuery ?? '',
  );
  late final _releaseDate = TextEditingController(
    text: widget.current.releaseDatePrefix ?? '',
  );
  late final _releaseFrom = TextEditingController(
    text: widget.current.releaseFrom ?? '',
  );
  late final _releaseThrough = TextEditingController(
    text: widget.current.releaseThrough ?? '',
  );
  late String _status = widget.current.publicationStatus ?? 'all';
  late String? _workId = widget.current.workId;
  String? _error;

  @override
  void dispose() {
    _category.dispose();
    _contributor.dispose();
    _releaseDate.dispose();
    _releaseFrom.dispose();
    _releaseThrough.dispose();
    super.dispose();
  }

  String? _optional(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _apply() {
    final date = _optional(_releaseDate.text);
    final from = _optional(_releaseFrom.text);
    final through = _optional(_releaseThrough.text);
    if (date != null && !isValidReleaseDate(date)) {
      setState(() {
        _error = 'Use a real date in YYYY, YYYY-MM, or YYYY-MM-DD format.';
      });
      return;
    }
    if ([from, through].any(
          (value) =>
              value != null &&
              (value.length != 10 || !isValidReleaseDate(value)),
        ) ||
        (from != null && through != null && from.compareTo(through) > 0)) {
      setState(
        () => _error =
            'Use full YYYY-MM-DD range dates, with From no later than Through.',
      );
      return;
    }
    Navigator.pop(
      context,
      CatalogFilters(
        categoryQuery: _optional(_category.text),
        contributorQuery: _optional(_contributor.text),
        categoryId: _optional(_category.text) == widget.current.categoryQuery
            ? widget.current.categoryId
            : null,
        contributorId:
            _optional(_contributor.text) == widget.current.contributorQuery
            ? widget.current.contributorId
            : null,
        workId: _workId,
        publicationStatus: _status == 'all' ? null : _status,
        releaseDatePrefix: date,
        releaseFrom: from,
        releaseThrough: through,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Filter catalog'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _category,
              decoration: const InputDecoration(
                labelText: 'Category contains',
                hintText: 'e.g. Fiction',
              ),
            ),
            TextField(
              controller: _contributor,
              decoration: const InputDecoration(
                labelText: 'Contributor contains',
                hintText: 'e.g. surname',
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(
                labelText: 'Publication status',
              ),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('Any status')),
                DropdownMenuItem(value: 'planned', child: Text('Planned')),
                DropdownMenuItem(value: 'announced', child: Text('Announced')),
                DropdownMenuItem(value: 'released', child: Text('Released')),
                DropdownMenuItem(
                  value: 'out_of_print',
                  child: Text('Out of print'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _status = value);
              },
            ),
            TextField(
              controller: _releaseDate,
              decoration: const InputDecoration(
                labelText: 'Release date starts with',
                hintText: 'YYYY, YYYY-MM, or YYYY-MM-DD',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _releaseFrom,
              decoration: const InputDecoration(
                labelText: 'Release range: from',
                hintText: 'YYYY-MM-DD',
              ),
            ),
            TextField(
              controller: _releaseThrough,
              decoration: const InputDecoration(
                labelText: 'Release range: through',
                hintText: 'YYYY-MM-DD',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Includes year-only and month-only dates that could fall in the range. Unknown dates are excluded.',
            ),
            TextButton(
              onPressed: () {
                final today = DateTime.now();
                _releaseFrom.text = catalogDate(today);
                _releaseThrough.text = catalogDate(sixMonthsAfter(today));
                _releaseDate.clear();
                setState(() => _error = null);
              },
              child: const Text('Next six months'),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          _category.clear();
          _contributor.clear();
          _releaseDate.clear();
          _releaseFrom.clear();
          _releaseThrough.clear();
          setState(() {
            _status = 'all';
            _workId = null;
            _error = null;
          });
        },
        child: const Text('Reset'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _apply, child: const Text('Apply filters')),
    ],
  );
}

class _CatalogError extends StatelessWidget {
  const _CatalogError({
    required this.error,
    required this.onRetry,
    this.showingCachedSnapshot = false,
    this.lease,
  });

  final Object error;
  final VoidCallback onRetry;
  final bool showingCachedSnapshot;
  final OfflineLease? lease;

  static String _stamp(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    if (showingCachedSnapshot) {
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: palette.paper,
          borderRadius: shelfRadius,
          border: Border.all(color: palette.hairline),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 18, color: palette.inkMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Showing the verified saved catalog read-only. Reconnect and reload to edit.'
                '${lease == null ? '' : '\nVerified ${_stamp(lease!.issuedAt)}. Offline access ends ${_stamp(lease!.expiresAt)}.'}',
                style: textTheme.bodySmall?.copyWith(height: 1.45),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
    }
    return Expanded(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  error is OfflineAccessUnavailable
                      ? Icons.cloud_off_outlined
                      : error is CatalogAccessDenied
                      ? Icons.lock_outline
                      : Icons.error_outline,
                  size: 28,
                  color: palette.inkMuted,
                ),
                const SizedBox(height: 14),
                Text(
                  error is OfflineAccessUnavailable
                      ? 'Offline access unavailable'
                      : error is CatalogAccessDenied
                      ? 'Catalog access is not approved'
                      : 'Catalog could not be loaded',
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  error.toString(),
                  style: textTheme.bodyMedium?.copyWith(
                    color: palette.inkMuted,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({
    required this.query,
    required this.onClear,
    this.filtered = false,
    this.onClearFilters,
  });

  final String query;
  final VoidCallback onClear;
  final bool filtered;
  final VoidCallback? onClearFilters;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final narrowed = query.isNotEmpty || filtered;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              narrowed
                  ? 'No editions match.'
                  : 'No editions in this catalog yet.',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              narrowed
                  ? 'Try a broader search or remove a filter.'
                  : 'Add an edition or import a file to start the catalog.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: palette.inkMuted),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                if (query.isNotEmpty)
                  OutlinedButton(
                    onPressed: onClear,
                    child: const Text('Clear search'),
                  ),
                if (filtered && onClearFilters != null)
                  OutlinedButton(
                    onPressed: onClearFilters,
                    child: const Text('Clear filters'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class EditionMetadataDialog extends StatefulWidget {
  const EditionMetadataDialog({
    super.key,
    required this.repository,
    required this.edition,
    this.workId,
    this.initialTitle,
    this.onConnectivityFailure,
  });

  final CatalogRepository repository;
  final CatalogEdition? edition;
  final String? workId;
  final String? initialTitle;
  final ValueChanged<Object>? onConnectivityFailure;

  @override
  State<EditionMetadataDialog> createState() => _EditionMetadataDialogState();
}

class _EditionMetadataDialogState extends State<EditionMetadataDialog> {
  late final _title = TextEditingController(
    text: widget.edition?.title ?? widget.initialTitle ?? '',
  );
  late final _language = TextEditingController(
    text: widget.edition?.language ?? 'en',
  );
  late final _isbn = TextEditingController(text: widget.edition?.isbn ?? '');
  late final _releaseDate = TextEditingController(
    text: widget.edition?.releaseDate ?? '',
  );
  late final _description = TextEditingController(
    text: widget.edition?.description ?? '',
  );
  late String _format = widget.edition?.format ?? 'paperback';
  late String _publicationStatus =
      widget.edition?.publicationStatus ?? 'planned';
  Object? _error;
  bool _busy = false;
  bool _connectivityLost = false;

  @override
  void dispose() {
    _title.dispose();
    _language.dispose();
    _isbn.dispose();
    _releaseDate.dispose();
    _description.dispose();
    super.dispose();
  }

  String? _validateReleaseDate(String value) {
    return value.isEmpty || isValidReleaseDate(value)
        ? null
        : 'Enter a real date as YYYY, YYYY-MM, or YYYY-MM-DD.';
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final language = _language.text.trim();
    final isbn = _isbn.text.trim();
    final releaseDate = _releaseDate.text.trim();
    if (title.isEmpty || title.length > 500) {
      setState(() => _error = 'Enter a title between 1 and 500 characters.');
      return;
    }
    if (language.length < 2 || language.length > 35) {
      setState(() => _error = 'Enter a language code of 2-35 characters.');
      return;
    }
    final isbnError = validateCatalogIsbn(isbn);
    if (isbnError != null) {
      setState(() => _error = isbnError);
      return;
    }
    final dateError = _validateReleaseDate(releaseDate);
    if (dateError != null) {
      setState(() => _error = dateError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final existing = widget.edition;
      final saved = existing == null
          ? await widget.repository.createEdition(
              workId: widget.workId,
              title: title,
              format: _format,
              language: language,
              isbn: isbn.isEmpty ? null : isbn,
              publicationStatus: _publicationStatus,
              releaseDate: releaseDate.isEmpty ? null : releaseDate,
              description: _description.text,
            )
          : await widget.repository.updateMetadata(
              existing,
              title: title,
              format: _format,
              language: language,
              isbn: isbn.isEmpty ? null : isbn,
              publicationStatus: _publicationStatus,
              releaseDate: releaseDate.isEmpty ? null : releaseDate,
              description: _description.text,
              coverKey: existing.coverKey,
            );
      if (mounted) Navigator.pop(context, saved);
    } catch (error) {
      final connectivityLost = isTemporaryCatalogConnectivityFailure(error);
      if (connectivityLost) widget.onConnectivityFailure?.call(error);
      if (mounted) {
        setState(() {
          _busy = false;
          _connectivityLost = connectivityLost;
          _error = error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.edition == null ? 'Add edition' : 'Edit edition'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.edition == null
                    ? widget.workId == null
                          ? 'Creates a new work with its first edition.'
                          : 'Adds an edition to the selected work. ISBN, credits, categories and cover are not copied.'
                    : 'Saving against revision ${widget.edition!.revision}.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                enabled: !_busy && !_connectivityLost,
                maxLength: 500,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              DropdownButtonFormField<String>(
                initialValue: _format,
                decoration: const InputDecoration(labelText: 'Format'),
                items: const [
                  DropdownMenuItem(
                    value: 'paperback',
                    child: Text('Paperback'),
                  ),
                  DropdownMenuItem(value: 'hardback', child: Text('Hardback')),
                  DropdownMenuItem(value: 'ebook', child: Text('Ebook')),
                  DropdownMenuItem(value: 'audio', child: Text('Audio')),
                ],
                onChanged: _busy || _connectivityLost
                    ? null
                    : (value) {
                        if (value != null) setState(() => _format = value);
                      },
              ),
              TextField(
                controller: _language,
                enabled: !_busy && !_connectivityLost,
                decoration: const InputDecoration(
                  labelText: 'Language code',
                  hintText: 'en',
                ),
              ),
              TextField(
                controller: _isbn,
                enabled: !_busy && !_connectivityLost,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'ISBN-13',
                  hintText: 'Optional',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: _publicationStatus,
                decoration: const InputDecoration(
                  labelText: 'Publication status',
                ),
                items: const [
                  DropdownMenuItem(value: 'planned', child: Text('Planned')),
                  DropdownMenuItem(
                    value: 'announced',
                    child: Text('Announced'),
                  ),
                  DropdownMenuItem(value: 'released', child: Text('Released')),
                  DropdownMenuItem(
                    value: 'out_of_print',
                    child: Text('Out of print'),
                  ),
                ],
                onChanged: _busy || _connectivityLost
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _publicationStatus = value);
                        }
                      },
              ),
              TextField(
                controller: _releaseDate,
                enabled: !_busy && !_connectivityLost,
                decoration: const InputDecoration(
                  labelText: 'Release date',
                  hintText: 'YYYY, YYYY-MM, or YYYY-MM-DD',
                  helperText: 'Leave blank when the date is unknown.',
                ),
              ),
              TextField(
                controller: _description,
                enabled: !_busy && !_connectivityLost,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _connectivityLost
                        ? 'Connection lost. Your draft is still here, but editing is paused until you reconnect.'
                        : _error is PostgrestException &&
                              (_error as PostgrestException).code == 'PT409'
                        ? 'This edition changed elsewhere. Your draft is still here; copy it before canceling and reloading.'
                        : _error.toString(),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || _connectivityLost ? null : _save,
          child: Text(
            widget.edition == null ? 'Create edition' : 'Save edition',
          ),
        ),
      ],
    ),
  );
}
