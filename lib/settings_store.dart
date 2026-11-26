import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'group_by.dart';
import 'queue_mode.dart';
import 'replay_gain.dart';
import 'search_bar_style.dart';
import 'look.dart';
import 'smart_shuffle.dart';
import 'song.dart';
import 'song_sort.dart';

class SettingsStore {
  static const _queueModeKey = 'queue_mode';
  static const _queueKey = 'queue';
  static const _nowPlayingKey = 'now_playing';
  static const _positionKey = 'position_ms';
  static const _shuffleKey = 'shuffle';
  static const _hiddenKey = 'hidden_songs';
  static const _themeIdKey = 'theme_id';
  static const _themeModeKey = 'theme_mode';
  static const _fontIdKey = 'font_id';
  static const _groupByKey = 'group_by';
  static const _levellingKey = 'levelling';
  static const _smartShuffleKey = 'smart_shuffle';
  static const _smartShuffleRulesKey = 'smart_shuffle_rules';
  static const _songSortKey = 'song_sort';
  static const _searchBarStyleKey = 'search_bar_style';
  static const _lookKey = 'look';
  static const _textScaleKey = 'text_scale';
  static const _downloadedThemesKey = 'downloaded_themes';
  static const _downloadedFontsKey = 'downloaded_fonts';
  static const _eqEnabledKey = 'eq_enabled';
  static const _eqGainsKey = 'eq_gains';
  static const _lyricsOffsetKey = 'lyrics_offset_';
  static const _tagEditsKey = 'tag_edits';
  static const _playbackKey = 'playback';

  /// Tags fixed in the app, by [tagEditKey]; the files are never changed.
  /// Speed, pitch and skip-silence; 1, 1 and off unless changed.
  Future<({double speed, double pitch, bool skipSilence})>
  loadPlayback() async {
    final saved =
        (await SharedPreferences.getInstance()).getStringList(_playbackKey) ??
        const [];
    double number(int i) =>
        (i < saved.length ? double.tryParse(saved[i]) : null)?.clamp(
          0.5,
          2.0,
        ) ??
        1.0;
    return (
      speed: number(0),
      pitch: number(1),
      skipSilence: saved.length > 2 && saved[2] == 'true',
    );
  }

  Future<void> savePlayback({
    required double speed,
    required double pitch,
    required bool skipSilence,
  }) async {
    await (await SharedPreferences.getInstance()).setStringList(_playbackKey, [
      '$speed',
      '$pitch',
      '$skipSilence',
    ]);
  }

  Future<Map<String, Map<String, String>>> loadTagEdits() async {
    final json = (await SharedPreferences.getInstance()).getString(
      _tagEditsKey,
    );
    if (json == null) return {};
    return {
      for (final MapEntry(:key, :value)
          in (jsonDecode(json) as Map<String, dynamic>).entries)
        key: Map<String, String>.from(value as Map),
    };
  }

  Future<void> saveTagEdits(Map<String, Map<String, String>> edits) async =>
      (await SharedPreferences.getInstance()).setString(
        _tagEditsKey,
        jsonEncode(edits),
      );

  /// How much later than their timestamps [song]'s lyrics are shown.
  Future<Duration> loadLyricsOffset(Song song) async => Duration(
    milliseconds:
        (await SharedPreferences.getInstance()).getInt(
          '$_lyricsOffsetKey${song.key}',
        ) ??
        0,
  );

  Future<void> saveLyricsOffset(Song song, Duration offset) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_lyricsOffsetKey${song.key}';
    offset == Duration.zero
        ? await prefs.remove(key)
        : await prefs.setInt(key, offset.inMilliseconds);
  }

  /// Whether the equalizer is on, and each band's gain in dB.
  Future<(bool, List<double>)> loadEqualizer() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getBool(_eqEnabledKey) ?? false,
      [
        for (final gain in prefs.getStringList(_eqGainsKey) ?? <String>[])
          double.tryParse(gain) ?? 0,
      ],
    );
  }

  Future<void> saveEqualizer(bool enabled, List<double> gains) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_eqEnabledKey, enabled);
    await prefs.setStringList(_eqGainsKey, [for (final gain in gains) '$gain']);
  }

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

  /// Uris of songs hidden from the library, like extra copies.
  Future<Set<String>> loadHidden() async =>
      ((await SharedPreferences.getInstance()).getStringList(_hiddenKey) ?? [])
          .toSet();

  Future<void> saveHidden(Set<String> uris) async {
    await (await SharedPreferences.getInstance()).setStringList(
      _hiddenKey,
      uris.toList(),
    );
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

  Future<SearchBarStyle> loadSearchBarStyle() async {
    final value = (await SharedPreferences.getInstance()).getString(
      _searchBarStyleKey,
    );
    return SearchBarStyle.values
            .where((style) => style.name == value)
            .firstOrNull ??
        SearchBarStyle.banner;
  }

  /// Look-and-feel options; the older search bar setting carries over.
  Future<LookOptions> loadLook() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_lookKey);
    if (saved != null) return LookOptions.fromJson(saved);
    return const LookOptions().withValue(await loadSearchBarStyle());
  }

  Future<void> saveLook(LookOptions options) async {
    await (await SharedPreferences.getInstance()).setString(
      _lookKey,
      options.toJson(),
    );
  }

  Future<SongSort> loadSongSort() async {
    final value = (await SharedPreferences.getInstance()).getString(
      _songSortKey,
    );
    return SongSort.values.where((sort) => sort.name == value).firstOrNull ??
        SongSort.title;
  }

  Future<void> saveSongSort(SongSort sort) async {
    await (await SharedPreferences.getInstance()).setString(
      _songSortKey,
      sort.name,
    );
  }

  Future<LevellingMode> loadLevelling() async {
    final value = (await SharedPreferences.getInstance()).getString(
      _levellingKey,
    );
    return LevellingMode.values
            .where((mode) => mode.name == value)
            .firstOrNull ??
        LevellingMode.off;
  }

  Future<void> saveLevelling(LevellingMode mode) async {
    await (await SharedPreferences.getInstance()).setString(
      _levellingKey,
      mode.name,
    );
  }

  Future<SmartShuffle> loadSmartShuffle() async {
    final prefs = await SharedPreferences.getInstance();
    final rules = prefs.getStringList(_smartShuffleRulesKey);
    return SmartShuffle(
      enabled: prefs.getBool(_smartShuffleKey) ?? false,
      rules: rules == null
          ? SmartShuffleRule.values.toSet()
          : {
              for (final rule in SmartShuffleRule.values)
                if (rules.contains(rule.name)) rule,
            },
    );
  }

  Future<void> saveSmartShuffle(SmartShuffle shuffle) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smartShuffleKey, shuffle.enabled);
    await prefs.setStringList(_smartShuffleRulesKey, [
      for (final rule in shuffle.rules) rule.name,
    ]);
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
