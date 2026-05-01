@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time_nts/src/sources/time_sources.dart';

void main() {
  group('HttpsSource constructor scheme enforcement', () {
    test('accepts an https URL', () {
      final source = HttpsSource('https://www.example.com');
      addTearDown(source.dispose);
      expect(source.id, 'https:https://www.example.com');
    });

    test('rejects an http URL', () {
      expect(
        () => HttpsSource('http://www.example.com'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('https scheme'), contains('http')),
          ),
        ),
      );
    });

    test('rejects a non-web scheme', () {
      expect(
        () => HttpsSource('ftp://files.example.com'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a bare host without a scheme', () {
      expect(
        () => HttpsSource('www.example.com'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an empty string', () {
      expect(() => HttpsSource(''), throwsA(isA<ArgumentError>()));
    });

    test('rejects an https URL missing a host', () {
      expect(() => HttpsSource('https://'), throwsA(isA<ArgumentError>()));
    });
  });
}
