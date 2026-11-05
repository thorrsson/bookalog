import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'catalog.dart';
import 'cache.dart';
import 'backend.dart';
import 'backend_controls.dart';
import 'exchange.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ComparisonApp());
}

class ComparisonApp extends StatelessWidget {
  const ComparisonApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Bookalog Flutter comparison',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff164f72)),
      useMaterial3: true,
    ),
    home: const CatalogScreen(),
  );
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  List<Edition> _editions = [];
  String _query = '';
  String _message = 'Loading synthetic records...';
  bool _busy = false;
  bool _error = false;
  bool _catalogLoaded = false;
  String? _source;
  Backend? _backend;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _backend?.close();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<String> _loadBackend() async {
    _editions = [];
    _catalogLoaded = false;
    try {
      _editions = await _backend!.load();
      _catalogLoaded = true;
      return 'Connected as ${_backend!.role}. Online-only; these records are not cached.';
    } catch (_) {
      _backend?.close();
      _backend = null;
      rethrow;
    }
  }

  Future<void> _connect() async {
    final backend = await showDialog<Backend>(
      context: context,
      builder: (context) => const ConnectionDialog(),
    );
    if (backend == null) return;
    if (!mounted) {
      backend.close();
      return;
    }
    _backend = backend;
    await _run(_loadBackend);
  }

  Future<String> _restoreFixture() async {
    _editions = [];
    _catalogLoaded = false;
    _backend?.close();
    _backend = null;
    _source ??= await rootBundle.loadString('assets/catalog.json');
    _editions = await compute(decodeCatalog, _source!);
    _catalogLoaded = true;
    return 'Synthetic catalog restored; test token discarded.';
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
    _searchFocus.requestFocus();
  }

  Future<void> _details(Edition edition) async {
    if (_backend != null && _backend!.role != 'viewer') {
      final saved = await showDialog<Edition>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            EditionEditor(backend: _backend!, edition: edition),
      );
      if (saved != null && mounted) {
        setState(() {
          _editions = _editions
              .map((row) => row.id == saved.id ? saved : row)
              .toList();
          _message = 'Title saved at revision ${saved.record['revision']}.';
          _error = false;
        });
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(edition.title),
        content: SingleChildScrollView(
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(edition.record),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _run(() async {
      _source = await rootBundle.loadString('assets/catalog.json');
      _editions = await compute(decodeCatalog, _source!);
      _catalogLoaded = true;
      return '${_editions.length} synthetic editions loaded. No backend connected.';
    });
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _error = false;
    });
    try {
      final message = await action();
      if (mounted) setState(() => _message = message);
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error.toString();
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _preview() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Comparison exchange',
          extensions: ['csv', 'xlsx', 'xml'],
          uniformTypeIdentifiers: [
            'public.comma-separated-values-text',
            'org.openxmlformats.spreadsheetml.sheet',
            'public.xml',
          ],
        ),
      ],
    );
    if (file == null) return 'File selection canceled.';
    if (await file.length() > 8 * 1024 * 1024) {
      throw const FormatException('The spike accepts files up to 8 MiB.');
    }
    final extension = file.name.split('.').last.toLowerCase();
    final bytes = await file.readAsBytes();
    final count = switch (extension) {
      'csv' => await compute(previewCsv, utf8.decode(bytes)),
      'xlsx' => await compute(previewXlsx, bytes),
      'xml' => await compute(previewOnix, bytes),
      _ => throw const FormatException(
        'Choose a CSV, XLSX, or illustrative ONIX XML file.',
      ),
    };
    return '$count $extension records previewed. No catalog changes applied; comparison profile only.';
  }

  Future<String> _export([String format = 'csv']) async {
    final bytes = switch (format) {
      'xlsx' => await compute(xlsxProjection, _editions),
      'xml' => await compute(onixProjection, _editions),
      'csv' => Uint8List.fromList(
        utf8.encode(await compute(csvProjection, _editions)),
      ),
      _ => throw const FormatException('Unsupported comparison export format.'),
    };
    final mime = switch (format) {
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'xml' => 'application/xml',
      _ => 'text/csv',
    };
    final name = 'synthetic-catalog.$format';
    if (Platform.isAndroid || Platform.isIOS) {
      if (!mounted) return 'Export canceled because the view was closed.';
      final box = context.findRenderObject()! as RenderBox;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: mime, name: name)],
          fileNameOverrides: [name],
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      return 'Export share sheet: ${result.status.name}.';
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return 'Export canceled.';
    await XFile.fromData(bytes, mimeType: mime).saveTo(location.path);
    return 'Exported the synthetic $format projection. Not a complete catalog interchange or recipient-certified ONIX feed.';
  }

  Widget _comparisonTools() => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 16),
    title: const Text('File exchange and test cache'),
    children: [
      if (_backend != null)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Disconnect to use these tools with the synthetic fixture. Connected records are never cached or exported here.',
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'File exchange',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      const Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'CSV/XLSX: seven columns. Illustrative ONIX: identifiers, titles, and formats only. Preview does not import records.',
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy || _backend != null
                  ? null
                  : () => _run(_preview),
              child: const Text('Preview file'),
            ),
            for (final format in ['csv', 'xlsx', 'xml'])
              OutlinedButton(
                onPressed: _busy || _backend != null || _editions.isEmpty
                    ? null
                    : () => _run(() => _export(format)),
                child: Text(
                  format == 'xml'
                      ? 'Export illustrative ONIX'
                      : 'Export ${format.toUpperCase()}',
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Synthetic cache',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      const Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Encrypted fixture only. Its local expiry does not prove offline membership.',
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy || _backend != null || _source == null
                  ? null
                  : () => _run(() async {
                      await saveSyntheticCache(_source!);
                      return 'Encrypted synthetic snapshot saved using an OS-protected key.';
                    }),
              child: const Text('Save test cache'),
            ),
            OutlinedButton(
              onPressed: _busy || _backend != null
                  ? null
                  : () => _run(() async {
                      _editions = await compute(
                        decodeCatalog,
                        await readSyntheticCache(),
                      );
                      _catalogLoaded = true;
                      return 'Decrypted test cache. Its local timestamp is not a server membership verification.';
                    }),
              child: const Text('Read test cache'),
            ),
            OutlinedButton(
              onPressed: _busy || _backend != null
                  ? null
                  : () => _run(() async {
                      await clearSyntheticCache();
                      return 'Synthetic cache and its key cleared.';
                    }),
              child: const Text('Clear test cache'),
            ),
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final rows = _editions.where((edition) => edition.matches(_query)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Bookalog / Flutter comparison')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      !_catalogLoaded && !_busy
                          ? 'Catalog unavailable'
                          : _backend == null
                          ? 'Synthetic catalog'
                          : 'Connected comparison catalog',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Feasibility tools, not the production interface. No sign-in or verified offline membership lease.',
                    ),
                    if (_backend != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${_backend!.provider == Provider.postgrest ? 'Supabase / PostgREST' : 'Google Cloud gateway'}'
                          ' | ${_backend!.role} | Online-only. ${_backend!.role == 'viewer' ? 'Read-only access.' : 'Select a title to edit.'}',
                        ),
                      ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _search,
                      focusNode: _searchFocus,
                      decoration: InputDecoration(
                        labelText:
                            'Search title, ISBN, contributor, or category',
                        border: OutlineInputBorder(),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: _clearSearch,
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_backend == null)
                          OutlinedButton(
                            onPressed: _busy ? null : _connect,
                            child: const Text('Test backend connection'),
                          )
                        else ...[
                          OutlinedButton(
                            onPressed: _busy ? null : () => _run(_loadBackend),
                            child: const Text('Reload backend'),
                          ),
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _run(_restoreFixture),
                            child: const Text('Disconnect and restore fixture'),
                          ),
                        ],
                      ],
                    ),
                    _comparisonTools(),
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _message,
                        style: TextStyle(
                          color: _error
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                    ),
                    if (_busy) const LinearProgressIndicator(),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '${rows.length} matching ${rows.length == 1 ? 'edition' : 'editions'}',
                      ),
                    ),
                  ],
                ),
              ),
              if (rows.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _busy
                              ? 'Loading catalog...'
                              : !_catalogLoaded
                              ? 'No catalog loaded. Resolve the error above or restore the fixture.'
                              : _query.isNotEmpty
                              ? 'No matching editions. Try a title, ISBN, contributor, or category.'
                              : 'No editions in this catalog. Reload the backend or restore the fixture.',
                        ),
                        if (!_busy && !_catalogLoaded)
                          TextButton(
                            onPressed: () => _run(_restoreFixture),
                            child: const Text('Restore synthetic catalog'),
                          ),
                        if (!_busy && _catalogLoaded && _query.isNotEmpty)
                          TextButton(
                            onPressed: _clearSearch,
                            child: const Text('Clear search'),
                          ),
                      ],
                    ),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final edition = rows[index];
                    return ListTile(
                      title: Text(edition.title),
                      subtitle: Text(
                        '${edition.format} | ${edition.isbn ?? 'No ISBN'} | ${edition.releaseDate ?? 'Date unknown'}',
                      ),
                      onTap: _busy ? null : () => _details(edition),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
