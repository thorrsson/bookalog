/*
THESIS: Every edition is a labelled stock item; the catalog reads like a well-kept distributor shelf, not a generic admin grid.
OWN-WORLD: The 3 Little Sisters house palette: off-white stock and burgundy in daylight, deep navy and gold after dark, set in Figtree. ISBNs are set as real EAN-13 Bookland barcodes.
STORY: Staff scan covers, narrow by status or view from the location index, and open a stock card holding the barcode label, facts, and actions.
FIRST VIEWPORT: A location-index sidebar at left, a toolbar with search and the primary action, full-bleed 2:3 covers with label plates, and a stock card at right.
FORM: Grounded direction 7 (Bookland label and distributor ledger); operate mode; direction seed 58901885.
*/

import 'package:flutter/material.dart';

/// Colour roles for the Bookland label world that Material's scheme cannot name.
@immutable
class ShelfPalette extends ThemeExtension<ShelfPalette> {
  const ShelfPalette({
    required this.canvas,
    required this.rail,
    required this.paper,
    required this.ink,
    required this.inkMuted,
    required this.hairline,
    required this.accent,
    required this.onAccent,
    required this.blankBoard,
  });

  final Color canvas;
  final Color rail;
  final Color paper;
  final Color ink;
  final Color inkMuted;
  final Color hairline;
  final Color accent;
  final Color onAccent;
  final Color blankBoard;

  // Brand: burgundy #65172D, gold #DAA428, navy #0F2B36, stone #D2D5D0.
  static const light = ShelfPalette(
    canvas: Color(0xfff5f5f5),
    rail: Color(0xffecebe6),
    paper: Color(0xffffffff),
    ink: Color(0xff1c2022),
    inkMuted: Color(0xff585c55),
    hairline: Color(0xffd2d5d0),
    accent: Color(0xff65172d),
    onAccent: Color(0xffffffff),
    blankBoard: Color(0xffe3e1da),
  );

  static const dark = ShelfPalette(
    canvas: Color(0xff0f2b36),
    rail: Color(0xff0a2029),
    paper: Color(0xff143541),
    ink: Color(0xfff2f0ea),
    inkMuted: Color(0xffa8b6b9),
    hairline: Color(0xff25495a),
    accent: Color(0xffdaa428),
    onAccent: Color(0xff19181d),
    blankBoard: Color(0xff1c4251),
  );

  static ShelfPalette of(BuildContext context) =>
      Theme.of(context).extension<ShelfPalette>() ?? light;

  @override
  ShelfPalette copyWith({
    Color? canvas,
    Color? rail,
    Color? paper,
    Color? ink,
    Color? inkMuted,
    Color? hairline,
    Color? accent,
    Color? onAccent,
    Color? blankBoard,
  }) => ShelfPalette(
    canvas: canvas ?? this.canvas,
    rail: rail ?? this.rail,
    paper: paper ?? this.paper,
    ink: ink ?? this.ink,
    inkMuted: inkMuted ?? this.inkMuted,
    hairline: hairline ?? this.hairline,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    blankBoard: blankBoard ?? this.blankBoard,
  );

  @override
  ShelfPalette lerp(ShelfPalette? other, double t) {
    if (other == null) return this;
    return ShelfPalette(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      rail: Color.lerp(rail, other.rail, t)!,
      paper: Color.lerp(paper, other.paper, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      blankBoard: Color.lerp(blankBoard, other.blankBoard, t)!,
    );
  }
}

/// Monospace is used only for identifiers, dates, and counts.
const shelfMono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: [
    'SF Mono',
    'Cascadia Mono',
    'Consolas',
    'Roboto Mono',
    'monospace',
  ],
  fontFeatures: [FontFeature.tabularFigures()],
);

const shelfRadius = BorderRadius.all(Radius.circular(4));

ThemeData buildBookalogTheme(Brightness brightness) {
  final palette = brightness == Brightness.light
      ? ShelfPalette.light
      : ShelfPalette.dark;
  final error = brightness == Brightness.light
      ? const Color(0xffb3261e)
      : const Color(0xffff8a80);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: palette.accent,
    onPrimary: palette.onAccent,
    primaryContainer: palette.accent,
    onPrimaryContainer: palette.onAccent,
    secondary: palette.ink,
    onSecondary: palette.canvas,
    secondaryContainer: palette.accent,
    onSecondaryContainer: palette.onAccent,
    tertiary: palette.accent,
    onTertiary: palette.onAccent,
    error: error,
    onError: palette.canvas,
    surface: palette.canvas,
    onSurface: palette.ink,
    onSurfaceVariant: palette.inkMuted,
    surfaceContainerLowest: palette.paper,
    surfaceContainerLow: palette.paper,
    surfaceContainer: palette.paper,
    surfaceContainerHigh: palette.rail,
    surfaceContainerHighest: palette.blankBoard,
    outline: palette.inkMuted,
    outlineVariant: palette.hairline,
    inverseSurface: palette.ink,
    onInverseSurface: palette.canvas,
    shadow: Colors.black,
    scrim: Colors.black,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    visualDensity: VisualDensity.compact,
    fontFamily: 'Figtree',
  );
  final text = base.textTheme
      .copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          height: 1.2,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 15),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 14,
          height: 1.45,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12.5),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: palette.inkMuted,
        ),
      )
      .apply(bodyColor: palette.ink, displayColor: palette.ink);
  const buttonShape = RoundedRectangleBorder(borderRadius: shelfRadius);
  const buttonSize = Size(0, 36);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 14);
  final hairlineSide = BorderSide(color: palette.hairline);
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: palette.canvas,
    canvasColor: palette.canvas,
    dividerColor: palette.hairline,
    extensions: [palette],
    dividerTheme: DividerThemeData(color: palette.hairline, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.canvas,
      foregroundColor: palette.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge,
      shape: Border(bottom: hairlineSide),
    ),
    cardTheme: CardThemeData(
      color: palette.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: shelfRadius,
        side: hairlineSide,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.ink,
        backgroundColor: palette.paper,
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        side: hairlineSide,
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brightness == Brightness.light
            ? palette.accent
            : palette.ink,
        minimumSize: buttonSize,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: buttonShape,
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: palette.ink,
        shape: buttonShape,
        minimumSize: const Size(36, 36),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(buttonShape),
        side: WidgetStatePropertyAll(hairlineSide),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.paper,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.onAccent
              : palette.ink,
        ),
        visualDensity: VisualDensity.compact,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.paper,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: shelfRadius,
        borderSide: hairlineSide,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: shelfRadius,
        borderSide: hairlineSide,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: shelfRadius,
        borderSide: BorderSide(color: palette.accent, width: 2),
      ),
      hintStyle: TextStyle(color: palette.inkMuted),
      labelStyle: TextStyle(color: palette.inkMuted),
      floatingLabelStyle: TextStyle(color: palette.ink),
      prefixIconColor: palette.inkMuted,
      suffixIconColor: palette.inkMuted,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.paper,
      selectedColor: palette.accent.withAlpha(46),
      side: hairlineSide,
      shape: const RoundedRectangleBorder(borderRadius: shelfRadius),
      labelStyle: text.bodySmall?.copyWith(
        color: palette.ink,
        fontWeight: FontWeight.w500,
      ),
      deleteIconColor: palette.inkMuted,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.paper,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      titleTextStyle: text.titleLarge,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: shelfRadius,
        side: hairlineSide,
      ),
      textStyle: text.bodyMedium,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: palette.ink, borderRadius: shelfRadius),
      textStyle: text.bodySmall?.copyWith(color: palette.canvas),
      waitDuration: const Duration(milliseconds: 400),
    ),
    listTileTheme: ListTileThemeData(
      selectedTileColor: palette.accent,
      selectedColor: palette.onAccent,
      iconColor: palette.inkMuted,
      shape: const RoundedRectangleBorder(borderRadius: shelfRadius),
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: text.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: palette.inkMuted,
      ),
      dataTextStyle: text.bodyMedium,
      headingRowHeight: 40,
      dataRowMinHeight: 44,
      dataRowMaxHeight: 44,
      dividerThickness: 1,
      dataRowColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent.withAlpha(46)
            : states.contains(WidgetState.hovered)
            ? palette.rail
            : null,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.ink,
      linearTrackColor: palette.hairline,
      linearMinHeight: 2,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.ink,
      contentTextStyle: text.bodyMedium?.copyWith(color: palette.canvas),
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: shelfRadius),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(palette.inkMuted.withAlpha(110)),
    ),
    focusColor: palette.accent.withAlpha(90),
    hoverColor: palette.ink.withAlpha(14),
    splashFactory: NoSplash.splashFactory,
  );
}

const _eanLeft = [
  '0001101',
  '0011001',
  '0010011',
  '0111101',
  '0100011',
  '0110001',
  '0101111',
  '0111011',
  '0110111',
  '0001011',
];

const _eanParity = [
  'LLLLLL',
  'LLGLGG',
  'LLGGLG',
  'LLGGGL',
  'LGLLGG',
  'LGGLLG',
  'LGGGLL',
  'LGLGLG',
  'LGLGGL',
  'LGGLGL',
];

/// Returns the 95 EAN-13 modules for a valid 13-digit code, or null.
List<bool>? ean13Modules(String? code) {
  if (code == null || !RegExp(r'^\d{13}$').hasMatch(code)) return null;
  final digits = code.split('').map(int.parse).toList();
  var sum = 0;
  for (var index = 0; index < 12; index++) {
    sum += digits[index] * (index.isEven ? 1 : 3);
  }
  if ((10 - sum % 10) % 10 != digits[12]) return null;
  String right(int digit) =>
      _eanLeft[digit].split('').map((bit) => bit == '0' ? '1' : '0').join();
  final buffer = StringBuffer('101');
  final parity = _eanParity[digits[0]];
  for (var index = 1; index <= 6; index++) {
    final digit = digits[index];
    buffer.write(
      parity[index - 1] == 'L'
          ? _eanLeft[digit]
          : right(digit).split('').reversed.join(),
    );
  }
  buffer.write('01010');
  for (var index = 7; index <= 12; index++) {
    buffer.write(right(digits[index]));
  }
  buffer.write('101');
  return buffer.toString().split('').map((bit) => bit == '1').toList();
}

bool _isGuard(int module) =>
    module < 3 || (module >= 45 && module < 50) || module >= 92;

class _BarcodePainter extends CustomPainter {
  _BarcodePainter(this.code, this.modules);

  final String code;
  final List<bool> modules;

  static const _quietLeft = 11;
  static const _quietRight = 7;

  @override
  void paint(Canvas canvas, Size size) {
    const total = _quietLeft + 95 + _quietRight;
    final module = size.width / total;
    final digitHeight = module * 9;
    final barBottom = size.height - digitHeight * 0.55;
    final guardBottom = size.height - digitHeight * 0.1;
    final paint = Paint()..color = const Color(0xff000000);
    for (var index = 0; index < modules.length; index++) {
      if (!modules[index]) continue;
      final left = (_quietLeft + index) * module;
      canvas.drawRect(
        Rect.fromLTRB(
          left,
          0,
          left + module + 0.01,
          _isGuard(index) ? guardBottom : barBottom,
        ),
        paint,
      );
    }
    final style = shelfMono.copyWith(
      color: const Color(0xff000000),
      fontSize: digitHeight,
      height: 1,
    );
    void digits(String text, double from, double to) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final centre = (from + to) / 2 * module;
      painter.paint(
        canvas,
        Offset(centre - painter.width / 2, size.height - painter.height),
      );
    }

    digits(code[0], 0, _quietLeft - 2);
    digits(code.substring(1, 7), _quietLeft + 3, _quietLeft + 45);
    digits(code.substring(7), _quietLeft + 50, _quietLeft + 92);
  }

  @override
  bool shouldRepaint(_BarcodePainter oldDelegate) => oldDelegate.code != code;
}

/// A Bookland label: always white stock with black bars, in both appearances.
class IsbnLabel extends StatelessWidget {
  const IsbnLabel({super.key, required this.isbn, this.barHeight = 58});

  final String? isbn;
  final double barHeight;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final modules = ean13Modules(isbn);
    return Semantics(
      label: isbn == null ? 'No ISBN assigned' : 'ISBN $isbn',
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xffffffff),
          borderRadius: shelfRadius,
          border: Border.all(color: palette.hairline),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isbn == null ? 'No ISBN assigned' : 'ISBN $isbn',
              style: shelfMono.copyWith(
                fontSize: 12,
                color: const Color(0xff121519),
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 6),
            if (modules != null)
              SizedBox(
                height: barHeight,
                width: double.infinity,
                child: CustomPaint(painter: _BarcodePainter(isbn!, modules)),
              )
            else
              Container(
                height: barHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xffcbd1d7)),
                  borderRadius: shelfRadius,
                ),
                child: Text(
                  isbn == null
                      ? 'Assign an ISBN-13 to print a barcode'
                      : 'Check digit does not validate',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xff505861),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Small barcode mark used as the product wordmark glyph.
class ShelfMark extends StatelessWidget {
  const ShelfMark({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    const widths = [1.6, 0.8, 0.8, 2.0, 0.8, 1.6];
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.accent,
          borderRadius: const BorderRadius.all(Radius.circular(3)),
        ),
        child: Padding(
          padding: EdgeInsets.all(size * 0.18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final width in widths)
                SizedBox(
                  width: width * size / 22,
                  child: ColoredBox(color: palette.onAccent),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Publication status as a printed stamp: outlined for pending, solid for live.
class StatusTag extends StatelessWidget {
  const StatusTag({super.key, required this.status, required this.label});

  final String status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final solid = status == 'released';
    final retired = status == 'out_of_print';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: solid ? palette.ink : null,
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        border: Border.all(color: retired ? palette.hairline : palette.ink),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: solid
              ? palette.canvas
              : retired
              ? palette.inkMuted
              : palette.ink,
        ),
      ),
    );
  }
}
