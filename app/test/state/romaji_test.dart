import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/romaji.dart';

JaToken t(String s, String? r, String p, [String p1 = '*']) => JaToken(s, r, p, p1);

void main() {
  group('kanaToRomaji', () {
    test('basic, digraphs and loanword sounds', () {
      expect(kanaToRomaji('タベ'), 'tabe');
      expect(kanaToRomaji('シュウデン'), 'shuuden');
      expect(kanaToRomaji('チョウサ'), 'chousa');
      expect(kanaToRomaji('フィーリング'), 'fiiringu');
      expect(kanaToRomaji('ティー'), 'tii');
      expect(kanaToRomaji('ヴァイオリン'), 'vaiorin');
    });

    test('small tsu doubles the next consonant', () {
      expect(kanaToRomaji('キット'), 'kitto');
      expect(kanaToRomaji('マッチ'), 'matchi');
      expect(kanaToRomaji('ズット'), 'zutto');
      expect(kanaToRomaji('アッ'), 'a'); // nothing to double at the end
    });

    test("n' before a vowel or y", () {
      expect(kanaToRomaji('コンヤ'), "kon'ya");
      expect(kanaToRomaji('レンアイ'), "ren'ai");
      expect(kanaToRomaji('サンポ'), 'sanpo');
      expect(kanaToRomaji('ジカン'), 'jikan');
    });

    test('hiragana, small vowels and long marks', () {
      expect(kanaToRomaji('ねぇ'), 'nee');
      expect(kanaToRomaji('アイラブユー'), 'airabuyuu');
      expect(kanaToRomaji('あいしてる'), 'aishiteru');
    });
  });

  group('tokensToRomaji (kuromoji output from a real song)', () {
    test('inflections join, particles are separate words', () {
      expect(
        tokensToRomaji([
          t('食べ', 'タベ', '動詞', '自立'), t('なく', 'ナク', '助動詞'), t('ちゃ', 'チャ', '助詞', '接続助詞'),
          t('　', null, '記号', '空白'),
          t('食べ', 'タベ', '動詞', '自立'), t('なく', 'ナク', '助動詞'), t('ちゃ', 'チャ', '助詞', '接続助詞'),
        ]),
        'tabenakucha tabenakucha',
      );
      expect(
        tokensToRomaji([
          t('嫌', 'イヤ', '名詞', '形容動詞語幹'), t('な', 'ナ', '助動詞'), t('こと', 'コト', '名詞', '非自立'),
          t('忘れ', 'ワスレ', '動詞', '自立'), t('させ', 'サセ', '動詞', '接尾'), t('て', 'テ', '助詞', '接続助詞'),
          t('？', '？', '記号', '一般'),
        ]),
        'iya na koto wasuresasete?',
      );
    });

    test('は is read wa, punctuation is kept, unknown kanji keep their surface', () {
      expect(
        tokensToRomaji([
          t('満たさ', 'ミタサ', '動詞', '自立'), t('れ', 'レ', '動詞', '接尾'), t('ない', 'ナイ', '助動詞'),
          t('、', '、', '記号', '読点'), t('の', 'ノ', '名詞', '非自立'), t('は', 'ハ', '助詞', '係助詞'),
          t('、', '、', '記号', '読点'), t('フィーリング', 'フィーリング', '名詞', '一般'),
        ]),
        'mitasarenai, no wa, fiiringu',
      );
      expect(
        tokensToRomaji([
          t('君', 'キミ', '名詞', '代名詞'), t('の', 'ノ', '助詞', '連体化'), t('体温', 'タイオン', '名詞', '一般'),
          t('と', 'ト', '助詞', '並立助詞'), t('、', '、', '記号', '読点'), t('心', 'ココロ', '名詞', '一般'),
          t('、', '、', '記号', '読点'), t('臓', null, '名詞', '一般'), t('。', '。', '記号', '句点'),
        ]),
        'kimi no taion to, kokoro, 臓.',
      );
    });

    test('auxiliaries after a noun stay separate; katakana without reading', () {
      expect(
        tokensToRomaji([
          t('君', 'キミ', '名詞', '代名詞'), t('の', 'ノ', '助詞', '連体化'), t('すべて', 'スベテ', '名詞', '副詞可能'),
          t('が', 'ガ', '助詞', '格助詞'), t('あたし', 'アタシ', '名詞', '代名詞'), t('なら', 'ナラ', '助動詞'),
          t('いい', 'イイ', '形容詞', '自立'), t('のに', 'ノニ', '助詞', '接続助詞'),
        ]),
        'kimi no subete ga atashi nara ii noni',
      );
      expect(
        tokensToRomaji([t('アイ', null, '名詞', '一般'), t(' ', null, '記号', '空白'), t('アイヘイチュー', null, '名詞', '固有名詞')]),
        'ai aiheichuu',
      );
      expect(
        tokensToRomaji([
          t('理解', 'リカイ', '名詞', 'サ変接続'), t('さ', 'サ', '動詞', '自立'), t('れ', 'レ', '動詞', '接尾'),
          t('ない', 'ナイ', '助動詞'),
        ]),
        'rikai sarenai',
      );
    });
  });
}
