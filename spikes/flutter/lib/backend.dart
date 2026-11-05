import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;

import 'catalog.dart';

enum Provider { postgrest, gateway }

class BackendFailure implements Exception {
  final int status;
  final String message;
  BackendFailure(this.status, this.message);
  @override
  String toString() => message;
}

class Backend {
  final Provider provider;
  final String accessToken;
  final String? apiKey;
  final Uri base;
  final http.Client _client;
  String? role;

  Backend({
    required this.provider,
    required String baseUrl,
    required this.accessToken,
    this.apiKey,
    http.Client? client,
  }) : base = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/'),
       _client = client ?? http.Client() {
    final local = ['127.0.0.1', 'localhost', '::1'].contains(base.host);
    if (!(base.scheme == 'https' || base.scheme == 'http' && local) ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        base.host.isEmpty) {
      throw BackendFailure(
        0,
        'Use HTTPS, or HTTP on localhost, without embedded credentials or query parameters.',
      );
    }
    if (accessToken.trim().isEmpty) {
      throw BackendFailure(401, 'An access token is required.');
    }
  }

  void close() => _client.close();

  Future<dynamic> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final request = http.Request(method, base.resolve(path))
      ..followRedirects = false
      ..headers['authorization'] = 'Bearer $accessToken';
    if (apiKey != null && apiKey!.isNotEmpty) {
      request.headers['apikey'] = apiKey!;
    }
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      return await (() async {
        final response = await _client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.listen(null).cancel();
          throw BackendFailure(response.statusCode, switch (response
              .statusCode) {
            401 => 'Authentication failed. Obtain a fresh test access token.',
            403 =>
              'The account or role is not permitted to perform this operation.',
            409 => 'This edition changed. Reload and compare your draft.',
            _ => 'The backend rejected the operation.',
          });
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 16 * 1024 * 1024) {
            throw BackendFailure(
              0,
              "The response exceeds the comparison's 16 MiB limit.",
            );
          }
          bytes.addAll(chunk);
        }
        return jsonDecode(utf8.decode(bytes));
      })().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      _client.close();
      throw BackendFailure(
        0,
        'The backend request timed out. Reconnect before retrying.',
      );
    } on http.ClientException {
      throw BackendFailure(
        0,
        'The backend could not be reached. Check the URL and connection.',
      );
    } on FormatException {
      throw BackendFailure(0, 'The backend returned invalid JSON.');
    }
  }

  Future<String> _membership() async {
    final result = await _request(
      'GET',
      provider == Provider.postgrest
          ? 'rpc/current_catalog_role'
          : 'membership',
    );
    final value = provider == Provider.postgrest
        ? result
        : result is Map
        ? result['role']
        : null;
    if (!['viewer', 'editor', 'administrator'].contains(value)) {
      throw BackendFailure(403, 'An active catalog membership is required.');
    }
    return value as String;
  }

  Future<List<Edition>> load() async {
    final elapsed = Stopwatch()..start();
    await _membership();
    final records = <dynamic>[];
    final pageIds = <String>{};
    if (provider == Provider.gateway) {
      final result = await _request('GET', 'editions');
      if (result is! Map || result['editions'] is! List) {
        throw BackendFailure(0, 'Missing editions array.');
      }
      records.addAll(result['editions'] as List);
    } else {
      while (true) {
        if (elapsed.elapsed > const Duration(minutes: 1)) {
          throw BackendFailure(
            0,
            'Catalog pagination took too long. Reconnect and retry.',
          );
        }
        final page = await _request(
          'GET',
          'editions?select=record&order=id&offset=${records.length}&limit=500',
        );
        if (page is! List) throw BackendFailure(0, 'Invalid catalog page.');
        if (page.isEmpty) break;
        for (final row in page) {
          if (row is! Map || row['record'] is! Map<String, dynamic>) {
            throw BackendFailure(0, 'Missing edition record.');
          }
          final id = row['record']['id'];
          if (id is! String || !pageIds.add(id)) {
            throw BackendFailure(
              0,
              'Invalid or duplicate records across pages. Reload the catalog.',
            );
          }
          records.add(row['record']);
        }
        if (records.length > 10000) {
          throw BackendFailure(
            0,
            'Catalog exceeds the comparison record limit.',
          );
        }
      }
    }
    if (records.length > 10000) {
      throw BackendFailure(0, 'Catalog exceeds the comparison record limit.');
    }
    final ids = <String>{};
    final editions = records.map((row) {
      if (row is! Map<String, dynamic>) {
        throw BackendFailure(0, 'Invalid edition object.');
      }
      final edition = Edition(row);
      if (!ids.add(edition.id)) {
        throw BackendFailure(
          0,
          'Duplicate records across pages. Reload the catalog.',
        );
      }
      return edition;
    }).toList();
    role = await _membership();
    return editions;
  }

  Future<Edition> saveTitle(Edition edition, String title) async {
    final revision = edition.record['revision'] as int;
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(edition.id)) {
      throw BackendFailure(400, 'Invalid edition identifier.');
    }
    final result = provider == Provider.postgrest
        ? await _request('POST', 'rpc/update_edition_title', {
            'edition_id': edition.id,
            'expected_revision': revision,
            'new_title': title,
          })
        : await _request('PATCH', 'editions/${edition.id}', {
            'expected_revision': revision,
            'title': title,
          });
    final row = provider == Provider.postgrest
        ? result
        : result is Map
        ? result['edition']
        : null;
    if (row is! Map<String, dynamic> ||
        row['id'] != edition.id ||
        row['revision'] != revision + 1) {
      throw BackendFailure(
        0,
        'The save response could not be confirmed. Reload before retrying.',
      );
    }
    return Edition(row);
  }
}
