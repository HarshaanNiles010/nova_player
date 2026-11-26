import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/look.dart';
import 'package:nova_player/search_bar_style.dart';
import 'package:nova_player/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('defaults to the banner and remembers the look', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    expect((await store.loadLook()).searchBar, SearchBarStyle.banner);
    final glass = looks.firstWhere((look) => look.name == 'Glass').options;
    await store.saveLook(glass);
    expect(await store.loadLook(), glass);
  });

  test('the older search bar setting carries into the look', () async {
    SharedPreferences.setMockInitialValues({'search_bar_style': 'floating'});
    expect(
      (await SettingsStore().loadLook()).searchBar,
      SearchBarStyle.floating,
    );
  });

  test('an unknown saved value falls back to the banner', () async {
    SharedPreferences.setMockInitialValues({'search_bar_style': 'gone'});
    expect((await SettingsStore().loadLook()).searchBar, SearchBarStyle.banner);
  });
}
