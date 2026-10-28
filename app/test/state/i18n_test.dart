import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/i18n.dart';

void main() {
  tearDown(() => I18n.notifier.value = 'zh');

  test('every key resolves in all three languages and differs from the key', () {
    final keys = ['nav.library', 'sing.record', 'results.total', 'settings.uiLanguage', 'backend.cudaMissing.body', 'library.deleteConfirm'];
    for (final lang in I18n.supported) {
      I18n.notifier.value = lang;
      for (final k in keys) {
        final s = tr(k, {'gpu': 'X', 'size': '1 GB', 'title': 'T'});
        expect(s, isNot(equals(k)), reason: '$k missing in $lang');
        expect(s, isNot(contains('{')), reason: '$k has unreplaced args in $lang');
      }
    }
  });

  test('switching the language notifies and persists through onChanged', () {
    final seen = <String>[];
    I18n.onChanged = seen.add;
    I18n.lang = 'ja';
    expect(tr('nav.library'), '曲ライブラリ');
    I18n.lang = 'en';
    expect(tr('nav.library'), 'Library');
    I18n.lang = 'xx'; // unsupported: ignored
    expect(I18n.lang, 'en');
    expect(seen, ['ja', 'en']);
    I18n.onChanged = null;
  });

  test('system locale mapping', () {
    expect(I18n.fromLocale('ja_JP'), 'ja');
    expect(I18n.fromLocale('en_US'), 'en');
    expect(I18n.fromLocale('zh_TW'), 'zh');
    expect(I18n.fromLocale(null), 'zh');
  });
}
