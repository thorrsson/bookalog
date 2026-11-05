/*
THESIS: A publication register keeps works, editions, and their current access state legible without turning the catalog into an admin console.
OWN-WORLD: Native Material surfaces in pressroom white and deep ink, with registration blue for navigation and a restrained chartreuse mark for active selection.
STORY: Staff authenticate with Google, see whether their membership is approved, then search and edit the catalog according to their server-assigned role.
FIRST VIEWPORT: A compact app bar anchors search and connection state; the catalog occupies the working area, with an edition list and a contextual detail pane on wide windows.
FORM: Grounded direction 5, paired with grounded surface structure 3; operate mode; surface seed e14b098c and direction seed 7d400113.
*/

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_storage.dart';
import 'catalog.dart';
import 'relationships.dart';
import 'offline_cache.dart';
import 'exchange_screen.dart';

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

const _registrationBlue = Color(0xff315f9c);
const _pressroomChartreuse = Color(0xffc7d338);

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _registrationBlue,
          tertiary: _pressroomChartreuse,
          surface: const Color(0xfff7f8f5),
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _registrationBlue,
          tertiary: _pressroomChartreuse,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Bookalog')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 16),
              SelectableText(message),
            ],
          ),
        ),
      ),
    ),
  );
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
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bookalog',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  'Publishing catalog',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sign in with your Google Workspace account. Access is granted only to approved catalog members.',
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : _signIn,
                  icon: const Icon(Icons.open_in_browser),
                  label: Text(
                    _busy ? 'Opening Google sign-in…' : 'Continue with Google',
                  ),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
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
      onSelect: (edition) =>
          _openEdition(edition, inlineDetails: inlineDetails),
    ),
  };

  @override
  Widget build(BuildContext context) {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catalog'),
        actions: [
          if (snapshot != null && MediaQuery.sizeOf(context).width >= 900)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Row(
                  children: [
                    Icon(
                      _showingCachedSnapshot
                          ? Icons.cloud_off_outlined
                          : Icons.circle,
                      size: _showingCachedSnapshot ? 18 : 10,
                      color: _showingCachedSnapshot
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : _pressroomChartreuse,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${snapshot.role.label} · ${snapshot.editions.length} editions',
                    ),
                  ],
                ),
              ),
            ),
          if (canEdit)
            IconButton(
              tooltip: 'Add edition',
              onPressed: _busy ? null : _createEdition,
              icon: const Icon(Icons.add),
            ),
          IconButton(
            tooltip: 'Reload catalog',
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: 'Catalog tools',
            enabled: !_busy,
            onSelected: (action) async {
              switch (action) {
                case 'exchange':
                  await _exchange();
                case 'members':
                  await _manageMembers();
                case 'signout':
                  await _signOut();
              }
            },
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
              const PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1480),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _search,
                    onChanged: (query) => setState(() {
                      if (_selected != null &&
                          (!_selected!.matches(query) ||
                              !_filters.matches(_selected!))) {
                        _selected = null;
                      }
                    }),
                    decoration: InputDecoration(
                      labelText: 'Search title, ISBN, contributor, or category',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _search.clear();
                                setState(() {});
                              },
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _configureFilters,
                        icon: const Icon(Icons.tune),
                        label: const Text('Filters'),
                      ),
                      if (_filters.categoryQuery case final category?)
                        InputChip(
                          label: Text('Category: $category'),
                          onDeleted: () => setState(
                            () => _filters = _filters.without(
                              CatalogFilterField.category,
                            ),
                          ),
                        ),
                      if (_filters.contributorQuery case final contributor?)
                        InputChip(
                          label: Text('Contributor: $contributor'),
                          onDeleted: () => setState(
                            () => _filters = _filters.without(
                              CatalogFilterField.contributor,
                            ),
                          ),
                        ),
                      if (_filters.publicationStatus case final status?)
                        InputChip(
                          label: Text('Status: ${_statusLabel(status)}'),
                          onDeleted: () => setState(
                            () => _filters = _filters.without(
                              CatalogFilterField.status,
                            ),
                          ),
                        ),
                      if (_filters.releaseDatePrefix case final date?)
                        InputChip(
                          label: Text('Release: $date'),
                          onDeleted: () => setState(
                            () => _filters = _filters.without(
                              CatalogFilterField.releaseDate,
                            ),
                          ),
                        ),
                      if (_filters.workId != null)
                        InputChip(
                          label: const Text('Same work'),
                          tooltip: _filters.workId,
                          onDeleted: () => setState(
                            () => _filters = _filters.without(
                              CatalogFilterField.work,
                            ),
                          ),
                        ),
                      if (_filters.releaseFrom != null ||
                          _filters.releaseThrough != null)
                        InputChip(
                          label: Text(
                            '${_filters.releaseFrom ?? 'Any date'} to ${_filters.releaseThrough ?? 'Any date'}',
                          ),
                          tooltip:
                              'Includes partial dates that overlap this range.',
                          onDeleted: () => setState(
                            () => _filters = _filters.without(
                              CatalogFilterField.releaseRange,
                            ),
                          ),
                        ),
                      if (!_filters.isEmpty)
                        TextButton(
                          onPressed: () =>
                              setState(() => _filters = const CatalogFilters()),
                          child: const Text('Clear filters'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_busy) const LinearProgressIndicator(),
                  if (_offlineWarning != null && _error == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(_offlineWarning!),
                      ),
                    ),
                  if (_error != null)
                    _CatalogError(
                      error: _error!,
                      onRetry: _reload,
                      showingCachedSnapshot: _showingCachedSnapshot,
                      lease: _offlineEntry?.lease,
                    ),
                  if (!_busy &&
                      (_error == null || _showingCachedSnapshot) &&
                      snapshot != null) ...[
                    SegmentedButton<_CatalogView>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: _CatalogView.gallery,
                          icon: Icon(Icons.grid_view_outlined),
                          label: Text('Gallery'),
                        ),
                        ButtonSegment(
                          value: _CatalogView.table,
                          icon: Icon(Icons.table_rows_outlined),
                          label: Text('Table'),
                        ),
                        ButtonSegment(
                          value: _CatalogView.calendar,
                          icon: Icon(Icons.calendar_month_outlined),
                          label: Text('Release calendar'),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: (selection) =>
                          setState(() => _view = selection.first),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${records.length} matching ${records.length == 1 ? 'edition' : 'editions'}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        PopupMenuButton<CatalogSort>(
                          tooltip: 'Sort catalog',
                          initialValue: _sort,
                          onSelected: (field) => setState(() => _sort = field),
                          icon: const Icon(Icons.sort),
                          itemBuilder: (context) => [
                            for (final field in CatalogSort.values)
                              CheckedPopupMenuItem(
                                value: field,
                                checked: _sort == field,
                                child: Text(field.label),
                              ),
                          ],
                        ),
                        IconButton(
                          tooltip: _sortAscending
                              ? 'Sort descending'
                              : 'Sort ascending',
                          onPressed: () =>
                              setState(() => _sortAscending = !_sortAscending),
                          icon: Icon(
                            _sortAscending
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 760;
                          final showDetails = constraints.maxWidth >= 1000;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                flex: showDetails ? 3 : 1,
                                child: records.isEmpty
                                    ? _EmptyResults(
                                        query: _search.text,
                                        onClear: () {
                                          _search.clear();
                                          setState(() {});
                                        },
                                      )
                                    : _catalogView(
                                        records,
                                        compact,
                                        showDetails,
                                      ),
                              ),
                              if (showDetails) ...[
                                const VerticalDivider(width: 28),
                                SizedBox(
                                  width: 330,
                                  child: _selected == null
                                      ? const _DetailPrompt()
                                      : _EditionDetails(
                                          edition: _selected!,
                                          repository: _repository,
                                          online:
                                              !_showingCachedSnapshot &&
                                              _error == null,
                                          onEdit: canEdit
                                              ? () => _edit(_selected!)
                                              : null,
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
                                          onShowWork: () =>
                                              _filterToWork(_selected!),
                                          onChooseCover: canEdit
                                              ? () => _selectCover(_selected!)
                                              : null,
                                          onRemoveCover:
                                              canEdit &&
                                                  _selected!.coverKey != null
                                              ? () => _removeCover(_selected!)
                                              : null,
                                          coverBusy: _coverBusy,
                                        ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
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
  Widget build(BuildContext context) => ListView.builder(
    itemCount: records.length,
    itemBuilder: (context, index) {
      final edition = records[index];
      return ListTile(
        selected: edition.id == selectedId,
        title: Text(edition.title),
        subtitle: Text(
          '${edition.format} · ${edition.isbn ?? 'No ISBN'} · ${edition.releaseDate ?? 'Date unknown'}',
        ),
        onTap: () => onSelect(edition),
        trailing: canEdit
            ? const Icon(Icons.edit_outlined)
            : const Icon(Icons.chevron_right),
      );
    },
  );
}

class _EditionDataSource extends DataTableSource {
  _EditionDataSource({
    required this.records,
    required this.selectedId,
    required this.onSelect,
  });

  final List<CatalogEdition> records;
  final String? selectedId;
  final ValueChanged<CatalogEdition> onSelect;

  @override
  DataRow? getRow(int index) {
    if (index >= records.length) return null;
    final edition = records[index];
    return DataRow.byIndex(
      index: index,
      selected: edition.id == selectedId,
      onSelectChanged: (_) => onSelect(edition),
      cells: [
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Text(edition.title, overflow: TextOverflow.ellipsis),
          ),
        ),
        DataCell(Text(edition.format)),
        DataCell(Text(edition.isbn ?? 'No ISBN')),
        DataCell(Text(edition.releaseDate ?? 'Date unknown')),
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
  Widget build(BuildContext context) => Scrollbar(
    child: SingleChildScrollView(
      child: PaginatedDataTable(
        showCheckboxColumn: false,
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
        ),
      ),
    ),
  );
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
  Widget build(BuildContext context) => GridView.builder(
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 250,
      mainAxisExtent: 300,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    ),
    itemCount: records.length,
    itemBuilder: (context, index) {
      final edition = records[index];
      return Card(
        clipBehavior: Clip.antiAlias,
        color: edition.id == selectedId
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
        child: InkWell(
          onTap: () => onSelect(edition),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _CoverPreview(
                  edition: edition,
                  repository: repository,
                  online: online,
                  fit: BoxFit.contain,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      edition.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${edition.format} · ${edition.releaseDate ?? 'Date unknown'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class ReleaseCalendarView extends StatelessWidget {
  const ReleaseCalendarView({
    super.key,
    required this.records,
    required this.selectedId,
    required this.onSelect,
  });

  final List<CatalogEdition> records;
  final String? selectedId;
  final ValueChanged<CatalogEdition> onSelect;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<CatalogEdition>>{};
    for (final edition in records) {
      grouped.putIfAbsent(edition.releaseDate ?? '', () => []).add(edition);
    }
    final dates = grouped.keys.toList()
      ..sort((left, right) {
        if (left.isEmpty) return 1;
        if (right.isEmpty) return -1;
        return left.compareTo(right);
      });
    final entries = <({String? heading, CatalogEdition? edition})>[];
    for (final date in dates) {
      entries.add((heading: _dateLabel(date), edition: null));
      for (final edition in grouped[date]!) {
        entries.add((heading: null, edition: edition));
      }
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.heading case final heading?) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              heading,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          );
        }
        final edition = entry.edition!;
        return ListTile(
          selected: edition.id == selectedId,
          title: Text(edition.title),
          subtitle: Text(
            '${edition.format} · ${edition.publicationStatus} · ${edition.isbn ?? 'No ISBN'}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => onSelect(edition),
        );
      },
    );
  }

  String _dateLabel(String value) => switch (value.length) {
    4 => '$value · year only',
    7 => '$value · month only',
    10 => value,
    _ => 'Date not set',
  };
}

class _DetailPrompt extends StatelessWidget {
  const _DetailPrompt();

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      'Select an edition to review its details.',
      style: Theme.of(context).textTheme.bodyLarge,
      textAlign: TextAlign.center,
    ),
  );
}

class _EditionDetails extends StatelessWidget {
  const _EditionDetails({
    required this.edition,
    required this.repository,
    required this.online,
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
    final credits = edition.credits;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 0.72,
            child: _CoverPreview(
              edition: edition,
              repository: repository,
              online: online,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 18),
          _DetailLine(label: 'Format', value: edition.format),
          _DetailLine(label: 'Language', value: edition.language),
          _DetailLine(
            label: 'Publication status',
            value: edition.publicationStatus,
          ),
          _DetailLine(label: 'ISBN-13', value: edition.isbn ?? 'Not assigned'),
          _DetailLine(
            label: 'Release date',
            value: edition.releaseDate ?? 'Not set',
          ),
          _DetailLine(label: 'Work ID', value: edition.workId),
          TextButton(
            onPressed: onShowWork,
            child: const Text('Show all editions of this work'),
          ),
          if (credits.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Contributors', style: Theme.of(context).textTheme.titleSmall),
            Wrap(
              spacing: 8,
              runSpacing: 4,
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
            const SizedBox(height: 12),
            Text('Categories', style: Theme.of(context).textTheme.titleSmall),
            Wrap(
              spacing: 8,
              runSpacing: 4,
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
          if (edition.description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Description', style: Theme.of(context).textTheme.titleSmall),
            Text(edition.description),
          ],
          if (onEdit != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onEdit,
              child: const Text('Edit edition'),
            ),
          ],
          if (onEditRelationships != null)
            TextButton(
              onPressed: coverBusy ? null : onEditRelationships,
              child: const Text('Edit contributors and categories'),
            ),
          if (onAddEdition != null)
            TextButton.icon(
              onPressed: coverBusy ? null : onAddEdition,
              icon: const Icon(Icons.library_books_outlined),
              label: const Text('Add another edition'),
            ),
          if (onChooseCover != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: coverBusy ? null : onChooseCover,
              icon: coverBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined),
              label: Text(
                coverBusy
                    ? 'Uploading cover…'
                    : edition.coverKey == null
                    ? 'Add cover'
                    : 'Replace cover',
              ),
            ),
          ],
          if (onRemoveCover != null) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: coverBusy ? null : onRemoveCover,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove cover'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CoverPreview extends StatelessWidget {
  const _CoverPreview({
    required this.edition,
    required this.repository,
    required this.fit,
    required this.online,
  });

  final CatalogEdition edition;
  final CatalogRepository repository;
  final BoxFit fit;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final key = edition.coverKey;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: key == null
          ? _coverStatus(context, 'No cover')
          : !online
          ? _coverStatus(context, 'Cover not cached')
          : FutureBuilder<String>(
              future: repository.signedCoverUrl(key),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return _coverStatus(
                    context,
                    snapshot.hasError ? 'Cover unavailable' : 'Loading cover…',
                  );
                }
                return Image.network(
                  snapshot.data!,
                  fit: fit,
                  semanticLabel: 'Cover of ${edition.title}',
                  errorBuilder: (context, error, stackTrace) =>
                      _coverStatus(context, 'Cover unavailable'),
                );
              },
            ),
    );
  }

  Widget _coverStatus(BuildContext context, String label) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.menu_book_outlined,
          size: 38,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 8),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    ),
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        SelectableText(value),
      ],
    ),
  );
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

  @override
  Widget build(BuildContext context) {
    if (showingCachedSnapshot) {
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.cloud_off_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Showing the verified saved catalog read-only. Reconnect and reload to edit.'
                      '${lease == null ? '' : '\nVerified ${lease!.issuedAt.toLocal()}. Offline access ends ${lease!.expiresAt.toLocal()}.'}',
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Expanded(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error is OfflineAccessUnavailable
                    ? 'Offline access unavailable'
                    : error is CatalogAccessDenied
                    ? 'Catalog access is not approved'
                    : 'Catalog could not be loaded',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(error.toString(), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(query.isEmpty ? 'No editions in this catalog.' : 'No matches.'),
        if (query.isNotEmpty)
          TextButton(onPressed: onClear, child: const Text('Clear search')),
      ],
    ),
  );
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
