import 'package:bookalog_catalog/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encodes a valid ISBN-13 as 95 EAN-13 modules with guards', () {
    final modules = ean13Modules('9780306406157');

    expect(modules, hasLength(95));
    expect(modules!.sublist(0, 3), [true, false, true]);
    expect(modules.sublist(45, 50), [false, true, false, true, false]);
    expect(modules.sublist(92), [true, false, true]);
  });

  test('rejects codes with a bad check digit or wrong length', () {
    expect(ean13Modules('9780306406158'), isNull);
    expect(ean13Modules('978030640615'), isNull);
    expect(ean13Modules('97803064061X7'), isNull);
  });

  testWidgets('ISBN label explains missing and invalid codes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildBookalogTheme(Brightness.light),
        home: const Scaffold(
          body: Column(
            children: [
              IsbnLabel(isbn: null),
              IsbnLabel(isbn: '9780306406158'),
              IsbnLabel(isbn: '9780306406157'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Assign an ISBN-13 to print a barcode'), findsOneWidget);
    expect(find.text('Check digit does not validate'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('9780306406157')), findsOneWidget);
  });
}
