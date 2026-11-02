import 'package:flutter_test/flutter_test.dart';
import 'package:nova_player/search_bar_style.dart';
import 'package:nova_player/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('defaults to the banner and remembers the choice', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    expect(await store.loadSearchBarStyle(), SearchBarStyle.banner);
    await store.saveSearchBarStyle(SearchBarStyle.floating);
    expect(await store.loadSearchBarStyle(), SearchBarStyle.floating);
  });

  test('an unknown saved value falls back to the banner', () async {
    SharedPreferences.setMockInitialValues({'search_bar_style': 'gone'});
    expect(await SettingsStore().loadSearchBarStyle(), SearchBarStyle.banner);
  });
}
