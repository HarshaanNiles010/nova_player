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

  static final _lyrics = <String, Future<String?>>{};

  /// Lyrics text (often LRC): embedded in the file, else a matching .lrc in
  /// the lyrics folder. Cached per song for this session.
  Future<String?> loadLyrics(Song song) => _lyrics[song.id] ??= _channel
      .invokeMethod<String>('getLyrics', {
        'uri': song.uri.toString(),
        'fileName': song.fileName,
      })
      .catchError((Object _) => null);

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
