import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/equalizer_page.dart';

void main() {
  test('presets lift only their own range', () {
    final bass = equalizerPresets['Bass']!;
    final treble = equalizerPresets['Treble']!;
    expect(bass(60), greaterThan(0));
    expect(bass(14000), 0);
    expect(treble(14000), greaterThan(0));
    expect(treble(60), 0);
    expect(equalizerPresets['Flat']!(1000), 0);
  });
}
