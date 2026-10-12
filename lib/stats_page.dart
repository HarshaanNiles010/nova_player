import 'package:flutter/material.dart';

import 'listening_history.dart';
import 'listening_stats.dart';
import 'music_home_page.dart';
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
