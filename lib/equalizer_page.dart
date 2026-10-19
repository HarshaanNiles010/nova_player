import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'settings_store.dart';

/// Gain in dB for a band centred on [hertz], per preset name.
final Map<String, double Function(double hertz)> equalizerPresets = {
  'Flat': (_) => 0,
  'Bass': (hertz) => hertz <= 150 ? 6 : (hertz <= 500 ? 3 : 0),
  'Treble': (hertz) => hertz >= 8000 ? 6 : (hertz >= 3000 ? 3 : 0),
  'Vocal': (hertz) =>
      hertz >= 800 && hertz <= 5000 ? 4 : (hertz < 200 ? -2 : 0),
};

/// Applies the saved equalizer. Band gains wait until a song is loaded,
/// since only then does Android report the bands.
Future<void> restoreEqualizer(AndroidEqualizer? equalizer) async {
  if (equalizer == null) return;
  final (enabled, gains) = await SettingsStore().loadEqualizer();
  await equalizer.setEnabled(enabled);
  if (gains.isEmpty) return;
  final bands = (await equalizer.parameters).bands;
  // Another phone (a restored backup) can have other bands.
  if (gains.length != bands.length) return;
  for (final band in bands) {
    await band.setGain(gains[band.index]);
  }
}

class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key, required this.equalizer});

  final AndroidEqualizer equalizer;

  Future<void> _save() async {
    final bands = (await equalizer.parameters).bands;
    await SettingsStore().saveEqualizer(equalizer.enabled, [
      for (final band in bands) band.gain,
    ]);
  }

  static String _hertz(double hertz) => hertz >= 1000
      ? '${(hertz / 1000).toStringAsFixed(hertz >= 10000 ? 0 : 1)} kHz'
      : '${hertz.round()} Hz';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: ListView(
        children: [
          StreamBuilder<bool>(
            stream: equalizer.enabledStream,
            initialData: equalizer.enabled,
            builder: (context, enabled) => SwitchListTile(
              title: const Text('Equalizer'),
              value: enabled.data ?? false,
              onChanged: (on) async {
                await equalizer.setEnabled(on);
                await _save();
              },
            ),
          ),
          FutureBuilder<AndroidEqualizerParameters>(
            future: equalizer.parameters,
            builder: (context, snapshot) {
              final parameters = snapshot.data;
              if (parameters == null) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Play a song to adjust the bands.'),
                );
              }
              return _Bands(
                parameters: parameters,
                label: _hertz,
                onChanged: _save,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Bands extends StatelessWidget {
  const _Bands({
    required this.parameters,
    required this.label,
    required this.onChanged,
  });

  final AndroidEqualizerParameters parameters;
  final String Function(double hertz) label;
  final Future<void> Function() onChanged;

  Future<void> _apply(double Function(double hertz) preset) async {
    for (final band in parameters.bands) {
      await band.setGain(
        preset(band.centerFrequency)
            .clamp(parameters.minDecibels, parameters.maxDecibels),
      );
    }
    await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final min = parameters.minDecibels;
    final max = parameters.maxDecibels;
    return Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final MapEntry(:key, :value) in equalizerPresets.entries)
              ActionChip(label: Text(key), onPressed: () => _apply(value)),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 300,
          child: Row(
            children: [
              for (final band in parameters.bands)
                Expanded(
                  child: StreamBuilder<double>(
                    stream: band.gainStream,
                    initialData: band.gain,
                    builder: (context, gain) {
                      final value = (gain.data ?? 0).clamp(min, max);
                      return Column(
                        children: [
                          Text(
                            '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)}',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Slider(
                                min: min,
                                max: max,
                                value: value,
                                onChanged: band.setGain,
                                onChangeEnd: (_) => onChanged(),
                              ),
                            ),
                          ),
                          Text(
                            label(band.centerFrequency),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
