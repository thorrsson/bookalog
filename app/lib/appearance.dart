import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The person's light/dark choice for this device; `system` follows the OS.
class AppearanceController extends ValueNotifier<ThemeMode> {
  AppearanceController([
    super.value = ThemeMode.system,
    Future<void> Function(ThemeMode mode)? save,
  ]) : _save = save;

  static const storageKey = 'bookalog.appearance';

  final Future<void> Function(ThemeMode mode)? _save;

  static ThemeMode parse(String? stored) => ThemeMode.values.firstWhere(
    (mode) => mode.name == stored,
    orElse: () => ThemeMode.system,
  );

  /// Restores the saved choice. Appearance is cosmetic, so storage failures
  /// fall back to following the OS rather than blocking startup.
  static Future<AppearanceController> restore() async {
    try {
      final preferences = SharedPreferencesAsync();
      final stored = await preferences.getString(storageKey);
      return AppearanceController(
        parse(stored),
        (mode) => preferences.setString(storageKey, mode.name),
      );
    } catch (_) {
      return AppearanceController();
    }
  }

  Future<void> select(ThemeMode mode) async {
    if (mode == value) return;
    value = mode;
    try {
      await _save?.call(mode);
    } catch (_) {
      // The choice still applies for this session.
    }
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}

const appearanceLabels = {
  ThemeMode.system: 'Match system',
  ThemeMode.light: 'Light',
  ThemeMode.dark: 'Dark',
};

/// Three-way System / Light / Dark switch for the sidebar footer.
class AppearanceSwitch extends StatelessWidget {
  const AppearanceSwitch({super.key, required this.controller});

  final AppearanceController controller;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ThemeMode>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: const VisualDensity(horizontal: -4, vertical: -3),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 4),
        ),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      segments: [
        for (final (mode, label) in const [
          (ThemeMode.system, 'System'),
          (ThemeMode.light, 'Light'),
          (ThemeMode.dark, 'Dark'),
        ])
          ButtonSegment(
            value: mode,
            tooltip: '${appearanceLabels[mode]} appearance',
            label: Text(label),
          ),
      ],
      selected: {controller.value},
      onSelectionChanged: (selection) => controller.select(selection.single),
    );
  }
}
