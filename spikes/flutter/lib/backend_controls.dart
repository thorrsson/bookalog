import 'package:flutter/material.dart';

import 'backend.dart';
import 'catalog.dart';

class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({super.key});
  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _key = TextEditingController();
  Provider _provider = Provider.postgrest;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _key.dispose();
    super.dispose();
  }

  void _connect() {
    try {
      final backend = Backend(
        provider: _provider,
        baseUrl: _url.text,
        accessToken: _token.text,
        apiKey: _key.text.isEmpty ? null : _key.text,
      );
      Navigator.pop(context, backend);
    } on BackendFailure catch (error) {
      setState(() => _error = error.message);
    } on FormatException {
      setState(() => _error = 'Enter a valid API base URL.');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Test backend connection'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Disposable comparison environments only. This is not Google sign-in. Tokens stay in memory until disconnect or app exit.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<Provider>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Backend'),
              items: const [
                DropdownMenuItem(
                  value: Provider.postgrest,
                  child: Text('Supabase / PostgREST'),
                ),
                DropdownMenuItem(
                  value: Provider.gateway,
                  child: Text('Google Cloud gateway'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _provider = value);
              },
            ),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'API base URL',
                helperText: 'Include /rest/v1 for hosted Supabase.',
              ),
            ),
            TextField(
              controller: _token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Test access token'),
            ),
            TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Supabase publishable key',
                helperText: 'Not needed for local PostgREST.',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _connect, child: const Text('Connect and load')),
    ],
  );
}

class EditionEditor extends StatefulWidget {
  final Backend backend;
  final Edition edition;
  const EditionEditor({
    super.key,
    required this.backend,
    required this.edition,
  });
  @override
  State<EditionEditor> createState() => _EditionEditorState();
}

class _EditionEditorState extends State<EditionEditor> {
  late final _title = TextEditingController(text: widget.edition.title);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Enter a title before saving.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.backend.saveTitle(widget.edition, _title.text);
      if (mounted) Navigator.pop(context, saved);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Edit title'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Saving against revision ${widget.edition.record['revision']}. On conflict, copy your draft before canceling and reloading.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                enabled: !_busy,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
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
          child: const Text('Cancel edit'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save title'),
        ),
      ],
    ),
  );
}
