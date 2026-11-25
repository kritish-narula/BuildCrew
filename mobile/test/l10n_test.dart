import 'package:buildcrew/l10n/gen/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all 12 launch languages are supported', () {
    expect(L.supportedLocales.map((l) => l.languageCode).toSet(),
        {'hi', 'bn', 'te', 'mr', 'ta', 'gu', 'kn', 'ml', 'or', 'pa', 'as', 'en'});
  });

  test('Hindi is fully translated for onboarding', () async {
    final hi = await L.delegate.load(const Locale('hi'));
    expect(hi.chooseLanguage, isNot('Choose your language'));
    expect(hi.workersQuoted(5), contains('5'));
  });
}
