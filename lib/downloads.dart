import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'song.dart';
import 'theme.dart';

/// Themes anyone can add to by editing themes/catalog.json in the repo.
final themeCatalogUrl = Uri.parse(
  'https://raw.githubusercontent.com/HarshaanNiles010/nova_player/main/themes/catalog.json',
);

/// Font names offered before the user types one; any Google Fonts family works.
const suggestedFonts = [
  'Press Start 2P',
  'VT323',
  'Pixelify Sans',
  'Silkscreen',
  'Space Mono',
  'Orbitron',
  'Cinzel',
  'Nunito',
];

Future<Uint8List> _get(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(url);
    // LRCLIB asks apps to name themselves.
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Nova Player (https://github.com/HarshaanNiles010/nova_player)',
    );
    // connectionTimeout only covers connecting; a server that stalls after
    // that would leave a spinner up forever.
    final response = await request.close().timeout(_readTimeout);
    final bytes = await response
        .timeout(_readTimeout)
        .fold<BytesBuilder>(
          BytesBuilder(),
          (builder, chunk) => builder..add(chunk),
        );
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}

const _readTimeout = Duration(seconds: 20);

Future<List<AppThemePreset>> fetchThemeCatalog() async =>
    parseThemeCatalog(utf8.decode(await _get(themeCatalogUrl)));

/// Skips entries that are not valid themes instead of failing the whole list.
List<AppThemePreset> parseThemeCatalog(String json) => [
  for (final item in jsonDecode(json) as List<dynamic>) ?_tryTheme(item),
];

AppThemePreset? _tryTheme(Object? item) {
  try {
    return AppThemePreset.fromJson(item as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

/// (weight, .ttf url) pairs from a Google Fonts css2 stylesheet.
List<(int, Uri)> fontFileUrls(String css) => [
  for (final match in RegExp(
    r'font-weight:\s*(\d+);\s*src:\s*url\((https://[^)]+\.ttf)\)',
  ).allMatches(css))
    (int.parse(match[1]!), Uri.parse(match[2]!)),
];

/// Downloaded font files live in `<app files>/fonts/<family>-<weight>.ttf`.
Future<Directory> _fontDir() async {
  final files = await const MethodChannel('com.novaplayer/music_library')
      .invokeMethod<String>('getFilesDir');
  return Directory('$files/fonts').create(recursive: true);
}

String _stem(String name) =>
    name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');

/// Weight files of [name] only: "nunito-400.ttf", not "nunito-sans-400.ttf".
bool _isFileOf(File file, String name) =>
    RegExp('^${RegExp.escape(_stem(name))}-\\d+\\.ttf\$')
        .hasMatch(file.uri.pathSegments.last);

/// Downloads regular and bold of a Google Fonts family and saves the files.
/// Throws when the family does not exist or the phone is offline.
Future<void> downloadFont(String name) async {
  // Without a browser user agent, Google serves plain .ttf files.
  final css = utf8.decode(
    await _get(
      Uri.https('fonts.googleapis.com', '/css2', {
        'family': '$name:wght@400;700',
      }),
    ),
  );
  final urls = fontFileUrls(css);
  if (urls.isEmpty) throw FormatException('No font files for $name');
  final dir = await _fontDir();
  for (final (weight, url) in urls) {
    await File('${dir.path}/${_stem(name)}-$weight.ttf')
        .writeAsBytes(await _get(url));
  }
}

/// Registers a downloaded font with Flutter; false when its files are gone.
Future<bool> loadDownloadedFont(AppFont font) async {
  final dir = await _fontDir();
  final files = dir.listSync().whereType<File>().where(
    (file) => _isFileOf(file, font.name),
  );
  if (files.isEmpty) return false;
  final loader = FontLoader(font.family!);
  for (final file in files) {
    loader.addFont(file.readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
  return true;
}

Future<void> deleteFontFiles(String name) async {
  for (final file in (await _fontDir()).listSync().whereType<File>()) {
    if (_isFileOf(file, name)) {
      await file.delete();
    }
  }
}

/// Lyrics for [song] from LRCLIB (lrclib.net), synced when it has them;
/// null when it has none. Throws when LRCLIB cannot be reached.
Future<String?> fetchLyrics(Song song) async {
  final seconds = song.duration.inSeconds;
  try {
    final exact = await _get(
      Uri.https('lrclib.net', '/api/get', {
        'track_name': song.title,
        'artist_name': song.artist,
        'album_name': song.album,
        'duration': '$seconds',
      }),
    );
    return lrclibLyrics(jsonDecode(utf8.decode(exact)));
  } on HttpException {
    // Not found with this album and length; search by title and artist.
  }
  final found = await _get(
    Uri.https('lrclib.net', '/api/search', {
      'track_name': song.title,
      'artist_name': song.artist,
    }),
  );
  return closestLrclibLyrics(jsonDecode(utf8.decode(found)), seconds);
}

/// The lyrics of one LRCLIB record, synced first.
String? lrclibLyrics(Object? record) {
  if (record is! Map<String, dynamic>) return null;
  for (final key in ['syncedLyrics', 'plainLyrics']) {
    if (record[key] case final String text when text.trim().isNotEmpty) {
      return text;
    }
  }
  return null;
}

/// Lyrics of the search result whose length is closest to [seconds], within
/// 3 seconds, so a live or extended version is not used.
String? closestLrclibLyrics(Object? results, int seconds) {
  if (results is! List<dynamic>) return null;
  final candidates = [
    for (final record in results)
      if (record case {'duration': final num length}
          when (length - seconds).abs() <= 3 && lrclibLyrics(record) != null)
        (record, (length - seconds).abs()),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return candidates.isEmpty ? null : lrclibLyrics(candidates.first.$1);
}
