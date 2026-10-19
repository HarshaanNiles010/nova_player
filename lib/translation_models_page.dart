import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// The language packs on the phone for translating lyrics, each deletable.
/// Translating a song downloads its pack again.
class TranslationModelsPage extends StatefulWidget {
  const TranslationModelsPage({super.key});

  @override
  State<TranslationModelsPage> createState() => _TranslationModelsPageState();
}

class _TranslationModelsPageState extends State<TranslationModelsPage> {
  final _models = OnDeviceTranslatorModelManager();
  late Future<List<TranslateLanguage>> _downloaded = _find();
  bool _deleting = false;

  Future<List<TranslateLanguage>> _find() async {
    final languages = TranslateLanguage.values;
    final present = await Future.wait([
      for (final language in languages)
        _models.isModelDownloaded(language.bcpCode),
    ]);
    return [
      for (final (i, language) in languages.indexed)
        if (present[i]) language,
    ];
  }

  Future<void> _delete(List<TranslateLanguage> languages) async {
    setState(() => _deleting = true);
    try {
      for (final language in languages) {
        await _models.deleteModel(language.bcpCode);
      }
    } finally {
      if (mounted) {
        setState(() {
          _deleting = false;
          _downloaded = _find();
        });
      }
    }
  }

  static String _name(TranslateLanguage language) =>
      language.name[0].toUpperCase() + language.name.substring(1);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<TranslateLanguage>>(
      future: _downloaded,
      builder: (context, snapshot) {
        final languages = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Translation languages'),
            actions: [
              if (languages != null && languages.isNotEmpty)
                TextButton(
                  onPressed: _deleting ? null : () => _delete(languages),
                  child: const Text('Delete all'),
                ),
            ],
          ),
          body: languages == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Language packs downloaded to translate lyrics on the '
                        'phone, about 30 MB each. English is used by every '
                        'translation. Translating a song downloads its '
                        'languages again.',
                      ),
                    ),
                    if (languages.isEmpty)
                      const ListTile(
                        title: Text('No language packs on the phone.'),
                      ),
                    for (final language in languages)
                      ListTile(
                        leading: const Icon(Icons.translate_rounded),
                        title: Text(_name(language)),
                        trailing: IconButton(
                          tooltip: 'Delete',
                          onPressed: _deleting
                              ? null
                              : () => _delete([language]),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
