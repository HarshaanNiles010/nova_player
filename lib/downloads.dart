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
  // Fetch every weight before saving any, so a failed download leaves no
  // half-installed font that loads without its bold.
  final files = [for (final (weight, url) in urls) (weight, await _get(url))];
  final dir = await _fontDir();
  for (final (weight, bytes) in files) {
    await File('${dir.path}/${_stem(name)}-$weight.ttf').writeAsBytes(bytes);
  }
}

/// Fonts from other foundries, listed in fonts/catalog.json in the repo.
final fontCatalogUrl = Uri.parse(
  'https://raw.githubusercontent.com/HarshaanNiles010/nova_player/main/fonts/catalog.json',
);

/// Sites a catalog font may be downloaded from; anything else is skipped.
const fontHosts = {'typographic.systems'};

/// A font in the catalog: a zip on its foundry's site and the regular and
/// bold .ttf files inside it.
class CatalogFont {
  const CatalogFont({
    required this.name,
    required this.by,
    required this.license,
    required this.zip,
    required this.regular,
    required this.bold,
  });

  final String name;
  final String by;
  final String license;
  final Uri zip;
  final String regular;
  final String bold;
}

Future<List<CatalogFont>> fetchFontCatalog() async =>
    parseFontCatalog(utf8.decode(await _get(fontCatalogUrl)));

/// Skips entries that are malformed or point outside [fontHosts].
List<CatalogFont> parseFontCatalog(String json) => [
  for (final item in jsonDecode(json) as List<dynamic>) ?_tryCatalogFont(item),
];

CatalogFont? _tryCatalogFont(Object? item) {
  try {
    final map = item as Map<String, dynamic>;
    final zip = Uri.parse(map['zip'] as String);
    final regular = map['regular'] as String;
    final bold = map['bold'] as String;
    if (zip.scheme != 'https' ||
        !fontHosts.contains(zip.host) ||
        !regular.endsWith('.ttf') ||
        !bold.endsWith('.ttf')) {
      return null;
    }
    return CatalogFont(
      name: map['name'] as String,
      by: map['by'] as String,
      license: map['license'] as String,
      zip: zip,
      regular: regular,
      bold: bold,
    );
  } catch (_) {
    return null;
  }
}

/// Downloads a catalog font's zip and saves its regular and bold files under
/// [CatalogFont.name], like a Google font. Throws when offline or when the
/// zip lacks either file.
Future<void> downloadCatalogFont(CatalogFont font) async {
  final files = readZipEntries(await _get(font.zip), {font.regular, font.bold});
  final regular = files[font.regular];
  final bold = files[font.bold];
  if (regular == null || bold == null) {
    throw FormatException('${font.zip} has no ${font.regular} or ${font.bold}');
  }
  final dir = await _fontDir();
  await File('${dir.path}/${_stem(font.name)}-400.ttf').writeAsBytes(regular);
  await File('${dir.path}/${_stem(font.name)}-700.ttf').writeAsBytes(bold);
}

/// The [wanted] files of a zip archive, by their path inside it. Supports
/// stored and deflated entries, which is what zip tools write.
Map<String, Uint8List> readZipEntries(Uint8List zip, Set<String> wanted) {
  final data = ByteData.sublistView(zip);
  int u16(int at) => data.getUint16(at, Endian.little);
  int u32(int at) => data.getUint32(at, Endian.little);
  // The end-of-directory record is last, after a comment of up to 64 KB.
  var end = -1;
  for (var i = zip.length - 22; i >= 0 && i >= zip.length - 22 - 0xFFFF; i--) {
    if (u32(i) == 0x06054b50) {
      end = i;
      break;
    }
  }
  if (end < 0) throw const FormatException('Not a zip file');
  final out = <String, Uint8List>{};
  var at = u32(end + 16);
  for (var n = u16(end + 10); n > 0; n--) {
    if (u32(at) != 0x02014b50) throw const FormatException('Bad zip directory');
    final method = u16(at + 10);
    final size = u32(at + 20);
    final nameLength = u16(at + 28);
    final local = u32(at + 42);
    final name = utf8.decode(zip.sublist(at + 46, at + 46 + nameLength));
    at += 46 + nameLength + u16(at + 30) + u16(at + 32);
    if (!wanted.contains(name)) continue;
    final start = local + 30 + u16(local + 26) + u16(local + 28);
    final raw = Uint8List.sublistView(zip, start, start + size);
    out[name] = switch (method) {
      0 => Uint8List.fromList(raw),
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(raw)),
      _ => throw FormatException('Unsupported zip compression $method'),
    };
  }
  return out;
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

/// An album on MusicBrainz whose cover may be the one for a song.
typedef CoverChoice = ({String id, String title});

/// Albums whose cover may be [song]'s, found on MusicBrainz by album and
/// artist, then by the song's title; best matches first. Throws when
/// MusicBrainz cannot be reached.
Future<List<CoverChoice>> findCovers(Song song) async {
  // Without the artist, a title search matches too many other records.
  if (song.artist == 'Unknown artist') return const [];
  final artist = 'artist:"${_phrase(song.artist)}"';
  final albumArtist = 'artist:"${_phrase(song.albumArtist)}"';
  final searches = [
    if (song.album != 'Unknown album')
      (
        'release-group',
        'releasegroup:"${_phrase(song.album)}" AND $albumArtist',
      ),
    ('recording', 'recording:"${_phrase(song.title)}" AND $artist'),
  ];
  final choices = <String, CoverChoice>{};
  for (final (i, (entity, query)) in searches.indexed) {
    // MusicBrainz allows one request per second.
    if (i > 0) await Future<void>.delayed(const Duration(seconds: 1));
    final found = await _get(
      Uri.https('musicbrainz.org', '/ws/2/$entity/', {
        'query': query,
        'fmt': 'json',
        'limit': '5',
      }),
    );
    for (final choice in releaseGroups(jsonDecode(utf8.decode(found)))) {
      choices.putIfAbsent(choice.id, () => choice);
    }
  }
  return choices.values.take(8).toList();
}

/// The front cover of [id] on the Cover Art Archive, [size] pixels wide.
Uri coverUrl(String id, {int size = 500}) =>
    Uri.https('coverartarchive.org', '/release-group/$id/front-$size');

/// Throws [HttpException] when that album has no front cover.
Future<Uint8List> downloadCover(String id) => _get(coverUrl(id));

/// [text] inside a quoted MusicBrainz (Lucene) phrase.
String _phrase(String text) =>
    text.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// Release groups in a MusicBrainz release-group or recording search that
/// score 90 or more, in order, each once.
List<CoverChoice> releaseGroups(Object? json) {
  if (json is! Map<String, dynamic>) return const [];
  final found = <String, CoverChoice>{};
  void add(Object? group) {
    if (group case {'id': final String id, 'title': final String title}) {
      found.putIfAbsent(id, () => (id: id, title: title));
    }
  }

  for (final group in json['release-groups'] as List<dynamic>? ?? const []) {
    if (group case {'score': final int score} when score >= 90) add(group);
  }
  for (final recording in json['recordings'] as List<dynamic>? ?? const []) {
    if (recording
        case {
          'score': final int score,
          'releases': final List<dynamic> releases,
        }
        when score >= 90) {
      for (final release in releases) {
        if (release case {'release-group': final group}) add(group);
      }
    }
  }
  return found.values.toList();
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
