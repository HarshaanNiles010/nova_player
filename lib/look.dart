import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'search_bar_style.dart';

enum PlayerLayout { classic, fullBleed, centeredCard, vinyl }

enum PlayerBackground { black, albumColor, gradient, blurredArt, theme }

enum SeekBarStyle {
  bars,
  wave,
  dots,
  line,
  squiggle,
  pill,
  mirrorBars,
  segments,
}

enum ControlStyle { plain, pills, circles, bigMinimal }

enum ArtShape { square, rounded, circle, scallop, flower }

enum TitleAlign { left, center }

enum ListLayout { list, compact, grid, textOnly }

enum MiniPlayerStyle { docked, floating }

/// On/off extras.
enum LookExtra {
  volumeSlider,
  lyricsBackdrop,
  miniProgress,
  libraryTabs,
  visualizer,
}

/// Each value's name and a one-line description, for the settings page.
const lookLabels = <Enum, (String, String)>{
  PlayerLayout.classic: ('Classic', 'Square art on top, controls below.'),
  PlayerLayout.fullBleed: ('Full-bleed', 'Art fills the top edge to edge.'),
  PlayerLayout.centeredCard: (
    'Centered card',
    'Smaller art with space around it.',
  ),
  PlayerLayout.vinyl: ('Vinyl', 'Round art that spins while playing.'),
  PlayerBackground.black: ('Black', 'Pure black, best on AMOLED screens.'),
  PlayerBackground.albumColor: (
    'Album color',
    'Tinted with the cover\'s color.',
  ),
  PlayerBackground.gradient: (
    'Gradient',
    'The cover\'s color fading into black.',
  ),
  PlayerBackground.blurredArt: (
    'Blurred art',
    'The cover, blurred, behind everything.',
  ),
  PlayerBackground.theme: ('Theme color', 'Your color theme\'s background.'),
  SeekBarStyle.bars: ('Bars', 'Thin bars, as tall as that part is loud.'),
  SeekBarStyle.wave: ('Wave', 'One smooth shape following the loudness.'),
  SeekBarStyle.dots: ('Dots', 'Dots that grow with the loudness.'),
  SeekBarStyle.line: ('Line', 'A plain thin line.'),
  SeekBarStyle.squiggle: (
    'Squiggle',
    'Played part wiggles while the song plays.',
  ),
  SeekBarStyle.pill: ('Thick pill', 'A chunky rounded bar.'),
  SeekBarStyle.mirrorBars: ('Equalizer', 'Bars growing up from a baseline.'),
  SeekBarStyle.segments: ('Segments', 'Separate blocks that light up in turn.'),
  ControlStyle.plain: ('Plain', 'Icons with a round play button.'),
  ControlStyle.pills: ('Pills', 'Rounded tinted buttons, wide play pill.'),
  ControlStyle.circles: ('Circles', 'Each button in an outlined circle.'),
  ControlStyle.bigMinimal: ('Big minimal', 'Large bare icons.'),
  ArtShape.square: ('Square', 'Sharp corners.'),
  ArtShape.rounded: ('Rounded', 'Soft corners.'),
  ArtShape.circle: ('Circle', 'Round artwork.'),
  ArtShape.scallop: ('Scallop', 'Wavy cookie-cutter edge.'),
  ArtShape.flower: ('Flower', 'Petal-shaped edge.'),
  TitleAlign.left: ('Left', 'Title and artist on the left.'),
  TitleAlign.center: ('Centered', 'Title and artist centered.'),
  ListLayout.list: ('List', 'Rows with art, title, format and length.'),
  ListLayout.compact: ('Compact', 'Smaller rows, more songs on screen.'),
  ListLayout.grid: ('Grid', 'Album-art cards, two to a row.'),
  ListLayout.textOnly: ('Text only', 'Title and artist, no artwork.'),
  SearchBarStyle.banner: ('Banner', 'Fixed at the top of the screen.'),
  SearchBarStyle.floating: ('Floating', 'A compact bar over the list.'),
  SearchBarStyle.scrolls: ('Scrolls away', 'At the top of the list.'),
  MiniPlayerStyle.docked: ('Docked', 'A bar across the bottom of the screen.'),
  MiniPlayerStyle.floating: ('Floating', 'A rounded card over the list.'),
  LookExtra.volumeSlider: (
    'Volume slider',
    'Phone media volume on the player.',
  ),
  LookExtra.lyricsBackdrop: (
    'Lyrics screen',
    'Full-screen lyrics over the blurred cover.',
  ),
  LookExtra.miniProgress: (
    'Mini player progress',
    'A progress strip on the mini player.',
  ),
  LookExtra.libraryTabs: (
    'Library tabs',
    'Albums, Artists… tabs on the main page.',
  ),
  LookExtra.visualizer: (
    'Visualizer',
    'Bars that move with the music. Needs the audio permission; '
        'it reads only the player\'s sound, never the microphone.',
  ),
};

String lookTitle(Enum value) => lookLabels[value]!.$1;

/// The single-choice options, in settings-page order, with their headings.
const lookChoices = <(String, List<Enum>)>[
  ('Player layout', PlayerLayout.values),
  ('Player background', PlayerBackground.values),
  ('Seek bar', SeekBarStyle.values),
  ('Controls', ControlStyle.values),
  ('Artwork shape', ArtShape.values),
  ('Title alignment', TitleAlign.values),
  ('Main page', ListLayout.values),
  ('Search bar', SearchBarStyle.values),
  ('Mini player', MiniPlayerStyle.values),
];

/// Every look-and-feel option; a [Look] is a named set of these.
@immutable
class LookOptions {
  const LookOptions({
    this.playerLayout = PlayerLayout.classic,
    this.background = PlayerBackground.black,
    this.seekBar = SeekBarStyle.bars,
    this.controls = ControlStyle.plain,
    this.artShape = ArtShape.square,
    this.titleAlign = TitleAlign.left,
    this.listLayout = ListLayout.list,
    this.searchBar = SearchBarStyle.banner,
    this.miniPlayer = MiniPlayerStyle.docked,
    this.extras = const {},
  });

  final PlayerLayout playerLayout;
  final PlayerBackground background;
  final SeekBarStyle seekBar;
  final ControlStyle controls;
  final ArtShape artShape;
  final TitleAlign titleAlign;
  final ListLayout listLayout;
  final SearchBarStyle searchBar;
  final MiniPlayerStyle miniPlayer;
  final Set<LookExtra> extras;

  bool has(LookExtra extra) => extras.contains(extra);

  List<Enum> get choices => [
    playerLayout,
    background,
    seekBar,
    controls,
    artShape,
    titleAlign,
    listLayout,
    searchBar,
    miniPlayer,
  ];

  /// A copy with [value] in place of the choice of the same type, or with a
  /// [LookExtra] switched [on] or off.
  LookOptions withValue(Enum value, {bool on = true}) => LookOptions(
    playerLayout: value is PlayerLayout ? value : playerLayout,
    background: value is PlayerBackground ? value : background,
    seekBar: value is SeekBarStyle ? value : seekBar,
    controls: value is ControlStyle ? value : controls,
    artShape: value is ArtShape ? value : artShape,
    titleAlign: value is TitleAlign ? value : titleAlign,
    listLayout: value is ListLayout ? value : listLayout,
    searchBar: value is SearchBarStyle ? value : searchBar,
    miniPlayer: value is MiniPlayerStyle ? value : miniPlayer,
    extras: value is LookExtra
        ? (on ? {...extras, value} : ({...extras}..remove(value)))
        : extras,
  );

  String toJson() => jsonEncode({
    for (var i = 0; i < lookChoices.length; i++)
      lookChoices[i].$1: choices[i].name,
    'extras': [for (final extra in extras) extra.name],
  });

  /// Unknown or missing options keep their defaults, so older saves still load.
  factory LookOptions.fromJson(String? json) {
    var options = const LookOptions();
    if (json == null) return options;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      for (final (heading, values) in lookChoices) {
        final match = values.where((v) => v.name == map[heading]).firstOrNull;
        if (match != null) options = options.withValue(match);
      }
      for (final name in (map['extras'] as List<dynamic>? ?? const [])) {
        final extra = LookExtra.values.where((e) => e.name == name).firstOrNull;
        if (extra != null) options = options.withValue(extra);
      }
    } on FormatException {
      // Corrupt save: defaults.
    } on TypeError {
      // Wrong shape: defaults.
    }
    return options;
  }

  @override
  bool operator ==(Object other) =>
      other is LookOptions &&
      [for (var i = 0; i < choices.length; i++) other.choices[i] == choices[i]]
          .every((same) => same) &&
      other.extras.length == extras.length &&
      other.extras.containsAll(extras);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(choices), Object.hashAllUnordered(extras));
}

const _codePrefix = 'nova-look:';

/// A short code for [options], to paste into another phone's Nova.
String lookCode(LookOptions options) =>
    _codePrefix + base64Url.encode(utf8.encode(options.toJson()));

/// The options in a [lookCode], or null when [text] isn't one.
LookOptions? lookFromCode(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith(_codePrefix)) return null;
  try {
    final json = utf8.decode(
      base64Url.decode(
        base64Url.normalize(trimmed.substring(_codePrefix.length)),
      ),
    );
    jsonDecode(json) as Map<String, dynamic>;
    return LookOptions.fromJson(json);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

class Look {
  const Look(this.name, this.description, this.options);

  final String name;
  final String description;
  final LookOptions options;
}

const looks = [
  Look(
    'Classic',
    'Nova\'s original: square art on black, bars, list.',
    LookOptions(),
  ),
  Look(
    'Glass',
    'Rounded art over the blurred cover, soft wave, lyrics screen.',
    LookOptions(
      playerLayout: PlayerLayout.centeredCard,
      background: PlayerBackground.blurredArt,
      seekBar: SeekBarStyle.wave,
      controls: ControlStyle.circles,
      artShape: ArtShape.rounded,
      titleAlign: TitleAlign.center,
      searchBar: SearchBarStyle.floating,
      miniPlayer: MiniPlayerStyle.floating,
      extras: {LookExtra.lyricsBackdrop, LookExtra.volumeSlider},
    ),
  ),
  Look(
    'Poster',
    'Edge-to-edge cover fading into its color, squiggle, album grid.',
    LookOptions(
      playerLayout: PlayerLayout.fullBleed,
      background: PlayerBackground.gradient,
      seekBar: SeekBarStyle.squiggle,
      controls: ControlStyle.pills,
      listLayout: ListLayout.grid,
      searchBar: SearchBarStyle.scrolls,
      extras: {
        LookExtra.lyricsBackdrop,
        LookExtra.volumeSlider,
        LookExtra.miniProgress,
        LookExtra.libraryTabs,
      },
    ),
  ),
  Look(
    'Turntable',
    'A spinning record on the cover\'s color, dots, round art.',
    LookOptions(
      playerLayout: PlayerLayout.vinyl,
      background: PlayerBackground.albumColor,
      seekBar: SeekBarStyle.dots,
      controls: ControlStyle.circles,
      artShape: ArtShape.circle,
      titleAlign: TitleAlign.center,
      listLayout: ListLayout.compact,
      extras: {LookExtra.miniProgress},
    ),
  ),
  Look(
    'Pure',
    'Minimal and fast: black, a plain line, no artwork in lists.',
    LookOptions(
      seekBar: SeekBarStyle.line,
      controls: ControlStyle.bigMinimal,
      listLayout: ListLayout.textOnly,
    ),
  ),
  Look(
    'Matching',
    'The player takes your color theme; pills and compact rows.',
    LookOptions(
      playerLayout: PlayerLayout.centeredCard,
      background: PlayerBackground.theme,
      seekBar: SeekBarStyle.pill,
      controls: ControlStyle.pills,
      artShape: ArtShape.scallop,
      listLayout: ListLayout.compact,
      extras: {LookExtra.libraryTabs, LookExtra.miniProgress},
    ),
  ),
];

/// The options in use, read across the app; saved by ThemeController.
final lookOptions = ValueNotifier(const LookOptions());

extension ArtShapePath on ArtShape {
  /// The outline of artwork of [size] in this shape.
  Path path(Size size) {
    final rect = Offset.zero & size;
    switch (this) {
      case ArtShape.square:
        return Path()..addRect(rect);
      case ArtShape.rounded:
        return Path()..addRRect(
          RRect.fromRectAndRadius(
            rect,
            Radius.circular(size.shortestSide * 0.1),
          ),
        );
      case ArtShape.circle:
        return Path()..addOval(rect);
      case ArtShape.scallop:
        return _wavyCircle(size, lobes: 12, depth: 0.05);
      case ArtShape.flower:
        return _wavyCircle(size, lobes: 8, depth: 0.14);
    }
  }
}

/// A circle whose edge rises and falls [lobes] times by [depth] of the radius.
Path _wavyCircle(Size size, {required int lobes, required double depth}) {
  final center = size.center(Offset.zero);
  final radius = size.shortestSide / 2;
  final path = Path();
  const steps = 240;
  for (var i = 0; i <= steps; i++) {
    final angle = i / steps * 2 * math.pi;
    final r = radius * (1 - depth * (1 - math.cos(lobes * angle)) / 2);
    final point = center + Offset(math.cos(angle), math.sin(angle)) * r;
    i == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
  }
  return path..close();
}

class ArtShapeClipper extends CustomClipper<Path> {
  const ArtShapeClipper(this.shape);

  final ArtShape shape;

  @override
  Path getClip(Size size) => shape.path(size);

  @override
  bool shouldReclip(ArtShapeClipper oldClipper) => oldClipper.shape != shape;
}

final _albumColors = <String, Future<Color?>>{};

/// The cover's most colorful shade, from a tiny copy of it; cached by [key].
Future<Color?> albumColor(String key, Uint8List bytes) =>
    _albumColors.putIfAbsent(key, () async {
      try {
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 16);
        final image = (await codec.getNextFrame()).image;
        final data = await image.toByteData();
        image.dispose();
        return data == null ? null : dominantColor(data.buffer.asUint8List());
      } catch (_) {
        return null;
      }
    });

/// Average of the pixels weighted by saturation, so grey borders and white
/// text on a cover don't wash the color out. [rgba] is 4 bytes per pixel.
Color dominantColor(Uint8List rgba) {
  var r = 0.0, g = 0.0, b = 0.0, total = 0.0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final color = Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
    final weight = HSVColor.fromColor(color).saturation + 0.05;
    r += rgba[i] * weight;
    g += rgba[i + 1] * weight;
    b += rgba[i + 2] * weight;
    total += weight;
  }
  if (total == 0) return Colors.black;
  return Color.fromARGB(255, r ~/ total, g ~/ total, b ~/ total);
}
