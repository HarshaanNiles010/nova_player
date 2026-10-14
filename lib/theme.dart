import 'dart:convert';

import 'package:flutter/material.dart';

import 'downloads.dart';
import 'settings_store.dart';

class AppThemePreset {
  const AppThemePreset({
    required this.id,
    required this.name,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.foreground,
    required this.primary,
    required this.secondary,
  });

  /// Colors are "#RRGGBB" strings, as in themes/catalog.json.
  factory AppThemePreset.fromJson(Map<String, dynamic> json) {
    Color color(String key) {
      final hex = (json[key] as String).replaceFirst('#', '');
      if (hex.length != 6) throw FormatException('Bad color $key: $hex');
      return Color(0xFF000000 | int.parse(hex, radix: 16));
    }

    return AppThemePreset(
      id: json['id'] as String,
      name: json['name'] as String,
      brightness: json['brightness'] == 'light'
          ? Brightness.light
          : Brightness.dark,
      background: color('background'),
      surface: color('surface'),
      foreground: color('foreground'),
      primary: color('primary'),
      secondary: color('secondary'),
    );
  }

  Map<String, dynamic> toJson() {
    String hex(Color color) =>
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return {
      'id': id,
      'name': name,
      'brightness': brightness.name,
      'background': hex(background),
      'surface': hex(surface),
      'foreground': hex(foreground),
      'primary': hex(primary),
      'secondary': hex(secondary),
    };
  }

  final String id;
  final String name;
  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color foreground;
  final Color primary;
  final Color secondary;
}

const appThemes = [
  // Inspired by games; the rest follow popular editor themes.
  AppThemePreset(
    id: 'outer_wilds',
    name: 'Outer Wilds',
    brightness: Brightness.dark,
    background: Color(0xFF0E1424), // deep space
    surface: Color(0xFF18203A),
    foreground: Color(0xFFE9E2D0),
    primary: Color(0xFFF28C28), // campfire
    secondary: Color(0xFF6FC3DF), // Nomai blue
  ),
  AppThemePreset(
    id: 'timber_hearth',
    name: 'Timber Hearth',
    brightness: Brightness.light,
    background: Color(0xFFEFE7D6),
    surface: Color(0xFFE3D6BC),
    foreground: Color(0xFF33352B),
    primary: Color(0xFFB4501A),
    secondary: Color(0xFF3E7C59), // pine
  ),
  AppThemePreset(
    id: 'rain_world',
    name: 'Rain World',
    brightness: Brightness.dark,
    background: Color(0xFF14181A), // rusted industry in the rain
    surface: Color(0xFF20272A),
    foreground: Color(0xFFDCE0DA), // slugcat white
    primary: Color(0xFFF2C14E), // overseer yellow
    secondary: Color(0xFFE8467C), // pink lizard
  ),
  AppThemePreset(
    id: 'five_pebbles',
    name: 'Five Pebbles',
    brightness: Brightness.dark,
    background: Color(0xFF170F22),
    surface: Color(0xFF241A33),
    foreground: Color(0xFFE6DDF2),
    primary: Color(0xFFB48CF2),
    secondary: Color(0xFF4FD1C5),
  ),
  AppThemePreset(
    id: 'hollow_knight',
    name: 'Hollow Knight',
    brightness: Brightness.dark,
    background: Color(0xFF0B0F1A),
    surface: Color(0xFF151B2B),
    foreground: Color(0xFFE6EEF5),
    primary: Color(0xFF9FC4E8), // soul
    secondary: Color(0xFFE3B866),
  ),
  AppThemePreset(
    id: 'celeste',
    name: 'Celeste',
    brightness: Brightness.dark,
    background: Color(0xFF1B1530),
    surface: Color(0xFF2A2145),
    foreground: Color(0xFFF2E9F7),
    primary: Color(0xFFE05A6E), // Madeline's hair
    secondary: Color(0xFF7FD3F0), // dash crystal
  ),
  AppThemePreset(
    id: 'minimalist',
    name: 'Minimalist',
    brightness: Brightness.light,
    background: Color(0xFFFAFAFA),
    surface: Color(0xFFFFFFFF),
    foreground: Color(0xFF151515),
    primary: Color(0xFF18181B),
    secondary: Color(0xFF71717A),
  ),
  AppThemePreset(
    id: 'amoled',
    name: 'AMOLED',
    brightness: Brightness.dark,
    background: Color(0xFF000000),
    surface: Color(0xFF0D0D0D),
    foreground: Color(0xFFF5F5F5),
    primary: Color(0xFFBB86FC),
    secondary: Color(0xFF03DAC6),
  ),
  AppThemePreset(
    id: 'nord',
    name: 'Nord',
    brightness: Brightness.dark,
    background: Color(0xFF2E3440),
    surface: Color(0xFF3B4252),
    foreground: Color(0xFFE5E9F0),
    primary: Color(0xFF81A1C1),
    secondary: Color(0xFFB48EAD),
  ),
  AppThemePreset(
    id: 'dracula',
    name: 'Dracula',
    brightness: Brightness.dark,
    background: Color(0xFF282A36),
    surface: Color(0xFF21222C),
    foreground: Color(0xFFF8F8F2),
    primary: Color(0xFFBD93F9),
    secondary: Color(0xFFFF79C6),
  ),
  AppThemePreset(
    id: 'gruvbox_dark',
    name: 'Gruvbox Dark',
    brightness: Brightness.dark,
    background: Color(0xFF1D2021),
    surface: Color(0xFF3C3836),
    foreground: Color(0xFFD5C4A1),
    primary: Color(0xFF83A598),
    secondary: Color(0xFFD3869B),
  ),
  AppThemePreset(
    id: 'gruvbox_light',
    name: 'Gruvbox Light',
    brightness: Brightness.light,
    background: Color(0xFFF9F5D7),
    surface: Color(0xFFEBDBB2),
    foreground: Color(0xFF504945),
    primary: Color(0xFF076678),
    secondary: Color(0xFF8F3F71),
  ),
  AppThemePreset(
    id: 'solarized_dark',
    name: 'Solarized Dark',
    brightness: Brightness.dark,
    background: Color(0xFF002B36),
    surface: Color(0xFF073642),
    foreground: Color(0xFF93A1A1),
    primary: Color(0xFF268BD2),
    secondary: Color(0xFF6C71C4),
  ),
  AppThemePreset(
    id: 'solarized_light',
    name: 'Solarized Light',
    brightness: Brightness.light,
    background: Color(0xFFFDF6E3),
    surface: Color(0xFFEEE8D5),
    foreground: Color(0xFF586E75),
    primary: Color(0xFF268BD2),
    secondary: Color(0xFF6C71C4),
  ),
  AppThemePreset(
    id: 'tokyo_dark',
    name: 'Tokyo Night',
    brightness: Brightness.dark,
    background: Color(0xFF1A1B26),
    surface: Color(0xFF16161E),
    foreground: Color(0xFFA9B1D6),
    primary: Color(0xFF2AC3DE),
    secondary: Color(0xFFBB9AF7),
  ),
  AppThemePreset(
    id: 'tokyo_light',
    name: 'Tokyo Day',
    brightness: Brightness.light,
    background: Color(0xFFD5D6DB),
    surface: Color(0xFFCBCCD1),
    foreground: Color(0xFF343B59),
    primary: Color(0xFF34548A),
    secondary: Color(0xFF5A4A78),
  ),
  AppThemePreset(
    id: 'onedark',
    name: 'OneDark',
    brightness: Brightness.dark,
    background: Color(0xFF282C34),
    surface: Color(0xFF353B45),
    foreground: Color(0xFFABB2BF),
    primary: Color(0xFF61AFEF),
    secondary: Color(0xFFC678DD),
  ),
  AppThemePreset(
    id: 'monokai',
    name: 'Monokai',
    brightness: Brightness.dark,
    background: Color(0xFF272822),
    surface: Color(0xFF383830),
    foreground: Color(0xFFF8F8F2),
    primary: Color(0xFF66D9EF),
    secondary: Color(0xFFAE81FF),
  ),
  AppThemePreset(
    id: 'material',
    name: 'Material',
    brightness: Brightness.dark,
    background: Color(0xFF263238),
    surface: Color(0xFF2E3C43),
    foreground: Color(0xFFEEFFFF),
    primary: Color(0xFF82AAFF),
    secondary: Color(0xFFC792EA),
  ),
  AppThemePreset(
    id: 'palenight',
    name: 'Palenight',
    brightness: Brightness.dark,
    background: Color(0xFF292D3E),
    surface: Color(0xFF444267),
    foreground: Color(0xFF959DCB),
    primary: Color(0xFF82AAFF),
    secondary: Color(0xFFC792EA),
  ),
  AppThemePreset(
    id: 'cat_mocha',
    name: 'Catppuccin Mocha',
    brightness: Brightness.dark,
    background: Color(0xFF1E1E2E),
    surface: Color(0xFF181825),
    foreground: Color(0xFFCDD6F4),
    primary: Color(0xFF89B4FA),
    secondary: Color(0xFFCBA6F7),
  ),
  AppThemePreset(
    id: 'cat_latte',
    name: 'Catppuccin Latte',
    brightness: Brightness.light,
    background: Color(0xFFEFF1F5),
    surface: Color(0xFFE6E9EF),
    foreground: Color(0xFF4C4F69),
    primary: Color(0xFF1E66F5),
    secondary: Color(0xFF8839EF),
  ),
  AppThemePreset(
    id: 'rose_pine',
    name: 'Rosé Pine',
    brightness: Brightness.dark,
    background: Color(0xFF191724),
    surface: Color(0xFF1F1D2E),
    foreground: Color(0xFFE0DEF4),
    primary: Color(0xFFC4A7E7),
    secondary: Color(0xFFF6C177),
  ),
  AppThemePreset(
    id: 'rose_dawn',
    name: 'Rosé Pine Dawn',
    brightness: Brightness.light,
    background: Color(0xFFFAF4ED),
    surface: Color(0xFFFFFAF3),
    foreground: Color(0xFF575279),
    primary: Color(0xFF907AA9),
    secondary: Color(0xFFEA9D34),
  ),
  AppThemePreset(
    id: 'everforest_dark',
    name: 'Everforest Dark',
    brightness: Brightness.dark,
    background: Color(0xFF2D353B),
    surface: Color(0xFF343F44),
    foreground: Color(0xFF859289),
    primary: Color(0xFF7FBBB3),
    secondary: Color(0xFFD699B6),
  ),
  AppThemePreset(
    id: 'everforest_light',
    name: 'Everforest Light',
    brightness: Brightness.light,
    background: Color(0xFFFDF6E3),
    surface: Color(0xFFF4F0D9),
    foreground: Color(0xFF5C6A72),
    primary: Color(0xFF3A94C5),
    secondary: Color(0xFFDF69BA),
  ),
  AppThemePreset(
    id: 'kanagawa',
    name: 'Kanagawa',
    brightness: Brightness.dark,
    background: Color(0xFF1F1F28),
    surface: Color(0xFF16161D),
    foreground: Color(0xFFDCD7BA),
    primary: Color(0xFF7E9CD8),
    secondary: Color(0xFF957FB8),
  ),
  AppThemePreset(
    id: 'oceanic',
    name: 'OceanicNext',
    brightness: Brightness.dark,
    background: Color(0xFF1B2B34),
    surface: Color(0xFF343D46),
    foreground: Color(0xFFC0C5CE),
    primary: Color(0xFF6699CC),
    secondary: Color(0xFFC594C5),
  ),
];

class AppFont {
  const AppFont({required this.id, required this.name, this.family});

  /// A Google Fonts family saved on the phone.
  AppFont.downloaded(this.name)
    : id = 'download:$name',
      family = 'Downloaded $name';

  final String id;
  final String name;

  /// Bundled font family from pubspec.yaml; null keeps the platform font.
  final String? family;
}

const appFonts = [
  AppFont(id: 'system', name: 'System'),
  AppFont(id: 'inter', name: 'Inter', family: 'Inter'),
  AppFont(id: 'ibm-plex-sans', name: 'IBM Plex Sans', family: 'IBMPlexSans'),
  AppFont(id: 'space-grotesk', name: 'Space Grotesk', family: 'SpaceGrotesk'),
  AppFont(id: 'lora', name: 'Lora', family: 'Lora'),
  AppFont(
    id: 'jetbrains-mono',
    name: 'JetBrains Mono',
    family: 'JetBrainsMonoNF',
  ),
];

const textScales = {
  'Small': 0.9,
  'Default': 1.0,
  'Large': 1.15,
  'Extra large': 1.3,
};

class ThemeController extends ChangeNotifier {
  ThemeController(this._settings);

  final SettingsStore _settings;
  AppThemePreset preset = appThemes.first;
  ThemeMode mode = ThemeMode.system;
  AppFont font = appFonts.first;
  double textScale = 1.0;
  List<AppThemePreset> downloadedThemes = [];
  List<AppFont> downloadedFonts = [];

  List<AppThemePreset> get allThemes => [...appThemes, ...downloadedThemes];
  List<AppFont> get allFonts => [...appFonts, ...downloadedFonts];

  Future<void> load() async {
    downloadedThemes = [
      for (final json in await _settings.loadDownloadedThemes())
        AppThemePreset.fromJson(jsonDecode(json) as Map<String, dynamic>),
    ];
    final savedId = await _settings.loadThemeId();
    preset =
        allThemes.where((theme) => theme.id == savedId).firstOrNull ?? preset;
    mode = await _settings.loadThemeMode();
    // Fonts whose files are gone (e.g. app data cleared) are dropped.
    downloadedFonts = [
      for (final name in await _settings.loadDownloadedFonts())
        ?await _tryLoadFont(AppFont.downloaded(name)),
    ];
    final savedFont = await _settings.loadFontId();
    font = allFonts.where((item) => item.id == savedFont).firstOrNull ?? font;
    textScale = await _settings.loadTextScale() ?? textScale;
    notifyListeners();
  }

  Future<void> selectPreset(AppThemePreset value) async {
    preset = value;
    notifyListeners();
    await _settings.saveThemeId(value.id);
  }

  Future<void> selectFont(AppFont value) async {
    font = value;
    notifyListeners();
    await _settings.saveFontId(value.id);
  }

  Future<void> selectTextScale(double value) async {
    textScale = value;
    notifyListeners();
    await _settings.saveTextScale(value);
  }

  Future<void> selectMode(ThemeMode value) async {
    mode = value;
    notifyListeners();
    await _settings.saveThemeMode(value);
  }

  Future<AppFont?> _tryLoadFont(AppFont font) async {
    try {
      return await loadDownloadedFont(font) ? font : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> installTheme(AppThemePreset theme) async {
    downloadedThemes = [
      ...downloadedThemes.where((item) => item.id != theme.id),
      theme,
    ];
    notifyListeners();
    await _saveThemes();
  }

  Future<void> removeTheme(AppThemePreset theme) async {
    downloadedThemes = downloadedThemes
        .where((item) => item.id != theme.id)
        .toList();
    if (preset.id == theme.id) await selectPreset(appThemes.first);
    notifyListeners();
    await _saveThemes();
  }

  Future<void> _saveThemes() => _settings.saveDownloadedThemes([
    for (final theme in downloadedThemes) jsonEncode(theme.toJson()),
  ]);

  /// Downloads a Google Fonts family and selects it. Throws on failure.
  Future<void> installFont(String name) async {
    await downloadFont(name);
    final font = AppFont.downloaded(name);
    if (await _tryLoadFont(font) == null) {
      throw StateError('Could not load $name');
    }
    downloadedFonts = [
      ...downloadedFonts.where((item) => item.id != font.id),
      font,
    ];
    await _saveFonts();
    await selectFont(font);
  }

  Future<void> removeFont(AppFont font) async {
    downloadedFonts = downloadedFonts
        .where((item) => item.id != font.id)
        .toList();
    if (this.font.id == font.id) await selectFont(appFonts.first);
    notifyListeners();
    await _saveFonts();
    await deleteFontFiles(font.name);
  }

  Future<void> _saveFonts() => _settings.saveDownloadedFonts([
    for (final font in downloadedFonts) font.name,
  ]);
}

abstract final class NovaTheme {
  static ThemeData build(
    AppThemePreset preset,
    Brightness brightness, {
    String? fontFamily,
  }) {
    final generated = ColorScheme.fromSeed(
      seedColor: preset.primary,
      brightness: brightness,
    );
    final exact = preset.brightness == brightness;
    final background = exact ? preset.background : generated.surface;
    final surface = exact ? preset.surface : generated.surfaceContainer;
    final foreground = exact ? preset.foreground : generated.onSurface;
    final scheme = generated.copyWith(
      primary: preset.primary,
      secondary: preset.secondary,
      surface: background,
      onSurface: foreground,
      surfaceContainer: surface,
      surfaceContainerHigh: surface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: fontFamily,
      // The explicit textTheme overrides ThemeData.fontFamily, so apply it here too.
      textTheme: Typography.material2021(platform: TargetPlatform.android).black
          .apply(
            fontFamily: fontFamily,
            bodyColor: foreground,
            displayColor: foreground,
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: foreground,
        elevation: 0,
      ),
      drawerTheme: DrawerThemeData(backgroundColor: background),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: foreground.withValues(alpha: 0.68)),
        prefixIconColor: foreground.withValues(alpha: 0.68),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
