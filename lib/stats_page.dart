import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'listening_history.dart';
import 'listening_stats.dart';
import 'music_home_page.dart';
import 'music_library.dart';
import 'player_controller.dart';
import 'song.dart';

enum _Period { month, year, all }

extension on _Period {
  String get label => switch (this) {
    _Period.month => 'This month',
    _Period.year => 'This year',
    _Period.all => 'All time',
  };

  DateTime? get since {
    final now = DateTime.now();
    return switch (this) {
      _Period.month => DateTime(now.year, now.month),
      _Period.year => DateTime(now.year),
      _Period.all => null,
    };
  }
}

/// Wrapped-style listening stats from the play log.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.player, required this.library});

  final PlayerController player;
  final List<Song> library;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late Future<List<PlayRecord>> _records = _load();
  var _period = _Period.year;

  Future<List<PlayRecord>> _load() async => [
    ...await ListeningHistory.instance.load(),
    ?widget.player.currentListen,
  ];

  Song? _songFor(PlayRecord record) {
    for (final song in widget.library) {
      if (song.id == record.songId ||
          (record.fileName.isNotEmpty && song.fileName == record.fileName)) {
        return song;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'YOUR STATS',
          style: TextStyle(fontSize: 14, letterSpacing: 2.4),
        ),
        actions: [
          IconButton(
            tooltip: 'Year in review',
            onPressed: () async {
              final records = await _records;
              if (!context.mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      RecapPage(records: records, songFor: _songFor),
                ),
              );
            },
            icon: const Icon(Icons.auto_awesome_rounded),
          ),
        ],
      ),
      body: FutureBuilder<List<PlayRecord>>(
        future: _records,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Could not read your history.'));
          }
          final records = snapshot.data;
          if (records == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final stats = computeStats(records, since: _period.since);
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _records = _load());
              await _records;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                SegmentedButton<_Period>(
                  segments: [
                    for (final period in _Period.values)
                      ButtonSegment(value: period, label: Text(period.label)),
                  ],
                  selected: {_period},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) =>
                      setState(() => _period = value.first),
                ),
                const SizedBox(height: 20),
                if (stats.isEmpty)
                  _EmptyStats(period: _period)
                else
                  ..._cards(context, stats),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _cards(BuildContext context, ListeningStats stats) {
    final colors = Theme.of(context).colorScheme;
    final minutes = (stats.totalMs / 60000).round();
    final topGenre = stats.topGenres.firstOrNull;
    return [
      _HeroCard(
        background: colors.primary,
        foreground: colors.onPrimary,
        label: 'MINUTES LISTENED',
        value: _minutes(stats.totalMs),
        detail: minutes >= 120
            ? 'That\'s ${_thousands(minutes ~/ 60)} hours across '
                  '${stats.daysListened} ${stats.daysListened == 1 ? 'day' : 'days'}.'
            : 'Across ${stats.daysListened} '
                  '${stats.daysListened == 1 ? 'day' : 'days'}.',
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          _SmallStat(label: 'PLAYS', value: _thousands(stats.plays)),
          const SizedBox(width: 12),
          _SmallStat(label: 'SONGS', value: _thousands(stats.uniqueSongs)),
          const SizedBox(width: 12),
          _SmallStat(label: 'ARTISTS', value: _thousands(stats.uniqueArtists)),
        ],
      ),
      if (topGenre != null) ...[
        const SizedBox(height: 12),
        _HeroCard(
          background: colors.secondary,
          foreground: colors.onSecondary,
          label: 'TOP GENRE',
          value: topGenre.label,
          detail: '${_minutes(topGenre.ms)} minutes of it.',
        ),
      ],
      if (stats.topSongs.isNotEmpty) ...[
        const _SectionTitle('TOP SONGS'),
        for (final (i, entry) in stats.topSongs.indexed)
          _RankRow(
            rank: i + 1,
            song: _songFor(entry.sample),
            title: entry.label,
            subtitle: entry.detail,
            trailing: '${entry.plays} ${entry.plays == 1 ? 'play' : 'plays'}',
          ),
      ],
      if (stats.topArtists.isNotEmpty) ...[
        const _SectionTitle('TOP ARTISTS'),
        for (final (i, entry) in stats.topArtists.indexed)
          _RankRow(
            rank: i + 1,
            song: _songFor(entry.sample),
            title: entry.label,
            trailing: '${_minutes(entry.ms)} min',
          ),
      ],
      if (stats.topAlbums.isNotEmpty) ...[
        const _SectionTitle('TOP ALBUMS'),
        for (final (i, entry) in stats.topAlbums.indexed)
          _RankRow(
            rank: i + 1,
            song: _songFor(entry.sample),
            title: entry.label,
            subtitle: entry.detail,
            trailing: '${_minutes(entry.ms)} min',
          ),
      ],
      if (stats.topGenres.length > 1) ...[
        const _SectionTitle('TOP GENRES'),
        for (final (i, entry) in stats.topGenres.indexed)
          _RankRow(
            rank: i + 1,
            title: entry.label,
            trailing: '${_minutes(entry.ms)} min',
          ),
      ],
      const SizedBox(height: 12),
      if (stats.peakHour case final hour?)
        _HeroCard(
          background: colors.surfaceContainerHigh,
          foreground: colors.onSurface,
          label: 'PEAK LISTENING HOUR',
          value: _hourLabel(hour),
          detail: _hourMood(hour),
        ),
      if (stats.topDay case final day?) ...[
        const SizedBox(height: 12),
        _HeroCard(
          background: colors.surfaceContainerHigh,
          foreground: colors.onSurface,
          label: 'BIGGEST DAY',
          value: MaterialLocalizations.of(context).formatMediumDate(day),
          detail: '${_minutes(stats.topDayMs)} minutes of music.',
        ),
      ],
    ];
  }
}

String _thousands(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);

/// Whole minutes, with "<1" so a short listen doesn't read as nothing.
String _minutes(int ms) =>
    ms > 0 && ms < 60000 ? '<1' : _thousands((ms / 60000).round());

String _hourLabel(int hour) {
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h ${hour < 12 ? 'AM' : 'PM'}';
}

String _hourMood(int hour) => switch (hour) {
  >= 5 && < 9 => 'Early bird. Music with your morning.',
  >= 9 && < 17 => 'Daytime listener. Music keeps you going.',
  >= 17 && < 22 => 'Evening wind-down is your time.',
  _ => 'Night owl. The best songs come out after dark.',
};

/// A year of listening as a row of swipeable slides, ending in a shareable card.
class RecapPage extends StatefulWidget {
  const RecapPage({super.key, required this.records, required this.songFor});

  final List<PlayRecord> records;
  final Song? Function(PlayRecord record) songFor;

  @override
  State<RecapPage> createState() => _RecapPageState();
}

class _RecapPageState extends State<RecapPage> {
  late final _years = recapYears(widget.records);
  late int? _year = _years.firstOrNull;
  final _cardKey = GlobalKey();
  int _page = 0;

  Future<void> _share() async {
    try {
      final card =
          _cardKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await card.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await MusicLibrary().shareImage(png!.buffer.asUint8List());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not share the card.')),
      );
    }
  }

  List<Widget> _slides(BuildContext context, ListeningStats stats, int year) {
    final colors = Theme.of(context).colorScheme;
    final hours = stats.totalMs ~/ 3600000;
    Widget ranked(
      String label,
      List<StatEntry> entries,
      Color background,
      Color foreground,
      String Function(StatEntry entry) detail,
    ) => _RecapSlide(
      background: background,
      foreground: foreground,
      label: label,
      value: entries.first.label,
      detail: detail(entries.first),
      song: widget.songFor(entries.first.sample),
      runnersUp: [for (final entry in entries.skip(1)) entry.label],
    );

    final so = year == DateTime.now().year ? ' SO FAR' : '';
    return [
      _RecapSlide(
        background: colors.primary,
        foreground: colors.onPrimary,
        label: 'YOUR $year$so',
        value: '${_minutes(stats.totalMs)} minutes',
        detail: hours >= 2
            ? 'That\'s ${_thousands(hours)} hours of music, over '
                  '${stats.daysListened} days.'
            : 'Over ${stats.daysListened} '
                  '${stats.daysListened == 1 ? 'day' : 'days'}.',
      ),
      if (stats.topSongs.isNotEmpty)
        ranked(
          'SONG OF THE YEAR',
          stats.topSongs,
          colors.surfaceContainerHigh,
          colors.onSurface,
          (e) =>
              '${e.detail}. ${_thousands(e.plays)} '
              '${e.plays == 1 ? 'play' : 'plays'}.',
        ),
      if (stats.topArtists.isNotEmpty)
        ranked(
          'ARTIST OF THE YEAR',
          stats.topArtists,
          colors.secondary,
          colors.onSecondary,
          (e) => '${_minutes(e.ms)} minutes together.',
        ),
      if (stats.topAlbums.isNotEmpty)
        ranked(
          'ALBUM OF THE YEAR',
          stats.topAlbums,
          colors.surfaceContainerHigh,
          colors.onSurface,
          (e) => '${e.detail}. ${_minutes(e.ms)} minutes.',
        ),
      if (stats.topGenres.isNotEmpty)
        _RecapSlide(
          background: colors.primary,
          foreground: colors.onPrimary,
          label: 'YOUR SOUND',
          value: stats.topGenres.first.label,
          detail: '${_minutes(stats.topGenres.first.ms)} minutes of it.',
          runnersUp: [for (final e in stats.topGenres.skip(1)) e.label],
        ),
      if (stats.peakHour case final hour?)
        _RecapSlide(
          background: colors.secondary,
          foreground: colors.onSecondary,
          label: 'YOUR HOUR',
          value: _hourLabel(hour),
          detail:
              '${_hourMood(hour)}'
              '${stats.topDay == null ? '' : ' Biggest day: ${MaterialLocalizations.of(context).formatMediumDate(stats.topDay!)}, ${_minutes(stats.topDayMs)} minutes.'}',
        ),
      _recapCard(context, stats, year),
    ];
  }

  Widget _recapCard(BuildContext context, ListeningStats stats, int year) {
    final colors = Theme.of(context).colorScheme;
    Widget row(String label, String? value) => value == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                    letterSpacing: 1.6,
                  ),
                ),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              key: _cardKey,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                color: colors.surfaceContainerHigh,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MY $year IN MUSIC',
                      style: TextStyle(
                        color: colors.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    row('MINUTES', _minutes(stats.totalMs)),
                    row('SONG', stats.topSongs.firstOrNull?.label),
                    row('ARTIST', stats.topArtists.firstOrNull?.label),
                    row('ALBUM', stats.topAlbums.firstOrNull?.label),
                    row('GENRE', stats.topGenres.firstOrNull?.label),
                    Text(
                      'NOVA PLAYER',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 10,
                        letterSpacing: 2.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (Theme.of(context).platform == TargetPlatform.android) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('Share'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final year = _year;
    final slides = year == null
        ? const <Widget>[]
        : _slides(
            context,
            computeStats(
              widget.records,
              since: DateTime(year),
              until: DateTime(year + 1),
            ),
            year,
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'YEAR IN REVIEW',
          style: TextStyle(fontSize: 14, letterSpacing: 2.4),
        ),
        actions: [
          if (_years.length > 1)
            PopupMenuButton<int>(
              tooltip: 'Choose a year',
              initialValue: year,
              onSelected: (value) => setState(() {
                _year = value;
                _page = 0;
              }),
              itemBuilder: (context) => [
                for (final value in _years)
                  CheckedPopupMenuItem(
                    value: value,
                    checked: value == year,
                    child: Text('$value'),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('$year'),
              ),
            ),
        ],
      ),
      body: year == null
          ? const Center(child: Text('Listen to some music and come back.'))
          : Column(
              children: [
                Expanded(
                  child: PageView(
                    // A new year starts again from its first slide.
                    key: ValueKey(year),
                    onPageChanged: (page) => setState(() => _page = page),
                    children: slides,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 16),
                  child: SafeArea(
                    top: false,
                    child: Text(
                      '${_page + 1} of ${slides.length}, swipe to continue',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _RecapSlide extends StatelessWidget {
  const _RecapSlide({
    required this.background,
    required this.foreground,
    required this.label,
    required this.value,
    required this.detail,
    this.song,
    this.runnersUp = const [],
  });

  final Color background;
  final Color foreground;
  final String label;
  final String value;
  final String detail;
  final Song? song;
  final List<String> runnersUp;

  @override
  Widget build(BuildContext context) {
    final song = this.song;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(24),
      ),
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: foreground.withValues(alpha: 0.8),
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 24),
            if (song != null) ...[
              NovaArtwork(song: song, size: 220),
              const SizedBox(height: 24),
            ],
            Text(
              value,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.displaySmall
                  ?.copyWith(color: foreground, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            Text(detail, style: TextStyle(color: foreground, fontSize: 16)),
            if (runnersUp.isNotEmpty) ...[
              const SizedBox(height: 24),
              for (final (i, name) in runnersUp.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${i + 2}. $name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: foreground.withValues(alpha: 0.8)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyStats extends StatelessWidget {
  const _EmptyStats({required this.period});

  final _Period period;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          Icon(
            Icons.insights_rounded,
            size: 56,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Nothing yet ${period == _Period.all ? '' : period.label.toLowerCase()}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Play some music. Your stats build up as you listen.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.background,
    required this.foreground,
    required this.label,
    required this.value,
    required this.detail,
  });

  final Color background;
  final Color foreground;
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: foreground.withValues(alpha: 0.8),
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.displaySmall
                ?.copyWith(color: foreground, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(detail, style: TextStyle(color: foreground)),
        ],
      ),
    );
  }
}

class _SmallStat extends StatelessWidget {
  const _SmallStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 28, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.6,
        ),
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.rank,
    required this.title,
    required this.trailing,
    this.subtitle = '',
    this.song,
  });

  final int rank;
  final String title;
  final String subtitle;
  final String trailing;
  final Song? song;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$rank',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          if (song case final song?) ...[
            const SizedBox(width: 6),
            NovaArtwork(song: song, size: 44),
          ],
        ],
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(trailing, style: theme.textTheme.labelMedium),
    );
  }
}
