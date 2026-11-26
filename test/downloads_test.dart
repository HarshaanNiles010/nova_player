import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  group('font catalog', () {
    test('the repo catalog parses with every entry kept', () {
      final json = File('fonts/catalog.json').readAsStringSync();
      final fonts = parseFontCatalog(json);
      expect(fonts, isNotEmpty);
      expect(fonts.length, (jsonDecode(json) as List).length);
    });

    test('keeps only https entries from allowed hosts', () {
      Map<String, String> entry(String zip) => {
        'name': 'F',
        'by': 'B',
        'license': 'OFL',
        'zip': zip,
        'regular': 'f/Regular.ttf',
        'bold': 'f/Bold.ttf',
      };
      final fonts = parseFontCatalog(
        jsonEncode([
          entry('https://typographic.systems/download/F-ttf.zip'),
          entry('http://typographic.systems/download/F-ttf.zip'),
          entry('https://evil.example/F-ttf.zip'),
          {'name': 'broken'},
        ]),
      );
      expect(fonts.map((f) => f.zip.toString()), [
        'https://typographic.systems/download/F-ttf.zip',
      ]);
    });

    test('readZipEntries reads stored and deflated files', () {
      final regular = utf8.encode('regular font bytes ' * 20);
      final bold = utf8.encode('bold');
      final zip = _zip({
        'f/Regular.ttf': regular,
        'f/Bold.ttf': bold,
        'x': [1],
      });
      final files = readZipEntries(zip, {'f/Regular.ttf', 'f/Bold.ttf'});
      expect(files['f/Regular.ttf'], regular);
      expect(files['f/Bold.ttf'], bold);
      expect(files.containsKey('x'), isFalse);
    });

    test('readZipEntries rejects what is not a zip', () {
      expect(
        () => readZipEntries(Uint8List.fromList(List.filled(40, 0)), {'a'}),
        throwsFormatException,
      );
    });
  });
}

String _encode(Map<String, dynamic> json) => jsonEncode(json);

/// A minimal zip: the first file deflated, the rest stored.
Uint8List _zip(Map<String, List<int>> files) {
  final out = BytesBuilder();
  final directory = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, v >> 8 & 0xff]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff]);
  var first = true;
  for (final MapEntry(key: name, value: data) in files.entries) {
    final method = first ? 8 : 0;
    first = false;
    final body = method == 8 ? ZLibEncoder(raw: true).convert(data) : data;
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    u32(out, 0x04034b50);
    for (final v in [20, 0, method, 0, 0]) {
      u16(out, v);
    }
    u32(out, 0); // CRC, which the reader does not check
    u32(out, body.length);
    u32(out, data.length);
    u16(out, nameBytes.length);
    u16(out, 0);
    out
      ..add(nameBytes)
      ..add(body);
    u32(directory, 0x02014b50);
    for (final v in [20, 20, 0, method, 0, 0]) {
      u16(directory, v);
    }
    u32(directory, 0);
    u32(directory, body.length);
    u32(directory, data.length);
    for (final v in [nameBytes.length, 0, 0, 0, 0]) {
      u16(directory, v);
    }
    u32(directory, 0);
    u32(directory, offset);
    directory.add(nameBytes);
  }
  final start = out.length;
  final dir = directory.takeBytes();
  out.add(dir);
  u32(out, 0x06054b50);
  for (final v in [0, 0, files.length, files.length]) {
    u16(out, v);
  }
  u32(out, dir.length);
  u32(out, start);
  u16(out, 0);
  return out.takeBytes();
}
