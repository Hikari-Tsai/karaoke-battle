import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/streaming_apps.dart';
import 'package:karaoke_battle/state/i18n.dart';
import 'package:karaoke_battle/state/stream_privacy.dart';

void main() {
  const id = 'C1B8B9E32C2467466E4A8B4CE4A99378';

  test('paths lose the home folder, account and computer name; alert IDs are hidden', () {
    String m(String s) => maskPrivate(s, home: '/Users/hikari', user: 'hikari', host: 'Hikaris-MacBook.local');
    expect(m('/Users/hikari/Library/Application Support/KaraokeBattle'), '~/Library/Application Support/KaraokeBattle');
    expect(m('/Volumes/hikari-ssd/songs'), '/Volumes/•••-ssd/songs');
    expect(m('scp to Hikaris-MacBook failed'), 'scp to ••• failed');
    expect(m('https://payment.ecpay.com.tw/Broadcaster/AlertBox/$id'), 'https://payment.ecpay.com.tw/Broadcaster/AlertBox/••••••••');
    expect(m('https://payment-stage.opay.tw/Broadcaster/Donate/${id.toLowerCase()}'), 'https://payment-stage.opay.tw/Broadcaster/Donate/••••••••');
    expect(m('nothing private'), 'nothing private');
  });

  test('only in 直播模式, and tr() masks what it fills in', () {
    final path = '/x/Broadcaster/AlertBox/$id';
    StreamPrivacy.live.value = false;
    expect(StreamPrivacy.mask(path), path);
    expect(tr('cheer.testFail', {'error': path}), contains(id));
    StreamPrivacy.live.value = true;
    addTearDown(() => StreamPrivacy.live.value = false);
    expect(StreamPrivacy.mask(path), '/x/Broadcaster/AlertBox/••••••••');
    expect(tr('cheer.testFail', {'error': path}), isNot(contains(id)));
  });

  test('the watch turns 直播模式 on and off with the streaming app', () async {
    var running = true;
    final w = StreamingWatch(interval: const Duration(hours: 1), check: () async => running);
    addTearDown(() {
      w.dispose();
      StreamPrivacy.live.value = false;
    });
    await w.poll();
    expect((w.live, StreamPrivacy.live.value), (true, true));
    running = false;
    await w.poll();
    expect(StreamPrivacy.live.value, isFalse);
  });

  test('more streaming apps count', () {
    for (final n in ['vMix64.exe', 'vMix', 'PRISMLiveStudio', 'PRISM Live Studio.exe', 'Twitch Studio', 'TikTok LIVE Studio.exe', 'Meld Studio', 'Ecamm Live', 'Wirecast']) {
      expect(isStreamingApp(n), isTrue, reason: n);
    }
    expect(isStreamingApp('Prism'), isFalse);
  });

  test('開發模式 can fake a streaming app', () async {
    final w = StreamingWatch(interval: const Duration(hours: 1), check: () async => false);
    addTearDown(() {
      w.dispose();
      StreamPrivacy.simulate.value = false;
      StreamPrivacy.live.value = false;
    });
    await w.poll();
    expect(StreamPrivacy.live.value, isFalse);
    StreamPrivacy.simulate.value = true;
    await w.poll();
    expect(StreamPrivacy.live.value, isTrue);
    StreamPrivacy.simulate.value = false;
    await w.poll();
    expect(StreamPrivacy.live.value, isFalse);
  });
}
