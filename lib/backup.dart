import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'listening_history.dart';

const _formatKey = 'nova_backup';
const _formatVersion = 1;

/// Every setting (playlists, smart playlists, favourites, themes, queue...)
/// plus the listening history, as one JSON text.
Future<String> createBackup() async {
  final prefs = await SharedPreferences.getInstance();
  return encodeBackup({
    for (final key in prefs.getKeys()) key: prefs.get(key)!,
  }, await ListeningHistory.instance.exportText());
}

String encodeBackup(Map<String, Object> settings, String history) => jsonEncode(
  {_formatKey: _formatVersion, 'settings': settings, 'history': history},
);

/// Reads a backup made by [encodeBackup]; throws [FormatException] for any
/// other file, so a wrong pick never overwrites the user's data.
({Map<String, Object> settings, String history}) decodeBackup(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const FormatException('Not a Nova backup');
  }
  if (json is! Map<String, dynamic> ||
      json[_formatKey] != _formatVersion ||
      json['settings'] is! Map<String, dynamic> ||
      json['history'] is! String) {
    throw const FormatException('Not a Nova backup');
  }
  final settings = <String, Object>{};
  for (final MapEntry(:key, :value)
      in (json['settings'] as Map<String, dynamic>).entries) {
    settings[key] = switch (value) {
      final String v => v,
      final bool v => v,
      final int v => v,
      final double v => v,
      final List<dynamic> v when v.every((e) => e is String) =>
        v.cast<String>().toList(),
      _ => throw FormatException('Bad value for $key'),
    };
  }
  return (settings: settings, history: json['history'] as String);
}

/// Replaces all settings and the listening history with [text]'s.
Future<void> restoreBackup(String text) async {
  final backup = decodeBackup(text);
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  for (final MapEntry(:key, :value) in backup.settings.entries) {
    switch (value) {
      case final String v:
        await prefs.setString(key, v);
      case final bool v:
        await prefs.setBool(key, v);
      case final int v:
        await prefs.setInt(key, v);
      case final double v:
        await prefs.setDouble(key, v);
      case final List<String> v:
        await prefs.setStringList(key, v);
    }
  }
  await ListeningHistory.instance.importText(backup.history);
}
