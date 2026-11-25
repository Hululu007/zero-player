import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_openstax_catalogue.dart';

import '../../test_support/publication_catalogue_fixture.dart';

const _pdf =
    'https://assets.openstax.org/oscms-prodcms/media/documents/Business_Law_I_Essentials_2e_-_WEB.pdf';

void main() {
  test('keywords match books past the first browse page', () async {
    await withPublicationCatalogue(
      (fixture) async {
        final transport = MediaHttpClient();
        try {
          final catalog = OpenStaxCatalogue(
            PublicationHttp(transport, authorize: (_) {}),
          );
          final books = await catalog.search(
            'Business Law',
            CancellationToken(),
            maxPages: 1,
            allowed: (_) => true,
          );
          expect(books.single.title, 'Business Law I Essentials 2e');
          expect(fixture.requests.map((uri) => uri.queryParameters['offset']), [
            '0',
            '1',
          ]);
        } finally {
          transport.close();
        }
      },
      host: 'openstax.org',
      respond: (request) async {
        final first = request.uri.queryParameters['offset'] == '0';
        request.response.write(
          jsonEncode({
            'meta': {'total_count': 2},
            'items': [
              if (first) _record({'title': 'Different Subject'}) else _record(),
            ],
          }),
        );
        await request.response.close();
      },
    );
  });

  test('finds a publisher edition by title, author, and either ISBN', () {
    final book = _record();
    for (final query in [
      'law essentials',
      'Betty Ross',
      '979-8-90095-013-6',
      '9781491939369',
    ]) {
      final edition = parseOpenStaxEdition(book, query)!;
      expect(edition.title, 'Business Law I Essentials 2e');
      expect(edition.license, 'CC BY-NC-SA 4.0');
      expect(edition.isbn, '9798900950136');
      expect(edition.candidates.single.link, Uri.parse(_pdf));
      expect(edition.page?.path, '/details/books/business-law-i-essentials-2e');
    }
    expect(parseOpenStaxEdition(book, 'another book'), isNull);
    expect(
      parseOpenStaxEdition(_record({'book_state': 'retired'}), ''),
      isNull,
    );
  });

  test(
    'shows catalogue metadata without a candidate when files are restricted',
    () {
      for (final change in [
        {'license_url': 'https://elsewhere.example/licenses/by/4.0/'},
        {'license_url': 'https://creativecommons.org/licenses/unknown/4.0/'},
        {'require_login_message_text': 'Sign in before continuing'},
        {'pdf_url': 'https://assets.openstax.org/private/exam.pdf'},
        {'pdf_url': 'https://www.openstax.org/redirect.pdf'},
        {'pdf_url': '$_pdf?token=secret'},
        {'pdf_url': _pdf.replaceFirst('Business_Law', 'folder%2FBusiness_Law')},
      ]) {
        expect(parseOpenStaxEdition(_record(change), '')?.candidates, isEmpty);
      }
      final current = parseOpenStaxEdition(_record(), '')!.candidates.single;
      final updated = parseOpenStaxEdition(
        _record({'last_updated_pdf': '2026-11-21'}),
        '',
      )!.candidates.single;
      expect(updated.link, current.link);
      expect(updated.id, isNot(current.id));
    },
  );
}

Map<String, Object?> _record([Map<String, Object?> overrides = const {}]) => {
  'id': 975,
  'book_state': 'live',
  'title': 'Business Law I Essentials 2e',
  'meta': {
    'slug': 'business-law-i-essentials-2e',
    'type': 'books.Book',
    'locale': 'en',
    'html_url':
        'https://openstax.org/details/books/business-law-i-essentials-2e',
  },
  'publish_date': '2026-11-20',
  'license_url': 'https://creativecommons.org/licenses/by-nc-sa/4.0/',
  'pdf_url': _pdf,
  'digital_isbn_13': '979-8-90095-013-6',
  'print_isbn_13': '9781491939369',
  'authors': [
    for (final name in [
      'John Adams',
      'Mary Smith',
      'Laura Torres',
      'Betty Ross',
    ])
      {
        'type': 'author',
        'value': {'name': name},
      },
  ],
  ...overrides,
};
