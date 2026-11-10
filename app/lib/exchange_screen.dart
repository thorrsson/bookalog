import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'catalog.dart';
import 'design.dart';
import 'exchange.dart';
import 'onix.dart';

class CatalogExchangeScreen extends StatefulWidget {
  const CatalogExchangeScreen({
    super.key,
    required this.repository,
    required this.role,
    required this.onApplied,
    this.files,
  });
  final CatalogRepository repository;
  final CatalogRole role;
  final Future<void> Function() onApplied;
  final CatalogExchangeFiles? files;

  @override
  State<CatalogExchangeScreen> createState() => _CatalogExchangeScreenState();
}

class _CatalogExchangeScreenState extends State<CatalogExchangeScreen> {
  late final _files = widget.files ?? CatalogExchangeFiles();
  CatalogSourceFile? _source;
  List<List<String>>? _table;
  List<Map<String, String>>? _onixProvenance;
  Map<String, int?> _mapping = {};
  CatalogImportPlan? _plan;
  CatalogImportReport? _report;
  List<CatalogImportReport> _history = [];
  bool _busy = false;
  bool _submitted = false;
  bool _ignoreUnmapped = false;
  bool _exportAcknowledged = false;
  bool _onixAcknowledged = false;
  final _publisher = TextEditingController();
  String? _error;
  String? _message;
  String? _historyError;

  bool get _canImport => canEditCatalog(widget.role, connected: true);
  List<String> get _unmapped => [
    for (final entry in (_table?.first ?? <String>[]).indexed)
      if (!_mapping.values.contains(entry.$1)) entry.$2,
  ];

  @override
  void initState() {
    super.initState();
    if (_canImport) _loadHistory();
  }

  @override
  void dispose() {
    _publisher.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final records = await widget.repository.loadImportReports();
      final history = records.map(CatalogImportReport.fromRecord).toList();
      if (mounted) {
        setState(() {
          _history = history;
          _historyError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _historyError = 'Import history could not be loaded: $error',
        );
      }
    }
  }

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final source = await _files.pick();
      if (source == null) return;
      final document = await _files.read(source);
      if (!mounted) return;
      setState(() {
        _source = source;
        _table = document.table;
        _onixProvenance = document.onixProvenance;
        _mapping = inferColumnMapping(document.table.first);
        _ignoreUnmapped = false;
        _plan = null;
        _report = null;
        _submitted = false;
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'File could not be opened: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final snapshot = await widget.repository.loadCatalog().timeout(
        const Duration(seconds: 30),
      );
      if (!canEditCatalog(snapshot.role, connected: true)) {
        throw const CatalogAccessDenied(
          'An active editor or administrator membership is required.',
        );
      }
      final plan = await prepareCatalogImport(
        _source!,
        _table!,
        _mapping,
        snapshot,
        onixProvenance: _onixProvenance,
      );
      if (mounted) setState(() => _plan = plan);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Review could not be prepared: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final plan = _plan!;
    if (!plan.canApply) return;
    setState(() {
      _busy = true;
      _submitted = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await widget.repository.importMetadata(
        requestId: plan.requestId,
        sourceName: plan.sourceName,
        sourceSha256: plan.sourceSha256,
        rows: plan.rows.map((row) => row.toRequest()).toList(),
      );
      final report = CatalogImportReport.fromRecord(result);
      if (!report.confirms(plan)) {
        throw const FormatException(
          'The import report does not match this request.',
        );
      }
      if (!mounted) return;
      setState(() {
        _report = report;
        _submitted = false;
      });
    } on PostgrestException catch (error) {
      if (mounted) {
        setState(() {
          // A database error rolls back the entire RPC; a transport error does not prove rollback.
          _submitted = ![
            'PT409',
            '23505',
            '22023',
            '22P02',
            '42501',
            'P0002',
          ].contains(error.code);
          _error = _submitted
              ? 'The outcome is not confirmed. Retry this same import or consult history. ${error.message}'
              : 'No rows were applied by this request. ${error.message}';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              'The outcome is not confirmed. Retry this same import or consult history. $error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (_report != null && mounted) {
      try {
        await widget.onApplied();
      } catch (error) {
        if (mounted) {
          setState(
            () => _error =
                'Import completed, but the catalog could not be refreshed: $error',
          );
        }
      }
      if (mounted) await _loadHistory();
    }
  }

  Future<void> _export(CatalogExchangeFormat format) async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final snapshot = await widget.repository.loadCatalog().timeout(
        const Duration(seconds: 30),
      );
      final bytes = await _files.encode(
        snapshot.editions,
        format: format,
        publisher: _publisher.text,
      );
      if (!mounted) return;
      final saved = await _files.save(
        format == CatalogExchangeFormat.onix
            ? 'bookalog-onix-core.xml'
            : 'bookalog-core.${format.name}',
        bytes,
      );
      if (saved && mounted) {
        setState(
          () => _message = '${snapshot.editions.length} editions exported.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Export was not saved: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveReport(CatalogImportReport report) async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final saved = await _files.save(
        'bookalog-import-${report.requestId}.json',
        Uint8List.fromList(
          utf8.encode(
            const JsonEncoder.withIndent('  ').convert(report.record),
          ),
        ),
      );
      if (saved && mounted) setState(() => _message = 'Import report saved.');
    } catch (error) {
      if (mounted) setState(() => _error = 'Report was not saved: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _mappingFields() => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth < 600
          ? constraints.maxWidth
          : (constraints.maxWidth - 16) / 2;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final field in coreExchangeColumns)
            SizedBox(
              width: width,
              child: DropdownButtonFormField<int>(
                key: ValueKey('${_source!.name}-$field-${_mapping[field]}'),
                initialValue: _mapping[field] ?? -1,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText:
                      '$field${requiredImportColumns.contains(field) ? ' (required)' : ''}',
                ),
                items: [
                  const DropdownMenuItem(value: -1, child: Text('Not mapped')),
                  for (final entry in _table!.first.indexed)
                    DropdownMenuItem(
                      value: entry.$1,
                      child: Text(entry.$2, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (index) => setState(() {
                        _mapping[field] = index == -1 ? null : index;
                        _ignoreUnmapped = false;
                      }),
              ),
            ),
        ],
      );
    },
  );

  Widget _header() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Catalog file exchange',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      const Text(coreExchangeNotice),
      if (_busy) ...[
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
      ],
      if (_error != null) ...[
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: SelectableText(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
      if (_message != null) ...[
        const SizedBox(height: 16),
        Semantics(liveRegion: true, child: Text(_message!)),
      ],
      if (_report case final report?) ...[
        const SizedBox(height: 24),
        Text('Import complete', style: Theme.of(context).textTheme.titleLarge),
        SelectableText(report.summary),
        SelectableText('Request ${report.requestId}'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : () => _saveReport(report),
            icon: const Icon(Icons.download),
            label: const Text('Save import report'),
          ),
        ),
      ],
      if (_plan == null || _report != null) ...[
        if (_source == null || _report != null) ...[
          const SizedBox(height: 24),
          Text(
            'Export all editions',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text(
            'Refreshes the full catalog online; active browsing filters do not limit this export. '
            'CSV prefixes formula-like text with an apostrophe. Use XLSX for exact text round-trips.',
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _exportAcknowledged,
            onChanged: _busy
                ? null
                : (value) => setState(() => _exportAcknowledged = value!),
            title: const Text(
              'I understand these files are unencrypted and omit the metadata listed above.',
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy || !_exportAcknowledged
                    ? null
                    : () => _export(CatalogExchangeFormat.xlsx),
                child: const Text('Export XLSX'),
              ),
              OutlinedButton(
                onPressed: _busy || !_exportAcknowledged
                    ? null
                    : () => _export(CatalogExchangeFormat.csv),
                child: const Text('Export CSV'),
              ),
            ],
          ),
          const SizedBox(height: shelfFormSpacing),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('ONIX 3.0 core profile'),
            subtitle: const Text(
              'Provisional compatibility; review before sharing',
            ),
            children: [
              const Text(onixProfileNotice),
              const SizedBox(height: 12),
              TextField(
                controller: _publisher,
                enabled: !_busy,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Publisher name for this export',
                  helperText: 'Used as publisher and message sender. Never inferred from your account.',
                  helperMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _onixAcknowledged,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _onixAcknowledged = value!),
                title: const Text(
                  'I understand the ONIX profile limits and have confirmed the publisher.',
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed:
                      _busy ||
                          !_exportAcknowledged ||
                          !_onixAcknowledged ||
                          _publisher.text.trim().isEmpty
                      ? null
                      : () => _export(CatalogExchangeFormat.onix),
                  child: const Text('Export ONIX'),
                ),
              ),
            ],
          ),
          if (_canImport) ...[
            const SizedBox(height: 32),
            Text(
              'Import core metadata',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Select a UTF-8 CSV or text-only XLSX and map columns, or select ONIX 3.0 core-profile XML. '
              'Review every row before applying. Up to 5,000 rows, 32 spreadsheet columns and 8 MiB.',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.upload_file),
                label: const Text('Select import file'),
              ),
            ),
          ],
        ],
        if (_source != null && _report == null) ...[
          const SizedBox(height: 24),
          Text(
            '${_source!.name} - ${_table!.length - 1} rows',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : _pick,
              child: const Text('Replace import file'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Blank IDs create new editions; known IDs update them. Blank work IDs create separate new works. '
            'ISBN matches require an explicit edition ID; names are never merged. '
            'Unmapped optional fields preserve existing values; mapped blank cells clear optional values.',
          ),
          const SizedBox(height: 16),
          if (_onixProvenance != null) ...[
            const Text(onixProfileNotice),
            const SizedBox(height: 12),
            Text(
              'Fixed ONIX mapping. Sender: ${_onixProvenance!.first['sender']}. '
              'Sent: ${_onixProvenance!.first['sent_at']}. '
              'Record references and publisher names are kept in the import report, not used to merge records.',
            ),
          ] else
            _mappingFields(),
          if (_unmapped.isNotEmpty)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'Ignore these source columns: ${_unmapped.join(', ')}',
              ),
              subtitle: const Text('Their values will not enter the catalog.'),
              value: _ignoreUnmapped,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _ignoreUnmapped = value!),
            ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _busy || (_unmapped.isNotEmpty && !_ignoreUnmapped)
                  ? null
                  : _preview,
              child: const Text('Review changes'),
            ),
          ),
        ],
        if (_canImport && (_source == null || _report != null)) ...[
          const SizedBox(height: 32),
          Text('Recent imports', style: Theme.of(context).textTheme.titleLarge),
          const Text(
            'Latest 50 reports; editors see their own, administrators see all.',
          ),
          if (_historyError != null) ...[
            Text(_historyError!),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy ? null : _loadHistory,
                child: const Text('Retry history'),
              ),
            ),
          ] else if (_history.isEmpty)
            const Text('No completed imports to show.'),
          for (final report in _history)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(report.sourceName),
              subtitle: Text(
                '${report.summary}\n${report.record['occurred_at']}',
              ),
              trailing: IconButton(
                tooltip: 'Save report for ${report.sourceName}',
                onPressed: _busy ? null : () => _saveReport(report),
                icon: const Icon(Icons.download),
              ),
            ),
        ],
      ] else ...[
        const SizedBox(height: 24),
        Text(
          'Review ${_plan!.rows.length} ${_plan!.rows.length == 1 ? 'row' : 'rows'} from ${_plan!.sourceName}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(
          [
            for (final action in [
              'Create',
              'Update',
              'Unchanged',
              'Needs attention',
            ])
              '${_plan!.rows.where((row) => row.action == action).length} ${action.toLowerCase()}',
          ].join(' | '),
        ),
        const SizedBox(height: 8),
        const Text(
          'Expand a row to compare fields. All rows apply together or none do. '
          'Changed revisions, duplicate ISBNs or invalid data block the whole import.',
        ),
        if (!_plan!.canApply)
          Text(
            'Resolve rows marked Needs attention before applying.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_submitted)
          const Text(
            'This request has been submitted. Retry uses the same ID to avoid duplicate changes. '
            'Do not start a different import until its outcome is known.',
          ),
      ],
      const SizedBox(height: 16),
    ],
  );

  Widget _row(ImportPreviewRow row) => ExpansionTile(
    key: ValueKey(row.sourceRow),
    tilePadding: EdgeInsets.zero,
    title: Text('Row ${row.sourceRow}: ${row.metadata['title']}'),
    subtitle: Text([row.action, ...row.errors].join(' - ')),
    childrenPadding: const EdgeInsets.only(bottom: 16),
    children: [
      if (row.sourceContext case final source?)
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            'Source reference: ${source['record_reference']}\n'
            'Publisher: ${source['publisher']}',
          ),
        ),
      for (final field in coreMetadataColumns)
        if (row.existing == null ||
            row.existing!.record[field] != row.metadata[field])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                '$field: ${row.existing?.record[field] ?? '(not set)'}\n'
                'Proposed: ${row.metadata[field] ?? '(not set)'}',
              ),
            ),
          ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final reviewing = _plan != null && _report == null;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('File exchange')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: ListView.builder(
                key: ValueKey((_source, _plan?.requestId, _report?.requestId)),
                padding: const EdgeInsets.all(24),
                itemCount: reviewing ? _plan!.rows.length + 1 : 1,
                itemBuilder: (context, index) =>
                    index == 0 ? _header() : _row(_plan!.rows[index - 1]),
              ),
            ),
          ),
        ),
        bottomNavigationBar: reviewing
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: _busy || _submitted
                            ? null
                            : () => setState(() {
                                _plan = null;
                                _error = null;
                              }),
                        child: const Text('Back to mapping'),
                      ),
                      FilledButton(
                        onPressed: _busy || !_plan!.canApply ? null : _apply,
                        child: Text(
                          _submitted
                              ? 'Retry same import'
                              : 'Apply ${_plan!.rows.length} reviewed ${_plan!.rows.length == 1 ? 'row' : 'rows'}',
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
