import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/i18n.dart';

void main() {
  tearDown(() => I18n.notifier.value = 'zh');

  test('every key resolves in all three languages and differs from the key', () {
    final keys = ['nav.library', 'sing.record', 'results.total', 'settings.uiLanguage', 'backend.cudaMissing.body', 'library.deleteConfirm', 'settings.ytDlpInstalled', 'settings.ytDlpInstallFailed', 'settings.ytDlpUpdateFailed', 'sidecars.ytDlpInstalling', 'sidecars.ytDlpInstalled', 'ytdlp.title', 'ytdlp.broken', 'ytdlp.pathOnly', 'ytdlp.failed', 'ytdlp.repair', 'ytdlp.working', 'ytdlp.done', 'ytdlp.dontRemind', 'sing.modePreview', 'sing.modePreviewTip', 'sing.modeRecording', 'sing.modeCountdown', 'sing.countdownHint', 'sing.cancelRecord', 'sing.midiGuide', 'sing.midiGuideTip', 'settings.wideKeyRange', 'settings.wideKeyRangeHint', 'backing.import', 'backing.title', 'backing.warn.drift', 'backing.warn.key', 'backing.warn.bands', 'backing.offsetPad', 'backing.offsetCut', 'backing.previewHint', 'backing.revertBody', 'library.exportMidi', 'library.midiNoNotes', 'library.midiSaved', 'export.lyrics', 'replays.lyricsAdded', 'export.localSong', 'export.includeSong', 'export.excludeSong', 'export.songSize', 'export.includeSongNote', 'export.excludeSongNote', 'export.chooseSong', 'replays.includedSong', 'replays.useIncluded', 'replays.includedAskTitle', 'replays.includedAskBody', 'library.coverSet', 'library.coverChange', 'library.coverRemove', 'library.coverPick', 'library.coverFailed', 'export.withCover', 'export.withBacking', 'export.extras', 'export.and', 'replays.backingAdded', 'results.best', 'results.bestBroken', 'celebrate.title', 'celebrate.beat', 'celebrate.skip', 'settings.resultSounds', 'settings.resultSoundsHint', 'nav.history', 'history.title', 'history.clear', 'history.empty', 'history.emptyHint', 'history.stat.takes', 'history.stat.songs', 'history.stat.time', 'history.stat.days', 'history.stat.avg', 'history.stat.best', 'history.hm', 'history.ms', 'history.range', 'results.locked', 'results.aiAdvice', 'results.aiMore', 'history.today', 'history.yesterday', 'history.clearTitle', 'history.clearBody', 'history.remove', 'history.removeTitle', 'history.removeBody', 'history.deleteTake', 'history.deleteTakeHint', 'history.removeAndDelete', 'history.removed', 'history.removedDeleted', 'history.undo', 'library.hide', 'library.deleteTake', 'library.deleteTakeTitle', 'library.deleteTakeBody', 'library.deleteTakeBest', 'library.takeDeleted', 'dev.mode', 'dev.modeHint', 'debug.importTake', 'debug.importBody', 'debug.importAlign', 'debug.importAlignHint', 'debug.importScore', 'debug.importScoreHint', 'debug.importGo', 'debug.importing', 'debug.imported', 'library.hidden', 'library.hiddenSongs', 'library.hiddenTitle', 'library.hiddenHint', 'library.hiddenNone', 'library.unhide', 'library.unhideAll', 'library.allHidden', 'history.cleared', 'about.thanks', 'setlist.header', 'setlist.title', 'setlist.today', 'setlist.button', 'setlist.clock', 'setlist.timeline', 'setlist.streamStart', 'setlist.timelineHint', 'setlist.scores', 'setlist.copy', 'setlist.copied', 'setlist.save', 'setlist.saved', 'setlist.fileName', 'setlist.obsTitle', 'setlist.obsHint', 'setlist.reveal', 'setlist.copyPath', 'setlist.pathCopied', 'lyrics.export', 'lyrics.exportTitle', 'lyrics.exportTrack', 'lyrics.exportPrimary', 'lyrics.exportLines', 'lyrics.exportFormat', 'lyrics.exportSrtHint', 'lyrics.exportLrcHint', 'lyrics.exportSave', 'lyrics.exportNone', 'demo.title', 'demo.lead', 'demo.song', 'demo.singer', 'demo.vb', 'demo.live', 'demo.judge', 'demo.ai', 'demo.c992', 'demo.c987', 'demo.download', 'demo.size', 'demo.downloading', 'demo.importing', 'demo.saved', 'demo.inReplays', 'demo.open', 'demo.failed', 'demo.watch', 'demo.videoLoading', 'demo.videoFailed', 'history.statsTitle', 'history.dayTakes', 'library.statsTitle', 'library.stat.songs', 'library.stat.ready', 'library.stat.sung', 'history.since', 'history.startTitle', 'history.startBody', 'history.startPick', 'history.startNow', 'history.startAll', 'history.startTip', 'history.emptySince', 'setlist.headerSince', 'setlist.headerAll', 'history.startTime', 'results.lyric', 'results.lyricHint', 'sing.videoOn', 'sing.videoOff', 'settings.showVideo', 'settings.showVideoHint', 'nav.profile', 'profile.title', 'profile.look', 'profile.female', 'profile.male', 'profile.name', 'profile.noName', 'profile.editName', 'profile.neutral', 'profile.cat', 'profile.dog', 'profile.rabbit', 'profile.bear', 'charts.measureRange', 'charts.remeasureRange', 'ach.title', 'ach.count', 'ach.points', 'ach.statsTitle', 'ach.stat.unlocked', 'ach.stat.points', 'ach.stat.medal1', 'ach.stat.medal2', 'ach.stat.medal3', 'ach.stat.latest', 'ach.tier1', 'ach.tier2', 'ach.tier3', 'ach.done', 'ach.on', 'ach.secretDesc', 'ach.unlocked', 'ach.firstRun', 'ach.more', 'ach.unlockedMany', 'ach.pointsGained', 'ach.tapToClose', 'move.button', 'move.title', 'move.intro', 'move.s1.title', 'move.s1.body', 'move.s2.title', 'move.s2.body', 'move.s3.title', 'move.s3.body', 'move.s4.title', 'move.s4.body', 'move.kept.title', 'move.kept.body', 'move.notKept.title', 'move.notKept.body', 'move.crossOs.title', 'move.crossOs.body', 'move.env.title', 'move.env.body', 'profile.identity', 'profile.identityHint', 'profile.userId', 'profile.devices', 'profile.noDevice', 'profile.thisDevice', 'profile.deviceSeen', 'profile.copy', 'profile.copied'];
    for (final lang in I18n.supported) {
      I18n.notifier.value = lang;
      for (final k in keys) {
        final s = tr(k, {'gpu': 'X', 'size': '1 GB', 'title': 'T', 'error': 'E', 'path': 'P', 'ppm': 5, 'n': 2, 'ms': '7.0', 's': '0.7', 'names': 'a.srt', 'mb': '5', 'items': 'x', 'best': '9', 'prev': '8', 'score': '9', 'songs': 3, 'date': '2026-11-20', 'time': '20:00', 'h': 1, 'm': 2, 'delay': '0.7', 'from': 'a', 'to': 'b', 'name': 'N', 'pct': 50, 'total': 47, 'first': '2026-11-01', 'last': '2026-11-21'});
        expect(s, isNot(equals(k)), reason: '$k missing in $lang');
        expect(s, isNot(contains('{')), reason: '$k has unreplaced args in $lang');
      }
    }
  });

  test('every sub-score has its rule and tips for the results question marks', () {
    for (final lang in I18n.supported) {
      I18n.notifier.value = lang;
      for (final k in ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'longTone']) {
        for (final key in ['rules.$k', 'results.tip.$k', 'results.$k']) {
          expect(tr(key), isNot(equals(key)), reason: '$key missing in $lang');
        }
      }
      for (final key in ['results.tipRule', 'results.tipHow', 'results.tipMore', 'results.scoringGuide']) {
        expect(tr(key), isNot(equals(key)), reason: '$key missing in $lang');
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
