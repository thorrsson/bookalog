import 'package:bookalog_catalog/appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses stored choices and falls back to system', () {
    expect(AppearanceController.parse('dark'), ThemeMode.dark);
    expect(AppearanceController.parse('light'), ThemeMode.light);
    expect(AppearanceController.parse('system'), ThemeMode.system);
    expect(AppearanceController.parse(null), ThemeMode.system);
    expect(AppearanceController.parse('sepia'), ThemeMode.system);
  });

  test('select persists changes once', () async {
    final saved = <ThemeMode>[];
    final controller = AppearanceController(
      ThemeMode.system,
      (mode) async => saved.add(mode),
    );
    await controller.select(ThemeMode.dark);
    await controller.select(ThemeMode.dark);
    expect(controller.value, ThemeMode.dark);
    expect(saved, [ThemeMode.dark]);
  });

  test('storage failures keep the choice for this session', () async {
    final controller = AppearanceController(
      ThemeMode.system,
      (_) async => throw StateError('disk full'),
    );
    await controller.select(ThemeMode.light);
    expect(controller.value, ThemeMode.light);
  });
}
