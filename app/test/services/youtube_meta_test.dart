import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/youtube_meta.dart';

void main() {
  test('music metadata first, then the channel without " - Topic" or VEVO', () {
    expect(youtubeArtist({'artists': ['YOASOBI', 'Ayase'], 'artist': 'YOASOBI, Ayase', 'channel': 'Ayase / YOASOBI'}), 'YOASOBI');
    expect(youtubeArtist({'artist': '周杰倫, 費玉清', 'channel': '杰威爾音樂 JVR Music'}), '周杰倫');
    expect(youtubeArtist({'creator': 'Ado', 'channel': 'Ado'}), 'Ado');
    expect(youtubeArtist({'channel': 'Aimer - Topic'}), 'Aimer');
    expect(youtubeArtist({'channel': 'TaylorSwiftVEVO'}), 'TaylorSwift');
    expect(youtubeArtist({'uploader': '多帕 Topa'}), '多帕 Topa', reason: 'a cover: the one singing it');
    expect(youtubeArtist({'title': 'no names here'}), isNull);
    expect(youtubeArtist({'artist': '  ', 'channel': ''}), isNull);
  });

  test('the release year (not the upload date) and the language', () {
    expect(youtubeYear({'track': '晴天', 'release_year': 2003, 'upload_date': '20200101'}), 2003);
    expect(youtubeYear({'track': 'Lemon', 'release_date': '19850601'}), 1985);
    expect(youtubeYear({'release_year': 2026, 'title': '【歌ってみた】食虫植物'}), isNull, reason: 'a cover\'s premiere is not the song\'s year');
    expect(youtubeYear({'upload_date': '20200101'}), isNull, reason: 'an upload is not a release');
    expect(youtubeLanguage({'language': 'ja'}), 'ja');
    expect(youtubeLanguage({'language': 'zh-TW'}), 'zh');
    expect(youtubeLanguage({'language': 'zh-HK'}), 'yue');
    expect(youtubeLanguage({'language': 'en-US'}), 'en');
    expect(youtubeLanguage({'language': 'fr'}), isNull);
    expect(youtubeLanguage({}), isNull);
  });
}
