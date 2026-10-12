import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'group_by.dart';
import 'queue_mode.dart';

class SettingsStore {
  static const _queueModeKey = 'queue_mode';
  static const _themeIdKey = 'theme_id';
  static const _themeModeKey = 'theme_mode';
  static const _fontIdKey = 'font_id';
  static const _groupByKey = 'group_by';
  static const _textScaleKey = 'text_scale';

  Future<QueueMode> loadQueueMode() async {
    final value = (await SharedPreferences.getInstance()).getString(
      _queueModeKey,
    );
    return QueueMode.values.where((mode) => mode.name == value).firstOrNull ??
        QueueMode.spotify;
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
