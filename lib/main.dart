import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'music_home_page.dart';
import 'settings_store.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.novaplayer.nova_player.playback',
    androidNotificationChannelName: 'Nova Player playback',
    androidNotificationOngoing: true,
  );
  runApp(const NovaApp());
}

class NovaApp extends StatefulWidget {
  const NovaApp({super.key, this.home});

  final Widget? home;

  @override
  State<NovaApp> createState() => _NovaAppState();
}

class _NovaAppState extends State<NovaApp> {
  late final ThemeController _themes = ThemeController(SettingsStore());

  @override
  void initState() {
    super.initState();
    _themes.load();
  }

  @override
  void dispose() {
    _themes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _themes,
      builder: (context, _) => MaterialApp(
        title: 'Nova Player',
        debugShowCheckedModeBanner: false,
        theme: NovaTheme.build(
          _themes.preset,
          Brightness.light,
          fontFamily: _themes.font.family,
        ),
        darkTheme: NovaTheme.build(
          _themes.preset,
          Brightness.dark,
          fontFamily: _themes.font.family,
        ),
        themeMode: _themes.mode,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: _ScaledTextScaler(
                media.textScaler,
                _themes.textScale,
              ),
            ),
            child: child!,
          );
        },
        home: widget.home ?? MusicHomePage(themeController: _themes),
      ),
    );
  }
}

/// Multiplies the system text scaling (accessibility) by the in-app size choice.
class _ScaledTextScaler extends TextScaler {
  const _ScaledTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is _ScaledTextScaler &&
      other.base == base &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}
