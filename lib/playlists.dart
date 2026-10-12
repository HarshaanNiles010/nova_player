import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'song.dart';

/// A playlist entry: the MediaStore id plus the file name, so songs survive
/// Android re-indexing (which changes ids) or moving the file.
@immutable
class PlaylistEntry {
  const PlaylistEntry(this.id, this.fileName);

  factory PlaylistEntry.of(Song song) => PlaylistEntry(song.id, song.fileName);

  /// Accepts the old format (a bare id string) and the current {id, file} map.
  factory PlaylistEntry.fromJson(Object? json) => switch (json) {
    final String id => PlaylistEntry(id, ''),
    final Map<String, dynamic> map => PlaylistEntry(
      map['id']?.toString() ?? '',
      map['file']?.toString() ?? '',
    ),
    _ => const PlaylistEntry('', ''),
  };

  final String id;
  final String fileName;

  Map<String, String> toJson() => {'id': id, 'file': fileName};

  bool matches(Song song) =>
      song.id == id || (fileName.isNotEmpty && song.fileName == fileName);
}

/// Playlists as name -> entries, saved in shared preferences.
class PlaylistStore extends ChangeNotifier {
  PlaylistStore._();

  // shortcut: one app-wide store; inject it if playlists ever need isolation in tests.
  static final instance = PlaylistStore._().._load();

  static const _key = 'playlists';
  Map<String, List<PlaylistEntry>> _playlists = {};

  /// Restores saved playlists from [json]; exposed for tests.
  @visibleForTesting
  void restore(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    _playlists = decoded.map(
      (name, entries) => MapEntry(
        name,
        (entries as List).map(PlaylistEntry.fromJson).toList(),
      ),
    );
    notifyListeners();
  }

  List<String> get names =>
      _playlists.keys.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  int lengthOf(String name) => _playlists[name]?.length ?? 0;

  bool contains(String name, Song song) =>
      _playlists[name]?.any((entry) => entry.matches(song)) ?? false;

  /// Songs of [name] in playlist order: matched by id first, then file name.
  /// Entries whose file is gone from [library] are skipped.
  List<Song> songsOf(String name, List<Song> library) {
    final byId = {for (final song in library) song.id: song};
    final byFile = <String, Song>{};
    for (final song in library) {
      byFile.putIfAbsent(song.fileName, () => song);
    }
    return [
      for (final entry in _playlists[name] ?? const <PlaylistEntry>[])
        ?(byId[entry.id] ?? byFile[entry.fileName]),
    ];
  }

  Future<void> _load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw != null) restore(raw);
  }

  Future<void> _save() async {
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(_playlists),
    );
  }

  Future<void> add(String name, Song song) async {
    final entries = _playlists.putIfAbsent(name, () => []);
    if (!entries.any((entry) => entry.matches(song))) {
      entries.add(PlaylistEntry.of(song));
    }
    await _save();
  }

  /// Saves [songs] as [name], replacing a playlist of that name.
  Future<void> replace(String name, List<Song> songs) async {
    _playlists[name] = songs.map(PlaylistEntry.of).toList();
    await _save();
  }

  Future<void> remove(String name, Song song) async {
    _playlists[name]?.removeWhere((entry) => entry.matches(song));
    await _save();
  }

  Future<void> delete(String name) async {
    _playlists.remove(name);
    await _save();
  }
}
