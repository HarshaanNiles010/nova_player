enum SearchBarStyle { banner, floating, scrolls }

extension SearchBarStyleDetails on SearchBarStyle {
  String get title => switch (this) {
    SearchBarStyle.banner => 'Banner',
    SearchBarStyle.floating => 'Floating',
    SearchBarStyle.scrolls => 'Scrolls with the list',
  };

  String get description => switch (this) {
    SearchBarStyle.banner =>
      'Nova, search and Group by stay fixed at the top of the screen.',
    SearchBarStyle.floating =>
      'A compact bar floats over the list, with the menu, search and Group by.',
    SearchBarStyle.scrolls =>
      'Nova, search and Group by sit at the top of the list and scroll away.',
  };
}
