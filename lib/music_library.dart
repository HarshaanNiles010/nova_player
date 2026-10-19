import 'dart:io';

import 'package:flutter/services.dart';

import 'song.dart';

class MusicLibrary {
  static const _channel = MethodChannel('com.novaplayer/music_library');
  // shortcut: FIFO cap of small thumbnails, switch to an LRU if eviction churn shows.
  static const _thumbnailCacheLimit = 400;
  static final _thumbnails = <String, Future<Uint8List?>>{};

  Future<List<Song>> loadSongs() async {
    final result = await _channel.invokeMethod<List<dynamic>>('getSongs') ?? [];
    return result
        .map((item) => Song.fromMap(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false);
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

  /// Downscaled artwork of at least [size] pixels, cached across rebuilds.
  Future<Uint8List?> loadThumbnail(Uri uri, int size) {
    final key = '$uri@$size';
    final cached = _thumbnails[key];
    if (cached != null) return cached;
    if (_thumbnails.length >= _thumbnailCacheLimit) {
      _thumbnails.remove(_thumbnails.keys.first);
    }
    return _thumbnails[key] = _channel
        .invokeMethod<Uint8List>('getArtwork', {
          'uri': uri.toString(),
          'size': size,
        })
        .catchError((Object _) => null);
  }
}
