// Lyrics actions shared by the song card, the sing screen and the
// no-lyrics dialog: importing a subtitle file, opening the editor, and the
// label a track is shown with.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/lyrics.dart';
import 'lyrics_editor_screen.dart';
import 'paste_lyrics_dialog.dart';
import 'recognize_dialog.dart';

/// How a track is named in menus.
String lyricTrackLabel(LyricTrack t) => switch (t.source) {
      LyricSource.youtube => t.auto ? '${t.lang} (${tr('sing.lyricsAuto')})' : t.lang,
      LyricSource.imported => tr('lyrics.src.imported', {'name': t.label ?? t.lang}),
      LyricSource.edited => '${baseLang(t.lang)} · ${tr('lyrics.src.edited')}',
      LyricSource.manual => tr('lyrics.src.manual'),
      LyricSource.whisper => tr('lyrics.src.whisper'),
      LyricSource.aligned => tr('lyrics.src.aligned'),
    };

/// Asks for a subtitle file and makes it [song]'s main lyrics. True when
/// one was imported; problems are shown in a snack bar.
Future<bool> pickAndImportLyrics(BuildContext context, Song song) async {
  final pipeline = context.read<AppServices>().pipeline;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final picked = await FilePicker.pickFiles(dialogTitle: tr('lyrics.pickTitle'), type: FileType.custom, allowedExtensions: kSubtitleExtensions);
  final path = picked.isEmpty ? null : picked.first.path;
  if (path == null) return false;
  try {
    final track = await pipeline.importSubtitles(song, path);
    messenger?.showSnackBar(SnackBar(content: Text(tr('lyrics.imported', {'name': track.label ?? '', 'n': '${track.lines.length}'}))));
    return true;
  } on SubtitleFormatException catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(tr(e.reason == 'encoding' ? 'lyrics.errEncoding' : 'lyrics.errFormat'))));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('$e')));
  }
  return false;
}

/// Recognises the lyrics with Whisper (asking to download the model the
/// first time); true when lyrics were saved.
Future<bool> recognizeLyrics(BuildContext context, Song song) => showRecognizeDialog(context, song, const RecognizeRequest.recognize());

/// Asks for the lyrics as text and times them; true when saved.
Future<bool> pasteLyrics(BuildContext context, Song song) async {
  final req = await showPasteLyricsDialog(context);
  if (req == null || !context.mounted) return false;
  return showRecognizeDialog(context, song, req);
}

/// Opens the lyrics editor; true when the user saved.
Future<bool> openLyricsEditor(BuildContext context, Song song) async {
  final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => LyricsEditorScreen(song: song)));
  return saved ?? false;
}
