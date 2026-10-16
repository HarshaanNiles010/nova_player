import 'package:flutter/material.dart';

import 'song.dart';

/// Groups of copies of the same song; each copy can be hidden from the
/// library, which leaves the file alone.
class DuplicatesPage extends StatefulWidget {
  const DuplicatesPage({
    super.key,
    required this.groups,
    required this.isHidden,
    required this.onHide,
  });

  final List<List<Song>> groups;
  final bool Function(Song song) isHidden;
  final Future<void> Function(List<Song> songs, bool hidden) onHide;

  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  Future<void> _hideExtras() async {
    await widget.onHide([
      for (final group in widget.groups) ...group.skip(1),
    ], true);
    if (mounted) setState(() {});
  }

  String _details(Song song) {
    final mb = song.size / (1024 * 1024);
    return [
      song.format,
      song.durationLabel,
      if (song.size > 0) '${mb.toStringAsFixed(1)} MB',
      if (song.folder.isNotEmpty) song.folder,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duplicates'),
        actions: [
          if (groups.isNotEmpty)
            TextButton(
              onPressed: _hideExtras,
              child: const Text('Keep best only'),
            ),
        ],
      ),
      body: groups.isEmpty
          ? const Center(child: Text('No duplicate songs found.'))
          : ListView.builder(
              itemCount: groups.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return const ListTile(
                    subtitle: Text(
                      'Same title, artist and length. The best copy comes '
                      'first: lossless, then the bigger file. Hidden copies '
                      'stay on your phone; switch them back on any time.',
                    ),
                  );
                }
                final group = groups[index - 1];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(
                        '${group.first.title} · ${group.first.artist}',
                        style: TextStyle(color: colors.primary),
                      ),
                    ),
                    for (final (i, copy) in group.indexed)
                      SwitchListTile(
                        title: Text(
                          copy.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          i == 0 ? 'Best · ${_details(copy)}' : _details(copy),
                        ),
                        value: !widget.isHidden(copy),
                        onChanged: (shown) async {
                          await widget.onHide([copy], !shown);
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                );
              },
            ),
    );
  }
}
