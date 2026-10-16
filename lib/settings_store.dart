import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'group_by.dart';
import 'queue_mode.dart';

class SettingsStore {
  static const _queueModeKey = 'queue_mode';
  static const _queueKey = 'queue';
  static const _nowPlayingKey = 'now_playing';
  static const _positionKey = 'position_ms';
  static const _shuffleKey = 'shuffle';
  static const _themeIdKey = 'theme_id';
  static const _themeModeKey = 'theme_mode';
  static const _fontIdKey = 'font_id';
  static const _groupByKey = 'group_by';
  static const _textScaleKey = 'text_scale';
  static const _downloadedThemesKey = 'downloaded_themes';
  static const _downloadedFontsKey = 'downloaded_fonts';

  /// Each entry is one theme as JSON.
  Future<List<String>> loadDownloadedThemes() async =>
      (await SharedPreferences.getInstance()).getStringList(
        _downloadedThemesKey,
      ) ??
      [];

  Future<void> saveDownloadedThemes(List<String> themes) async {
    await (await SharedPreferences.getInstance()).setStringList(
      _downloadedThemesKey,
      themes,
    );
  }

  /// Google Fonts family names.
  Future<List<String>> loadDownloadedFonts() async =>
      (await SharedPreferences.getInstance()).getStringList(
        _downloadedFontsKey,
      ) ??
      [];

  Future<void> saveDownloadedFonts(List<String> names) async {
    await (await SharedPreferences.getInstance()).setStringList(
      _downloadedFontsKey,
      names,
    );
  }

  Future<QueueMode> loadQueueMode() async {
    final value = (await SharedPreferences.getInstance()).getString(
      _queueModeKey,
    );
    return QueueMode.values.where((mode) => mode.name == value).firstOrNull ??
        QueueMode.spotify;
  }

  /// Song ids still waiting in the queue.
  Future<List<String>> loadQueue() async =>
      (await SharedPreferences.getInstance()).getStringList(_queueKey) ?? [];

  Future<void> saveQueue(List<String> songIds) async {
    await (await SharedPreferences.getInstance()).setStringList(
      _queueKey,
      songIds,
    );
  }

  /// The song that was playing and how far into it, from the last session.
  Future<(String?, Duration)> loadNowPlaying() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getString(_nowPlayingKey),
      Duration(milliseconds: prefs.getInt(_positionKey) ?? 0),
    );
  }

  Future<void> saveNowPlaying(String songId, Duration position) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nowPlayingKey, songId);
    await prefs.setInt(_positionKey, position.inMilliseconds);
  }

  Future<bool> loadShuffle() async =>
      (await SharedPreferences.getInstance()).getBool(_shuffleKey) ?? false;

  Future<void> saveShuffle(bool enabled) async {
    await (await SharedPreferences.getInstance()).setBool(_shuffleKey, enabled);
  }

  Future<void> saveQueueMode(QueueMode mode) async {
    await (await SharedPreferences.getInstance()).setString(
      _queueModeKey,
      mode.name,
    );
  }

  Future<String?> loadThemeId() async {
    return (await SharedPreferences.getInstance()).getString(_themeIdKey);
  }

  Future<void> saveThemeId(String id) async {
    await (await SharedPreferences.getInstance()).setString(_themeIdKey, id);
  }

  Future<GroupBy> loadGroupBy() async {
    final value = (await SharedPreferences.getInstance()).getString(
      _groupByKey,
    );
    return GroupBy.values.where((group) => group.name == value).firstOrNull ??
        GroupBy.none;
  }

  Future<void> saveGroupBy(GroupBy group) async {
    await (await SharedPreferences.getInstance()).setString(
      _groupByKey,
      group.name,
    );
  }

  Future<String?> loadFontId() async {
    return (await SharedPreferences.getInstance()).getString(_fontIdKey);
  }

  Future<void> saveFontId(String id) async {
    await (await SharedPreferences.getInstance()).setString(_fontIdKey, id);
  }

  Future<double?> loadTextScale() async {
    return (await SharedPreferences.getInstance()).getDouble(_textScaleKey);
  }

  Future<void> saveTextScale(double scale) async {
    await (await SharedPreferences.getInstance()).setDouble(
      _textScaleKey,
      scale,
    );
  }

  Future<ThemeMode> loadThemeMode() async {
    final value = (await SharedPreferences.getInstance()).getString(
      _themeModeKey,
    );
    return ThemeMode.values.where((mode) => mode.name == value).firstOrNull ??
        ThemeMode.system;
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    await (await SharedPreferences.getInstance()).setString(
      _themeModeKey,
      mode.name,
    );
  }
}
