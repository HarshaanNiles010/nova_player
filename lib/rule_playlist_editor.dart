import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'rule_playlists.dart';

/// Creates or edits a [RulePlaylist]; pops with nothing, the store is
/// updated on save.
class RulePlaylistEditor extends StatefulWidget {
  const RulePlaylistEditor({super.key, this.initial});

  final RulePlaylist? initial;

  @override
  State<RulePlaylistEditor> createState() => _RulePlaylistEditorState();
}

class _RulePlaylistEditorState extends State<RulePlaylistEditor> {
  late final _name = TextEditingController(text: widget.initial?.name);
  late final _limit = TextEditingController(
    text: '${widget.initial?.limit ?? 50}',
  );
  late RuleSort _sort = widget.initial?.sort ?? RuleSort.best;

  /// Rules being edited; each value has its own text controller.
  late final List<(RuleField, RuleOp, TextEditingController)> _rules = [
    for (final rule in widget.initial?.rules ?? const <Rule>[])
      (rule.field, rule.op, TextEditingController(text: rule.value)),
  ];

  @override
  void initState() {
    super.initState();
    if (_rules.isEmpty) _addRule();
  }

  @override
  void dispose() {
    _name.dispose();
    _limit.dispose();
    for (final (_, _, value) in _rules) {
      value.dispose();
    }
    super.dispose();
  }

  void _addRule() => setState(
    () =>
        _rules.add((RuleField.genre, RuleOp.contains, TextEditingController())),
  );

  void _setField(int index, RuleField field) {
    final (old, op, value) = _rules[index];
    if (old == field) return;
    final ops = RuleOp.forField(field);
    setState(() {
      // Text and number fields take different values.
      if (old.number != field.number) value.clear();
      _rules[index] = (field, ops.contains(op) ? op : ops.first, value);
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final rules = [
      for (final (field, op, value) in _rules)
        if (value.text.trim().isNotEmpty) Rule(field, op, value.text.trim()),
    ];
    final problem = name.isEmpty
        ? 'Give the playlist a name.'
        : rules.isEmpty
        ? 'Add at least one rule with a value.'
        : null;
    if (problem != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    await RulePlaylistStore.instance.save(
      RulePlaylist(
        name: name,
        rules: rules,
        sort: _sort,
        limit: int.tryParse(_limit.text) ?? 0,
      ),
      replacing: widget.initial?.name,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initial == null ? 'New smart playlist' : 'Edit smart playlist',
        ),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 24),
          Text(
            'Songs that match all of these',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final (index, (field, op, value)) in _rules.indexed)
            Padding(
              // Rows keep their dropdown state when one above is removed.
              key: ObjectKey(value),
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    flex: 4,
                    child: DropdownButtonFormField<RuleField>(
                      initialValue: field,
                      isExpanded: true,
                      items: [
                        for (final f in RuleField.values)
                          DropdownMenuItem(value: f, child: Text(f.label)),
                      ],
                      onChanged: (f) => _setField(index, f!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<RuleOp>(
                      // Keyed by field type so the choices reset with it.
                      key: ValueKey(field.number),
                      initialValue: op,
                      isExpanded: true,
                      items: [
                        for (final o in RuleOp.forField(field))
                          DropdownMenuItem(value: o, child: Text(o.label)),
                      ],
                      onChanged: (o) =>
                          setState(() => _rules[index] = (field, o!, value)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: value,
                      keyboardType: field.number
                          ? TextInputType.number
                          : TextInputType.text,
                      inputFormatters: [
                        if (field.number)
                          FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: InputDecoration(
                        hintText: field.number ? '0' : 'rock',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove rule',
                    onPressed: _rules.length == 1
                        ? null
                        : () => setState(
                            () => _rules.removeAt(index).$3.dispose(),
                          ),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addRule,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add rule'),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<RuleSort>(
            initialValue: _sort,
            decoration: const InputDecoration(labelText: 'Order'),
            items: [
              for (final s in RuleSort.values)
                DropdownMenuItem(value: s, child: Text(s.label)),
            ],
            onChanged: (s) => setState(() => _sort = s!),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _limit,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Most songs',
              helperText: '0 keeps every matching song',
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Example: Genre has rock, Skips ≤ 0, Added (days ago) ≤ 365 '
            'finds rock songs added this year that you never skipped.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
