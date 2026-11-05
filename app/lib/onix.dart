import 'dart:convert';
import 'dart:typed_data';

import 'package:bookalog_exchange/bookalog_exchange.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'catalog.dart';

const onixNamespace = 'http://ns.editeur.org/onix/3.0/reference';
const onixProfile = 'bookalog-onix-core-v1';
const onixProfileNotice =
    'Provisional ONIX 3.0 reference-tag core profile, not a recipient-approved feed. '
    'Contributors, categories, covers, prices, rights and internal revisions are not exported. '
    'Unsupported input fields or codes block the file; they are never silently discarded. '
    'Review against the current catalog before applying; ONIX carries no Bookalog revision.';
const _forms = {
  'paperback': 'BC',
  'hardback': 'BB',
  'ebook': 'EA',
  'audio': 'AA',
};
const _languages = {
  'en': 'eng',
  'fr': 'fre',
  'de': 'ger',
  'es': 'spa',
  'it': 'ita',
  'pt': 'por',
  'nl': 'dut',
  'da': 'dan',
  'sv': 'swe',
  'no': 'nor',
  'fi': 'fin',
  'is': 'ice',
  'pl': 'pol',
  'cs': 'cze',
  'el': 'gre',
  'ru': 'rus',
  'ar': 'ara',
  'he': 'heb',
  'hi': 'hin',
  'ja': 'jpn',
  'ko': 'kor',
  'zh': 'chi',
};
const _statuses = {
  'planned': ('01', '02'),
  'announced': ('02', '02'),
  'released': ('03', '04'),
  'out_of_print': ('03', '07'),
};

String? onixLanguageCode(String language) =>
    _languages[language] ??
    (_languages.containsValue(language) ? language : null);

class OnixCatalogInput {
  const OnixCatalogInput(this.records, this.provenance);
  final List<Map<String, String>> records;
  final List<Map<String, String>> provenance;
}

Never _invalid(String message) => throw FormatException(message);

bool _xmlText(String text) => text.runes.every(
  (rune) =>
      rune == 9 ||
      rune == 10 ||
      rune == 13 ||
      (rune >= 0x20 && rune <= 0xd7ff) ||
      (rune >= 0xe000 && rune <= 0xfffd) ||
      (rune >= 0x10000 && rune <= 0x10ffff),
);

void _attributes(XmlElement node, [Map<String, String?> allowed = const {}]) {
  if (node.attributes
          .map((attribute) => attribute.name.qualified)
          .toSet()
          .length !=
      node.attributes.length) {
    _invalid('Repeated attributes on ${node.name.local}.');
  }
  for (final attribute in node.attributes) {
    if (attribute.name.qualified == 'xmlns' ||
        attribute.name.prefix == 'xmlns') {
      if (attribute.value != onixNamespace) {
        _invalid('Unsupported namespace on ${node.name.local}.');
      }
      continue;
    }
    final name = attribute.name.qualified;
    if (!allowed.containsKey(name) ||
        (allowed[name] != null && attribute.value != allowed[name])) {
      _invalid('Unsupported attribute $name on ${node.name.local}.');
    }
  }
}

void _shape(
  XmlElement node,
  Map<String, (int, int)> children, {
  Map<String, String?> attributes = const {},
}) {
  _attributes(node, attributes);
  final names = children.keys.toList();
  var last = -1;
  final counts = <String, int>{};
  for (final child in node.children) {
    if (child is XmlComment) continue;
    if (child is XmlText && child.value.trim().isEmpty) continue;
    if (child is! XmlElement) {
      _invalid('Unexpected text or instruction in ${node.name.local}.');
    }
    final name = child.name.local;
    final position = names.indexOf(name);
    if (position < 0) {
      _invalid('Unsupported ${node.name.local}/$name. No data was imported.');
    }
    if (position < last) _invalid('Out-of-order $name in ${node.name.local}.');
    last = position;
    counts[name] = (counts[name] ?? 0) + 1;
  }
  for (final entry in children.entries) {
    final count = counts[entry.key] ?? 0;
    if (count < entry.value.$1 || count > entry.value.$2) {
      _invalid('Missing or repeated ${node.name.local}/${entry.key}.');
    }
  }
}

XmlElement _one(XmlElement node, String name) {
  final children = node.childElements.where(
    (child) => child.name.local == name,
  );
  if (children.length != 1) {
    _invalid('Missing or repeated ${node.name.local}/$name.');
  }
  return children.single;
}

XmlElement? _optional(XmlElement node, String name) {
  final children = node.childElements.where(
    (child) => child.name.local == name,
  );
  return children.isEmpty ? null : children.single;
}

String _text(
  XmlElement node, {
  int maximum = 100000,
  Map<String, String?> attributes = const {},
}) {
  _attributes(node, attributes);
  if (node.childElements.isNotEmpty ||
      node.children.any((child) => child is! XmlText && child is! XmlCDATA)) {
    _invalid('Use plain text in ${node.name.local}; markup is not supported.');
  }
  final value = node.innerText;
  if (value.isEmpty || value.length > maximum || !_xmlText(value)) {
    _invalid('Invalid or oversized ${node.name.local}.');
  }
  return value;
}

String _value(XmlElement node, String name, {int maximum = 200}) =>
    _text(_one(node, name), maximum: maximum);

void _equals(XmlElement node, String name, String expected) {
  if (_value(node, name) != expected) {
    _invalid('Unsupported $name; this profile requires $expected.');
  }
}

String _uuid(String value) {
  if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      .hasMatch(value)) {
    _invalid('Bookalog identifiers must be lowercase UUIDs.');
  }
  return value;
}

String _date(XmlElement node) {
  final format = node.getAttribute('dateformat') ?? '00';
  final text = _text(node, maximum: 8, attributes: {'dateformat': format});
  final length = switch (format) {
    '00' => 8,
    '01' => 6,
    '05' => 4,
    _ => 0,
  };
  if (text.length != length || !RegExp(r'^\d+$').hasMatch(text)) {
    _invalid('Use dateformat 00 (YYYYMMDD), 01 (YYYYMM), or 05 (YYYY).');
  }
  final value = [
    text.substring(0, 4),
    if (length >= 6) text.substring(4, 6),
    if (length == 8) text.substring(6, 8),
  ].join('-');
  if (!isValidReleaseDate(value)) _invalid('Invalid publication date $text.');
  return value;
}

void _sentDate(String value) {
  if (!RegExp(r'^[1-9]\d{7}T\d{6}Z$').hasMatch(value) ||
      !isValidReleaseDate(
        '${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)}',
      ) ||
      int.parse(value.substring(9, 11)) > 23 ||
      int.parse(value.substring(11, 13)) > 59 ||
      int.parse(value.substring(13, 15)) > 59) {
    _invalid('SentDateTime must be a real UTC YYYYMMDDThhmmssZ timestamp.');
  }
}

OnixCatalogInput decodeCatalogOnix(Uint8List bytes) {
  if (bytes.length > maximumFileBytes) _invalid('File exceeds 8 MiB.');
  var source = utf8.decode(bytes);
  if (source.startsWith('\ufeff')) source = source.substring(1);
  if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(source)) {
    _invalid('DTD and entity declarations are not accepted.');
  }
  var depth = 0;
  var elements = 0;
  for (final event in parseEvents(source)) {
    if (event is XmlStartElementEvent) {
      elements++;
      depth++;
      if (depth > 24 || elements > 250000) {
        _invalid('ONIX exceeds the nesting or element limit.');
      }
      if (event.isSelfClosing) depth--;
    } else if (event is XmlEndElementEvent) {
      depth--;
    } else if (event is XmlProcessingEvent || event is XmlDoctypeEvent) {
      _invalid('XML processing instructions and DTDs are not accepted.');
    } else if (event is XmlDeclarationEvent) {
      final attributes = {
        for (final attribute in event.attributes)
          attribute.name: attribute.value,
      };
      if (attributes['version'] != '1.0' ||
          attributes.length != event.attributes.length ||
          attributes.keys.any(
            (name) => !['version', 'encoding', 'standalone'].contains(name),
          ) ||
          (attributes['standalone'] != null &&
              !['yes', 'no'].contains(attributes['standalone'])) ||
          (attributes['encoding'] != null &&
              attributes['encoding']!.toUpperCase() != 'UTF-8')) {
        _invalid('Use XML 1.0 encoded as UTF-8.');
      }
    }
  }
  final document = XmlDocument.parse(source);
  final root = document.rootElement;
  for (final node in [root, ...root.descendants.whereType<XmlElement>()]) {
    if (node.namespaceUri != onixNamespace) {
      _invalid('Use the ONIX 3.0 reference-tag namespace.');
    }
  }
  if (root.name.local != 'ONIXMessage' ||
      root.getAttribute('release') != '3.0') {
    _invalid('Only ONIX 3.0 reference-tag messages are supported.');
  }
  _shape(
    root,
    {'Header': (1, 1), 'Product': (1, 5000)},
    attributes: {'release': '3.0'},
  );
  final header = _one(root, 'Header');
  _shape(header, {'Sender': (1, 1), 'SentDateTime': (1, 1)});
  final sender = _one(header, 'Sender');
  _shape(sender, {'SenderName': (1, 1)});
  final senderName = _value(sender, 'SenderName');
  if (senderName.trim().isEmpty) _invalid('SenderName may not be blank.');
  final sentAt = _value(header, 'SentDateTime');
  _sentDate(sentAt);
  final records = <Map<String, String>>[];
  final provenance = <Map<String, String>>[];
  final references = <String>{};
  for (final product in root.childElements.where(
    (node) => node.name.local == 'Product',
  )) {
    try {
      _shape(product, {
        'RecordReference': (1, 1),
        'NotificationType': (1, 1),
        'ProductIdentifier': (1, 2),
        'DescriptiveDetail': (1, 1),
        'CollateralDetail': (0, 1),
        'PublishingDetail': (1, 1),
        'RelatedMaterial': (0, 1),
      });
      final reference = _value(product, 'RecordReference');
      if (reference.trim().isEmpty || !references.add(reference)) {
        _invalid('RecordReference must be nonempty and unique.');
      }
      var id = '';
      var isbn = '';
      final identifierTypes = <String>{};
      for (final identifier in product.childElements.where(
        (node) => node.name.local == 'ProductIdentifier',
      )) {
        _shape(identifier, {
          'ProductIDType': (1, 1),
          'IDTypeName': (0, 1),
          'IDValue': (1, 1),
        });
        final type = _value(identifier, 'ProductIDType');
        if (!identifierTypes.add(type)) {
          _invalid('Repeated ProductIDType $type.');
        }
        final value = _value(identifier, 'IDValue');
        if (type == '01') {
          _equals(identifier, 'IDTypeName', 'Bookalog edition');
          id = _uuid(value);
        } else if (type == '15' &&
            _optional(identifier, 'IDTypeName') == null) {
          if (validateCatalogIsbn(value) != null) _invalid('Invalid ISBN-13.');
          isbn = value;
        } else {
          _invalid('Unsupported product identifier $type.');
        }
      }
      final detail = _one(product, 'DescriptiveDetail');
      _shape(detail, {
        'ProductComposition': (1, 1),
        'ProductForm': (1, 1),
        'TitleDetail': (1, 1),
        'Language': (1, 1),
      });
      _equals(detail, 'ProductComposition', '00');
      final formCode = _value(detail, 'ProductForm');
      final form = _forms.entries.where((entry) => entry.value == formCode);
      if (form.isEmpty) _invalid('Unsupported ProductForm $formCode.');
      final title = _one(detail, 'TitleDetail');
      _shape(title, {'TitleType': (1, 1), 'TitleElement': (1, 1)});
      _equals(title, 'TitleType', '01');
      final titleElement = _one(title, 'TitleElement');
      _shape(titleElement, {'TitleElementLevel': (1, 1), 'TitleText': (1, 1)});
      _equals(titleElement, 'TitleElementLevel', '01');
      final titleText = _value(titleElement, 'TitleText', maximum: 500);
      if (titleText.trim().isEmpty) _invalid('TitleText may not be blank.');
      final language = _one(detail, 'Language');
      _shape(language, {'LanguageRole': (1, 1), 'LanguageCode': (1, 1)});
      _equals(language, 'LanguageRole', '01');
      final code = _value(language, 'LanguageCode');
      final languageMatch = _languages.entries.where(
        (entry) => entry.value == code,
      );
      if (languageMatch.isEmpty) _invalid('Unsupported LanguageCode $code.');
      var description = '';
      if (_optional(product, 'CollateralDetail') case final collateral?) {
        _shape(collateral, {'TextContent': (1, 1)});
        final content = _one(collateral, 'TextContent');
        _shape(content, {
          'TextType': (1, 1),
          'ContentAudience': (1, 1),
          'Text': (1, 1),
        });
        _equals(content, 'TextType', '03');
        _equals(content, 'ContentAudience', '00');
        description = _text(
          _one(content, 'Text'),
          attributes: {'textformat': '06'},
        );
      }
      final publishing = _one(product, 'PublishingDetail');
      _shape(publishing, {
        'Publisher': (1, 1),
        'PublishingStatus': (1, 1),
        'PublishingDate': (0, 1),
      });
      final publisher = _one(publishing, 'Publisher');
      _shape(publisher, {'PublishingRole': (1, 1), 'PublisherName': (1, 1)});
      _equals(publisher, 'PublishingRole', '01');
      final publisherName = _value(publisher, 'PublisherName');
      if (publisherName.trim().isEmpty) {
        _invalid('PublisherName may not be blank.');
      }
      final notification = _value(product, 'NotificationType');
      final publishingStatus = _value(publishing, 'PublishingStatus');
      final status = _statuses.entries.where(
        (entry) => entry.value == (notification, publishingStatus),
      );
      if (status.isEmpty) {
        _invalid(
          'Unsupported notification/status $notification/$publishingStatus. '
          'Deletes, block updates and test messages are not imported.',
        );
      }
      var release = '';
      if (_optional(publishing, 'PublishingDate') case final date?) {
        _shape(date, {'PublishingDateRole': (1, 1), 'Date': (1, 1)});
        _equals(date, 'PublishingDateRole', '01');
        release = _date(_one(date, 'Date'));
      }
      if (publishingStatus == '02' && release.isEmpty) {
        _invalid('Forthcoming products require an expected publication date.');
      }
      var workId = '';
      if (_optional(product, 'RelatedMaterial') case final related?) {
        _shape(related, {'RelatedWork': (1, 1)});
        final work = _one(related, 'RelatedWork');
        _shape(work, {'WorkRelationCode': (1, 1), 'WorkIdentifier': (1, 1)});
        _equals(work, 'WorkRelationCode', '01');
        final identifier = _one(work, 'WorkIdentifier');
        _shape(identifier, {
          'WorkIDType': (1, 1),
          'IDTypeName': (1, 1),
          'IDValue': (1, 1),
        });
        _equals(identifier, 'WorkIDType', '01');
        _equals(identifier, 'IDTypeName', 'Bookalog work');
        workId = _uuid(_value(identifier, 'IDValue'));
      }
      records.add({
        'id': id,
        'work_id': workId,
        'revision': '',
        'title': titleText,
        'format': form.single.key,
        'language': languageMatch.single.key,
        'isbn13': isbn,
        'publication_status': status.single.key,
        'release_date': release,
        'description': description,
      });
      provenance.add({
        'profile': onixProfile,
        'record_reference': reference,
        'sender': senderName,
        'sent_at': sentAt,
        'publisher': publisherName,
      });
    } on FormatException catch (error) {
      _invalid('ONIX product ${records.length + 1}: ${error.message}');
    }
  }
  return OnixCatalogInput(records, provenance);
}

Uint8List encodeCatalogOnix(
  List<CatalogEdition> editions, {
  required String publisher,
  required DateTime sentAt,
}) {
  if (editions.isEmpty || editions.length > 5000) {
    _invalid('Export 1-5,000 editions as ONIX.');
  }
  if (publisher.trim().isEmpty ||
      publisher.length > 200 ||
      !_xmlText(publisher)) {
    _invalid('Enter a publisher name of 1-200 XML-safe characters.');
  }
  final stamp =
      '${sentAt.toUtc().toIso8601String().split('.').first.replaceAll('-', '').replaceAll(':', '')}Z';
  _sentDate(stamp);
  final builder = XmlBuilder();
  void text(String name, String value, [Map<String, String>? attributes]) =>
      builder.element(
        name,
        attributes: attributes ?? {},
        nest: () => builder.text(value),
      );
  builder.processing('xml', 'version="1.0" encoding="UTF-8"');
  builder.element(
    'ONIXMessage',
    attributes: {'xmlns': onixNamespace, 'release': '3.0'},
    nest: () {
      builder.element(
        'Header',
        nest: () {
          builder.element(
            'Sender',
            nest: () => text('SenderName', publisher.trim()),
          );
          text('SentDateTime', stamp);
        },
      );
      final ids = <String>{};
      for (final edition in editions) {
        final id = _uuid(edition.id);
        final workId = _uuid(edition.workId);
        if (!ids.add(id)) _invalid('Repeated edition $id.');
        final form = _forms[edition.format];
        final language = onixLanguageCode(edition.language);
        final status = _statuses[edition.publicationStatus];
        if (form == null || language == null || status == null) {
          _invalid(
            'Edition $id has a format, language or status outside $onixProfile. '
            'Regional language tags and unmapped codes are not simplified.',
          );
        }
        if (edition.title.trim().isEmpty ||
            edition.title.length > 500 ||
            edition.description.length > 100000 ||
            !_xmlText(edition.title) ||
            !_xmlText(edition.description) ||
            edition.isbn == '' ||
            validateCatalogIsbn(edition.isbn ?? '') != null ||
            (edition.releaseDate != null &&
                !isValidReleaseDate(edition.releaseDate!))) {
          _invalid('Edition $id has invalid or oversized core metadata.');
        }
        if (status.$2 == '02' && edition.releaseDate == null) {
          _invalid(
            'Edition $id needs an expected publication date for forthcoming ONIX status.',
          );
        }
        builder.element(
          'Product',
          nest: () {
            text('RecordReference', 'urn:uuid:$id');
            text('NotificationType', status.$1);
            builder.element(
              'ProductIdentifier',
              nest: () {
                text('ProductIDType', '01');
                text('IDTypeName', 'Bookalog edition');
                text('IDValue', id);
              },
            );
            if (edition.isbn case final isbn?) {
              builder.element(
                'ProductIdentifier',
                nest: () {
                  text('ProductIDType', '15');
                  text('IDValue', isbn);
                },
              );
            }
            builder.element(
              'DescriptiveDetail',
              nest: () {
                text('ProductComposition', '00');
                text('ProductForm', form);
                builder.element(
                  'TitleDetail',
                  nest: () {
                    text('TitleType', '01');
                    builder.element(
                      'TitleElement',
                      nest: () {
                        text('TitleElementLevel', '01');
                        text('TitleText', edition.title);
                      },
                    );
                  },
                );
                builder.element(
                  'Language',
                  nest: () {
                    text('LanguageRole', '01');
                    text('LanguageCode', language);
                  },
                );
              },
            );
            if (edition.description.isNotEmpty) {
              builder.element(
                'CollateralDetail',
                nest: () {
                  builder.element(
                    'TextContent',
                    nest: () {
                      text('TextType', '03');
                      text('ContentAudience', '00');
                      text('Text', edition.description, {'textformat': '06'});
                    },
                  );
                },
              );
            }
            builder.element(
              'PublishingDetail',
              nest: () {
                builder.element(
                  'Publisher',
                  nest: () {
                    text('PublishingRole', '01');
                    text('PublisherName', publisher.trim());
                  },
                );
                text('PublishingStatus', status.$2);
                if (edition.releaseDate case final release?) {
                  builder.element(
                    'PublishingDate',
                    nest: () {
                      text('PublishingDateRole', '01');
                      text('Date', release.replaceAll('-', ''), {
                        'dateformat': switch (release.length) {
                          4 => '05',
                          7 => '01',
                          _ => '00',
                        },
                      });
                    },
                  );
                }
              },
            );
            builder.element(
              'RelatedMaterial',
              nest: () {
                builder.element(
                  'RelatedWork',
                  nest: () {
                    text('WorkRelationCode', '01');
                    builder.element(
                      'WorkIdentifier',
                      nest: () {
                        text('WorkIDType', '01');
                        text('IDTypeName', 'Bookalog work');
                        text('IDValue', workId);
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
  // XML normalizes literal CR; character references preserve description line endings.
  final bytes = Uint8List.fromList(
    utf8.encode(
      builder.buildDocument().toXmlString().replaceAll('\r', '&#13;'),
    ),
  );
  if (bytes.length > maximumFileBytes) _invalid('ONIX export exceeds 8 MiB.');
  return bytes;
}
