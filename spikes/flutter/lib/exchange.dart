import 'dart:convert';
import 'dart:typed_data';

import 'package:bookalog_exchange/bookalog_exchange.dart' as tables;
import 'package:xml/xml.dart';

import 'catalog.dart';

const maximumFileBytes = tables.maximumFileBytes;
const maximumExpandedBytes = tables.maximumExpandedBytes;

XmlDocument _xml(String source) {
  if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(source)) {
    throw const FormatException(
      'DTD and entity declarations are not accepted.',
    );
  }
  return XmlDocument.parse(source);
}

int previewXlsx(Uint8List bytes) {
  final rows = tables.decodeXlsxTable(
    bytes,
    maximumRows: 10000,
    maximumColumns: 7,
  );
  if (rows.first.join('|') != exchangeColumns.join('|')) {
    throw const FormatException('Expected the seven comparison columns.');
  }
  return rows.length - 1;
}

Uint8List xlsxProjection(List<Edition> editions) {
  if (editions.length > 10000) {
    throw const FormatException(
      'The comparison exports at most 10,000 editions.',
    );
  }
  return tables.encodeXlsxTable([
    exchangeColumns,
    ...editions.map(
      (edition) => exchangeColumns
          .map((column) => edition.record[column]?.toString() ?? '')
          .toList(),
    ),
  ]);
}

int previewOnix(Uint8List bytes) {
  if (bytes.length > maximumFileBytes) {
    throw const FormatException('File exceeds 8 MiB.');
  }
  final root = _xml(utf8.decode(bytes)).rootElement;
  if (root.name.local != 'ONIXMessage' ||
      root.getAttribute('release') != '3.0') {
    throw const FormatException(
      'Only the illustrative ONIX 3.0 profile is accepted.',
    );
  }
  final products = root.findElements('Product').toList();
  if (products.isEmpty || products.length > 10000) {
    throw const FormatException('Expected 1-10,000 illustrative products.');
  }
  for (final product in products) {
    for (final name in ['RecordReference', 'IDValue', 'TitleText']) {
      if (!product
          .findAllElements(name)
          .any((node) => node.innerText.trim().isNotEmpty)) {
        throw FormatException('Product is missing $name.');
      }
    }
  }
  return products.length;
}

Uint8List onixProjection(List<Edition> editions) {
  if (editions.isEmpty || editions.length > 10000) {
    throw const FormatException('Expected 1-10,000 editions.');
  }
  final builder = XmlBuilder();
  builder.processing('xml', 'version="1.0" encoding="UTF-8"');
  builder.comment(
    'Synthetic projection only; not a complete or recipient-certified ONIX feed.',
  );
  builder.element(
    'ONIXMessage',
    attributes: {'release': '3.0'},
    nest: () {
      builder.element(
        'Header',
        nest: () {
          builder.element(
            'Sender',
            nest: () =>
                builder.element('SenderName', nest: 'Synthetic publisher'),
          );
          builder.element('SentDateTime', nest: '20300101');
        },
      );
      for (final edition in editions) {
        final form = switch (edition.format) {
          'paperback' => 'BC',
          'ebook' => 'DG',
          _ => throw const FormatException(
            'This illustrative profile supports paperback and ebook only.',
          ),
        };
        builder.element(
          'Product',
          nest: () {
            builder.element('RecordReference', nest: edition.id);
            builder.element('NotificationType', nest: '03');
            builder.element(
              'ProductIdentifier',
              nest: () {
                builder.element(
                  'ProductIDType',
                  nest: edition.isbn == null ? '01' : '15',
                );
                if (edition.isbn == null) {
                  builder.element('IDTypeName', nest: 'Bookalog synthetic');
                }
                builder.element('IDValue', nest: edition.isbn ?? edition.id);
              },
            );
            builder.element(
              'DescriptiveDetail',
              nest: () {
                builder.element('ProductComposition', nest: '00');
                builder.element('ProductForm', nest: form);
                builder.element(
                  'TitleDetail',
                  nest: () {
                    builder.element('TitleType', nest: '01');
                    builder.element(
                      'TitleElement',
                      nest: () {
                        builder.element('TitleElementLevel', nest: '01');
                        builder.element('TitleText', nest: edition.title);
                      },
                    );
                  },
                );
              },
            );
          },
        );
      }
    },
  );
  return Uint8List.fromList(utf8.encode(builder.buildDocument().toXmlString()));
}
