import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'catalog.dart';
import 'design.dart';

class CatalogRelationshipsDialog extends StatefulWidget {
  const CatalogRelationshipsDialog({
    super.key,
    required this.repository,
    required this.edition,
    this.onConnectivityFailure,
  });

  final CatalogRepository repository;
  final CatalogEdition edition;
  final ValueChanged<Object>? onConnectivityFailure;

  @override
  State<CatalogRelationshipsDialog> createState() =>
      _CatalogRelationshipsDialogState();
}

class _CatalogRelationshipsDialogState
    extends State<CatalogRelationshipsDialog> {
  late final _credits = [...widget.edition.credits];
  late final _categories = [...widget.edition.categoryReferences];
  final _role = TextEditingController(text: 'author');
  CatalogRelationOptions? _options;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _connectionLost = false;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _role.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final options = await widget.repository.loadRelationOptions();
      if (mounted) setState(() => _options = options);
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not load choices: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _addContributor(CatalogReference contributor) {
    final role = _role.text.trim();
    if (role.isEmpty || role.length > 80) {
      setState(() => _error = 'Enter a credit role of 1-80 characters.');
      return false;
    }
    if (_credits.length >= 100) {
      setState(() => _error = 'An edition can have at most 100 credits.');
      return false;
    }
    if (contributor.id != null &&
        _credits.any(
          (credit) =>
              credit.contributor.id == contributor.id && credit.role == role,
        )) {
      setState(() => _error = 'That contributor already has this credit role.');
      return false;
    }
    setState(() {
      _credits.add(CatalogCredit(contributor: contributor, role: role));
      _error = null;
    });
    return true;
  }

  bool _addCategory(CatalogReference category) {
    if (_categories.length >= 100) {
      setState(() => _error = 'An edition can have at most 100 categories.');
      return false;
    }
    if (_categories.any(
      (existing) =>
          existing.name == category.name ||
          (category.id != null && existing.id == category.id),
    )) {
      setState(() => _error = 'This edition already has that category.');
      return false;
    }
    setState(() {
      _categories.add(category);
      _error = null;
    });
    return true;
  }

  void _moveCredit(int from, int to) => setState(() {
    final credit = _credits.removeAt(from);
    _credits.insert(to, credit);
  });

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.repository.updateRelations(
        widget.edition,
        credits: _credits,
        categories: _categories,
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (error) {
      final connectionLost = isTemporaryCatalogConnectivityFailure(error);
      if (connectionLost) widget.onConnectivityFailure?.call(error);
      if (mounted) {
        setState(() {
          _connectionLost = connectionLost;
          _error = connectionLost
              ? 'Connection lost. Your draft is still here. Close and reload the catalog before trying again.'
              : error is PostgrestException && error.code == 'PT409'
              ? 'This edition changed elsewhere. Your draft is still here; compare it before closing and reloading.'
              : 'Relationships were not saved: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = !_saving && !_connectionLost;
    final options = _options;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: ShelfDialogTitle(
          title: 'Contributors and categories',
          error: _error,
        ),
        content: SizedBox(
          width: 640,
          child: ShelfFormScroll(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.edition.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Changes apply only to this edition. Other editions and shared names are not changed.',
                ),
                if (_loading || _saving) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (options != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Contributor credits',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Text(
                    'Select an existing identity, or explicitly create a new one. Matching names are not merged.',
                  ),
                  for (final (index, credit) in _credits.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            '${index + 1}. ${credit.contributor.name} - ${credit.role}',
                          ),
                          Wrap(
                            children: [
                              IconButton(
                                tooltip: 'Move ${credit.contributor.name} up',
                                onPressed: editable && index > 0
                                    ? () => _moveCredit(index, index - 1)
                                    : null,
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: 'Move ${credit.contributor.name} down',
                                onPressed:
                                    editable && index < _credits.length - 1
                                    ? () => _moveCredit(index, index + 1)
                                    : null,
                                icon: const Icon(Icons.arrow_downward),
                              ),
                              TextButton.icon(
                                onPressed: editable
                                    ? () => setState(
                                        () => _credits.removeAt(index),
                                      )
                                    : null,
                                icon: const Icon(Icons.close),
                                label: const Text('Remove credit'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (_credits.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No contributor credits assigned.'),
                    ),
                  TextField(
                    controller: _role,
                    enabled: editable,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Role for the next credit',
                      hintText: 'author, illustrator, translator',
                    ),
                  ),
                  const SizedBox(height: shelfFormSpacing),
                  _ReferencePicker(
                    label: 'Contributor',
                    options: options.contributors,
                    maxLength: 300,
                    enabled: editable,
                    onAdd: _addContributor,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Categories',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final category in _categories)
                        InputChip(
                          label: Text(category.name),
                          onDeleted: editable
                              ? () =>
                                    setState(() => _categories.remove(category))
                              : null,
                        ),
                    ],
                  ),
                  if (_categories.isEmpty)
                    const Text('No categories assigned.'),
                  const SizedBox(height: shelfFormSpacing),
                  _ReferencePicker(
                    label: 'Category',
                    options: options.categories,
                    maxLength: 160,
                    enabled: editable,
                    onAdd: _addCategory,
                  ),
                ],
                if (_error != null && options == null && !_loading) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _loadOptions,
                    child: const Text('Retry loading choices'),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: editable && !_loading && options != null ? _save : null,
            child: const Text('Save relationships'),
          ),
        ],
      ),
    );
  }
}

class _ReferencePicker extends StatefulWidget {
  const _ReferencePicker({
    required this.label,
    required this.options,
    required this.maxLength,
    required this.enabled,
    required this.onAdd,
  });

  final String label;
  final List<CatalogReference> options;
  final int maxLength;
  final bool enabled;
  final bool Function(CatalogReference) onAdd;

  @override
  State<_ReferencePicker> createState() => _ReferencePickerState();
}

class _ReferencePickerState extends State<_ReferencePicker> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  CatalogReference? _selected;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final existing = _selected?.name == _controller.text ? _selected : null;
      final valid =
          _controller.text.trim().isNotEmpty &&
          _controller.text.trim().length <= widget.maxLength;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RawAutocomplete<CatalogReference>(
            textEditingController: _controller,
            focusNode: _focus,
            displayStringForOption: (reference) => reference.name,
            onSelected: (reference) => setState(() => _selected = reference),
            optionsBuilder: (value) => widget.options
                .where(
                  (reference) => reference.name.toLowerCase().contains(
                    value.text.toLowerCase(),
                  ),
                )
                .take(20),
            fieldViewBuilder: (context, controller, focus, submit) => TextField(
              controller: controller,
              focusNode: focus,
              enabled: widget.enabled,
              maxLength: widget.maxLength,
              onChanged: (_) => setState(() => _selected = null),
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: '${widget.label} name',
                helperText: 'Search existing entries or type a new name.',
              ),
            ),
            optionsViewBuilder: (context, select, options) => Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: SizedBox(
                  width: constraints.maxWidth,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      children: [
                        for (final reference in options)
                          ListTile(
                            title: Text(reference.name),
                            subtitle: Text(reference.id!),
                            onTap: () => select(reference),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: widget.enabled && valid
                ? () {
                    final reference =
                        existing ??
                        CatalogReference(
                          id: null,
                          name: _controller.text.trim(),
                        );
                    if (widget.onAdd(reference)) {
                      _focus.unfocus();
                      _controller.clear();
                      setState(() => _selected = null);
                    }
                  }
                : null,
            icon: const Icon(Icons.add),
            label: Text(
              existing == null
                  ? 'Create new ${widget.label.toLowerCase()}'
                  : 'Use selected ${widget.label.toLowerCase()}',
            ),
          ),
        ],
      );
    },
  );
}
