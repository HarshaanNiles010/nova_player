# Nova Player

A local music player for Android, built with Flutter. It plays the music files already on your phone: no accounts, no streaming, no ads.

This is a vibe coded app made for myself. If you want to use the code to make your own player, go for it.

## Features

**Library**
- Finds every song Android has indexed, plus extra folders you add (for example folders with a `.nomedia` file).
- Search by title, artist or album, group by artist, album, genre, year or format, and fast-scroll long lists.
- Album art, with album and artist pages. Tap the artist or album name on Now Playing to open them.

**Playback**
- Background playback with a media notification and lock-screen controls.
- Queue with "play next" and "add to queue", shuffle and repeat, in two queue styles (Spotify and Strawberry).
- The queue sheet on Now Playing shows queued songs and everything after them. Drag to reorder, tap a song to play it now.
- Queued songs stay put when you shuffle (in the app, or from a car or Bluetooth device), jump to another song, or close the app.
- Reopening the app brings back the last song, paused where you left it, with shuffle as you left it.
- Sleep timer: pause after 15 to 60 minutes or at the end of the song, fading out over the last 10 seconds.
- Gapless playback between songs in the same format (sample rate and channels); a format change can leave a short gap.
- A waveform seek bar on Now Playing.
- Lyrics from the file's tags or a matching `.lrc` file. Synced lyrics follow the song.
- In landscape, Now Playing shows the player on the left and lyrics on the right.

**Playlists**
- Make your own playlists and drag songs into any order.
- A heart on Now Playing adds the song to Favourites.
- Smart playlists:
  - the last 50 songs played
  - the 50 newest songs
  - 50 random songs you have never played
  - a 50-song mix from a genre you pick, ranked by Thompson sampling on your plays and skips
- Your own smart playlists from rules, for example "Genre has rock, Skips ≤ 0, Added (days ago) ≤ 365". Rules can use genre, artist, album, format, year, plays, skips, when a song was added and when you last played it. The playlist updates as your library and plays change.

**Look and feel**
- Built-in themes, including ones inspired by Outer Wilds, Rain World, Hollow Knight and Celeste, each with a light, dark or system mode.
- More themes can be downloaded in the app from [`themes/catalog.json`](themes/catalog.json).
- Bundled fonts, plus any [Google Fonts](https://fonts.google.com) family downloaded in the app.
- Adjustable text size.

**Also**
- A duplicate finder in Settings: the same song in several files (title, artist and length match, ignoring tags like "(Remastered)"), best copy first. Hide the extra copies from the library without deleting anything.
- Listening stats.
- Home-screen widgets in two sizes.

## Requirements

- Flutter with Dart 3.13.5 or newer (built with Flutter 3.47)
- Android 7.0 (API 24) or newer. Android only for now; there is no iOS build.

## Run it

```sh
git clone https://github.com/HarshaanNiles010/nova_player.git
cd nova_player
flutter pub get
flutter run
```

Grant the music permission when the app asks, so it can read your library.

## Release build

Release builds need your own signing key; the build stops instead of falling back to the debug key.

1. Create a keystore (keep it backed up; you need the same key to update the installed app):
   ```sh
   keytool -genkey -v -keystore ~/nova-player-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias nova
   ```
2. Create `android/key.properties`, which git ignores:
   ```properties
   storeFile=/absolute/path/to/nova-player-release.jks
   storePassword=...
   keyAlias=nova
   keyPassword=...
   ```
3. Build and install:
   ```sh
   flutter build apk --release
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```

## Add a theme

Themes in the "Get more themes" screen come from [`themes/catalog.json`](themes/catalog.json) on the `main` branch. Phones pick up changes the next time that screen opens, with no app update needed. Each entry looks like this:

```json
{
  "id": "hades",
  "name": "Hades",
  "brightness": "dark",
  "background": "#170A0C",
  "surface": "#2A1215",
  "foreground": "#F3E3CF",
  "primary": "#E5482E",
  "secondary": "#7FD957"
}
```

`id` must be unique. Colors are `#RRGGBB`. `brightness` is `dark` or `light`. The app skips entries it cannot read.

## Project layout

| Path | What it holds |
| --- | --- |
| `lib/music_home_page.dart` | Most of the UI: library, Now Playing, playlists, settings |
| `lib/player_controller.dart`, `lib/queue_mode.dart` | Playback and the queue (just_audio) |
| `lib/smart_playlists.dart` | Smart playlists and the genre-mix ranking |
| `lib/theme.dart`, `lib/downloads.dart` | Themes and fonts, plus downloading them |
| `lib/listening_history.dart`, `lib/stats_page.dart` | Play history and stats |
| `android/app/src/main/kotlin/` | MediaStore scanning, extra folders, lyrics files and widgets |
| `themes/catalog.json` | Downloadable themes |
| `tool/make_icon.py` | Generates the launcher icon |

## Tests

```sh
flutter test
flutter analyze
```

## License

[Apache 2.0](LICENSE)
