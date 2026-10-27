import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'settings_store.dart';
import 'song.dart';

class MusicLibrary {
  static const _channel = MethodChannel('com.novaplayer/music_library');
  // shortcut: FIFO cap of small thumbnails, switch to an LRU if eviction churn shows.
  static const _thumbnailCacheLimit = 400;
  static final _thumbnails = <String, Future<Uint8List?>>{};

  /// Bumped when a cover is saved or removed, so artwork on screen reloads.
  static final artworkChanged = ValueNotifier(0);

  /// Saved covers by lower-case song name, as content:// or file:// URIs.
  static var _covers = const <String, String>{};

  /// [song]'s saved cover, for the notification; null when it has none.
  static Uri? coverUri(Song song) {
    final uri = _covers[_base(song).toLowerCase()];
    return uri == null ? null : Uri.parse(uri);
  }

  static bool hasCover(Song song) => coverUri(song) != null;

  Future<void> _loadCovers() async {
    final found = await _channel
        .invokeMapMethod<String, String>('getCovers')
        .catchError((Object _) => null);
    _covers = found ?? const {};
  }

  /// Bumped when tags are edited or files trashed, so the library reloads.
  static final libraryChanged = ValueNotifier(0);

  /// Title, artist and album fixed in the app, applied over the files' tags.
  static var _tagEdits = <String, Map<String, String>>{};

  static String _tagKeyOf(Song song) =>
      tagEditKey({'path': song.path, 'uri': song.uri});

  static bool hasEditedTags(Song song) =>
      _tagEdits.containsKey(_tagKeyOf(song));

  /// Saves [changes] (by [Song.fromMap] key, like 'album') over each of
  /// [songs]' earlier edits; null goes back to the files' own tags.
  Future<void> editTags(List<Song> songs, Map<String, String>? changes) async {
    for (final song in songs) {
      final key = _tagKeyOf(song);
      changes == null
          ? _tagEdits.remove(key)
          : _tagEdits[key] = {...?_tagEdits[key], ...changes};
    }
    await SettingsStore().saveTagEdits(_tagEdits);
    libraryChanged.value++;
  }

  Future<List<Song>> loadSongs() async {
    await _loadCovers();
    _tagEdits = await SettingsStore().loadTagEdits();
    final result = await _channel.invokeMethod<List<dynamic>>('getSongs') ?? [];
    final maps = result.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return {...map, ...?_tagEdits[tagEditKey(map)]};
    }).toList();
    return borrowArtistGenres(maps).map(Song.fromMap).toList(growable: false);
  }

  /// Extra folders scanned directly, as (uri, readable name).
  Future<List<({String uri, String name})>> musicFolders() async {
    final result =
        await _channel.invokeMethod<List<dynamic>>('getMusicFolders') ?? [];
    return [
      for (final item in result.cast<Map<dynamic, dynamic>>())
        (uri: item['uri'] as String, name: item['name'] as String),
    ];
  }

  /// Opens the system folder picker; true when a folder was added.
  Future<bool> addMusicFolder() async =>
      await _channel.invokeMethod<bool>('addMusicFolder') ?? false;

  Future<void> removeMusicFolder(String uri) =>
      _channel.invokeMethod<void>('removeMusicFolder', {'uri': uri});

  /// Has Android re-index all storage; call [loadSongs] afterwards.
  Future<void> rescanStorage() => _channel.invokeMethod<void>('rescanStorage');

  /// Moves the files of [songs] to the phone's trash after it asks the
  /// user, or with [restore] brings them back; false when they say no.
  /// Android deletes trashed files for good after 30 days.
  Future<bool> trashSongs(List<Song> songs, {bool restore = false}) async {
    final done =
        await _channel.invokeMethod<bool>('trashSongs', {
          'uris': [for (final song in songs) song.uri.toString()],
          'trash': !restore,
        }) ??
        false;
    if (done) libraryChanged.value++;
    return done;
  }

  /// Lets the user pick where to save [text]; false when cancelled.
  Future<bool> saveTextFile(String name, String mimeType, String text) async =>
      await _channel.invokeMethod<String>('saveTextFile', {
        'name': name,
        'mimeType': mimeType,
        'text': text,
      }) !=
      null;

  /// Lets the user pick a file and returns its text; null when cancelled.
  Future<String?> openTextFile() =>
      _channel.invokeMethod<String>('openTextFile');

  /// Closes and reopens the app, so restored settings load from scratch.
  Future<void> restartApp() => _channel.invokeMethod<void>('restartApp');

  static final _lyrics = <String, Future<String?>>{};

  /// Lyrics text (often LRC): embedded in the file, else a matching .lrc in
  /// the lyrics folder, else downloaded ones. Cached per song for this session.
  Future<String?> loadLyrics(Song song) => _lyrics[song.id] ??= _channel
      .invokeMethod<String>('getLyrics', {
        'uri': song.uri.toString(),
        'fileName': song.fileName,
      })
      .catchError((Object _) => null)
      .then(
        (found) async => found ?? await _readAppLyrics('${_base(song)}.lrc'),
      );

  /// Saves downloaded lyrics as "Song.lrc" for "Song.flac"; see [_store].
  Future<void> saveDownloadedLyrics(Song song, String lyrics) async {
    await _store(song, '${_base(song)}.lrc', lyrics);
    _lyrics[song.id] = Future.value(lyrics);
  }

  /// A saved English translation ("Song.en.lrc"), or null.
  Future<String?> loadStoredTranslation(Song song) async =>
      await _channel
          .invokeMethod<String>('getStoredTranslation', {
            'fileName': song.fileName,
          })
          .catchError((Object _) => null) ??
      await _readAppLyrics('${_base(song)}.en.lrc');

  Future<void> saveTranslation(Song song, String lrc) =>
      _store(song, '${_base(song)}.en.lrc', lrc);

  /// Into the lyrics folder, next to the song when it is inside it, so the
  /// lyrics stay with the music; else in the app's storage.
  Future<void> _store(Song song, String name, String text) async {
    final saved = await _channel
        .invokeMethod<bool>('saveLyrics', {
          'path': song.path,
          'name': name,
          'text': text,
        })
        .catchError((Object _) => false);
    if (saved ?? false) return;
    final file = await _appLyrics(name);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<String?> _readAppLyrics(String name) async {
    final file = await _appLyrics(name);
    return await file.exists() ? file.readAsString() : null;
  }

  Future<File> _appLyrics(String name) async {
    final files = await _channel.invokeMethod<String>('getFilesDir');
    return File('$files/lyrics/$name');
  }

  // shortcut: keyed by file name like the lyrics folder, so two different
  // songs with the same file name share lyrics; key by song id if that bites.
  static String _base(Song song) {
    final name = song.fileName.contains('.')
        ? song.fileName.substring(0, song.fileName.lastIndexOf('.'))
        : song.fileName;
    return name.replaceAll('/', '_');
  }

  /// Name of the picked .lrc folder, or null when none is set.
  Future<String?> lyricsFolder() => _channel
      .invokeMethod<String>('getLyricsFolder')
      .catchError((Object _) => null);

  /// Opens the system folder picker; returns the folder now in use.
  Future<String?> pickLyricsFolder() async {
    final folder = await _channel.invokeMethod<String>('pickLyricsFolder');
    _lyrics.clear(); // songs without lyrics may have some now
    return folder;
  }

  Future<void> clearLyricsFolder() async {
    await _channel.invokeMethod<void>('clearLyricsFolder');
    _lyrics.clear();
  }

  /// Saves a downloaded cover as "Song.jpg" for "Song.flac", next to the song
  /// like lyrics (see [_store]); it then shows instead of the embedded one.
  Future<void> saveCover(Song song, Uint8List bytes) async {
    final name = '${_base(song)}.jpg';
    final saved = await _channel
        .invokeMethod<bool>('saveCover', {
          'path': song.path,
          'name': name,
          'bytes': bytes,
        })
        .catchError((Object _) => false);
    if (!(saved ?? false)) {
      final files = await _channel.invokeMethod<String>('getFilesDir');
      final file = File('$files/covers/$name');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }
    await _coverChanged(song);
  }

  /// Deletes [song]'s saved cover, so the art inside the file shows again.
  Future<void> removeCover(Song song) async {
    final name = '${_base(song)}.jpg';
    await _channel
        .invokeMethod<bool>('deleteCover', {'name': name})
        .catchError((Object _) => false);
    final file = File(
      '${await _channel.invokeMethod<String>('getFilesDir')}/covers/$name',
    );
    if (await file.exists()) await file.delete();
    await _coverChanged(song);
  }

  Future<void> _coverChanged(Song song) async {
    await _loadCovers();
    _thumbnails.removeWhere((key, _) => key.startsWith('${song.uri}@'));
    artworkChanged.value++;
  }

  /// Downscaled artwork of at least [size] pixels, cached across rebuilds:
  /// a saved cover, else the one in the file.
  Future<Uint8List?> loadThumbnail(Song song, int size) {
    final key = '${song.uri}@$size';
    final cached = _thumbnails[key];
    if (cached != null) return cached;
    if (_thumbnails.length >= _thumbnailCacheLimit) {
      _thumbnails.remove(_thumbnails.keys.first);
    }
    return _thumbnails[key] = _channel
        .invokeMethod<Uint8List>('getArtwork', {
          'uri': song.uri.toString(),
          'fileName': song.fileName,
          'size': size,
        })
        .catchError((Object _) => null);
  }
}

/// Songs without a genre tag take the most common genre among their artist's
/// other songs, so fewer land in "Unknown genre". The files are not changed.
List<Map<String, dynamic>> borrowArtistGenres(List<Map<String, dynamic>> maps) {
  String? genreOf(Map<String, dynamic> map) => switch (map['genre']
      ?.toString()
      .trim()) {
    final String genre when genre.isNotEmpty && genre != '<unknown>' => genre,
    _ => null,
  };
  final counts = <Object?, Map<String, int>>{};
  for (final map in maps) {
    if (genreOf(map) case final genre?) {
      final artist = counts.putIfAbsent(map['artist'], () => {});
      artist[genre] = (artist[genre] ?? 0) + 1;
    }
  }
  return [
    for (final map in maps)
      if (genreOf(map) == null && counts[map['artist']] != null)
        {
          ...map,
          'genre': counts[map['artist']]!.entries
              .reduce((a, b) => b.value > a.value ? b : a)
              .key,
        }
      else
        map,
  ];
}
