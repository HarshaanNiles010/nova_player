import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/downloads.dart';

void main() {
  test('theme catalog parses, round-trips and skips bad entries', () {
    final themes = parseThemeCatalog(
      File('themes/catalog.json').readAsStringSync(),
    );
    expect(themes, isNotEmpty);
    expect(themes.map((t) => t.id).toSet().length, themes.length);
    final again = parseThemeCatalog(
      '[${themes.map((t) => t.toJson()).map(_encode).join(',')},'
      '{"id": "broken", "name": "Broken", "primary": "#12"}]',
    );
    expect(again.map((t) => t.toJson()), themes.map((t) => t.toJson()));
  });

  test('font urls come from a Google Fonts stylesheet', () {
    const css = '''
@font-face {
  font-family: 'Roboto Slab';
  font-weight: 400;
  src: url(https://fonts.gstatic.com/s/a/regular.ttf) format('truetype');
}
@font-face {
  font-family: 'Roboto Slab';
  font-weight: 700;
  src: url(https://fonts.gstatic.com/s/a/bold.ttf) format('truetype');
}''';
    expect(fontFileUrls(css), [
      (400, Uri.parse('https://fonts.gstatic.com/s/a/regular.ttf')),
      (700, Uri.parse('https://fonts.gstatic.com/s/a/bold.ttf')),
    ]);
  });
}

String _encode(Map<String, dynamic> json) => jsonEncode(json);
