import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'song.dart';

/// One listening session of a song. Song details are copied in so stats
/// survive songs being renamed, re-indexed or deleted.
class PlayRecord {
  const PlayRecord({
    required this.start,
    required this.songId,
    required this.fileName,
    required this.title,
    required this.artist,
    required this.album,
    required this.genre,
    required this.listenedMs,
    required this.lengthMs,
  });

  factory PlayRecord.of(Song song, DateTime start, int listenedMs) =>
      PlayRecord(
        start: start,
        songId: song.id,
        fileName: song.fileName,
        title: song.title,
        artist: song.artist,
        album: song.album,
        genre: song.genre,
        listenedMs: listenedMs,
        lengthMs: song.duration.inMilliseconds,
      );

  factory PlayRecord.fromJson(Map<String, dynamic> json) => PlayRecord(
    start: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
    songId: json['id'] as String,
    fileName: json['f'] as String,
    title: json['ti'] as String,
    artist: json['ar'] as String,
    album: json['al'] as String,
    genre: json['g'] as String,
    listenedMs: json['ms'] as int,
    lengthMs: json['len'] as int,
  );

  final DateTime start;
  final String songId;
  final String fileName;
  final String title;
  final String artist;
  final String album;
  final String genre;
  final int listenedMs;
  final int lengthMs;

  /// Spotify's rule: a play counts after 30 s, or half of a shorter song.
  bool get countsAsPlay {
    final threshold = lengthMs > 0 && lengthMs < 60000 ? lengthMs ~/ 2 : 30000;
    return listenedMs >= threshold;
  }

  /// Identifies the song across re-indexing: file name, else MediaStore id.
  String get songKey => fileName.isNotEmpty ? fileName : songId;

  Map<String, Object> toJson() => {
    't': start.millisecondsSinceEpoch,
    'id': songId,
    'f': fileName,
    'ti': title,
    'ar': artist,
    'al': album,
    'g': genre,
    'ms': listenedMs,
    'len': lengthMs,
  };
}

/// Append-only log of [PlayRecord]s, one JSON object per line in the app's
/// private files folder.
class ListeningHistory {
  ListeningHistory._();

  static final instance = ListeningHistory._();

  static const _channel = MethodChannel('com.novaplayer/music_library');
  static const _pendingKey = 'listening_pending';

  Future<File>? _file;
  Future<void> _writes = Future.value();

  Future<File> _logFile() => _file ??= _channel
      .invokeMethod<String>('getFilesDir')
      .then((dir) => File('$dir/listening_history.jsonl'));

  /// Serialises writes so concurrent appends never interleave.
  Future<void> _enqueue(Future<void> Function() write) =>
      _writes = _writes.then((_) => write()).catchError((Object _) {});

  Future<void> append(PlayRecord record) => _enqueue(() async {
    await (await _logFile()).writeAsString(
      '${jsonEncode(record)}\n',
      mode: FileMode.append,
      flush: true,
    );
  });

  /// Saves the session in progress so a killed app loses at most one checkpoint.
  Future<void> savePending(PlayRecord? record) => _enqueue(() async {
    final prefs = await SharedPreferences.getInstance();
    if (record == null) {
      await prefs.remove(_pendingKey);
    } else {
      await prefs.setString(_pendingKey, jsonEncode(record));
    }
  });

  /// Moves a session left over from a killed app into the log.
  Future<void> recoverPending() async {
    final raw = (await SharedPreferences.getInstance()).getString(_pendingKey);
    if (raw == null) return;
    await append(PlayRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>));
    await savePending(null);
  }

  /// The whole log as text, for a backup.
  Future<String> exportText() async {
    await _writes;
    final file = await _logFile();
    return await file.exists() ? file.readAsString() : '';
  }

  /// Replaces the log with [text] from a backup.
  Future<void> importText(String text) =>
      _enqueue(() async => (await _logFile()).writeAsString(text, flush: true));

  Future<List<PlayRecord>> load() async {
    await _writes;
    final file = await _logFile();
    if (!await file.exists()) return const [];
    return parseHistory(await file.readAsString());
  }
}

/// Parses the log, skipping a line cut short by a crash mid-write.
List<PlayRecord> parseHistory(String text) => [
  for (final line in const LineSplitter().convert(text))
    if (line.trim().isNotEmpty) ?_tryParse(line),
];

PlayRecord? _tryParse(String line) {
  try {
    return PlayRecord.fromJson(jsonDecode(line) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}
