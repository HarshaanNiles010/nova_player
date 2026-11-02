import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/lyrics.dart';

void main() {
  test('picking stops at the limit and can be undone', () {
    final picked = <int>{};
    for (var i = 0; i < 7; i++) {
      togglePickedLine(picked, i);
    }
    expect(picked, {0, 1, 2, 3, 4});
    togglePickedLine(picked, 2);
    togglePickedLine(picked, 6);
    expect(picked, {0, 1, 3, 4, 6});
  });
}
