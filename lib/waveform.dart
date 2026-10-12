List<double> waveformPeaks(String seed, int count) {
  if (count <= 0) return const [];
  var state = seed.codeUnits.fold<int>(17, (value, code) => value * 31 + code);
  return List.generate(count, (_) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return 0.18 + (state / 0x7fffffff) * 0.82;
  }, growable: false);
}
