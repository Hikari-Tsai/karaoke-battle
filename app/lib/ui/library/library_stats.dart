// The library's totals as a stats card: songs, ready to sing, songs sung,
// takes, time sung and the best take (tap it for its result). Shown at the
// top of the Library and on the profile page. Counts every scored take (the
// History's start point does not apply here).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../services/sing_history.dart';
import '../../services/song_library.dart';
import '../../state/i18n.dart';
import '../results/results_screen.dart';
import '../widgets/rank.dart';
import '../widgets/stats_card.dart';

class LibraryStats extends StatefulWidget {
  const LibraryStats({super.key});

  @override
  State<LibraryStats> createState() => _LibraryStatsState();
}

class _LibraryStatsState extends State<LibraryStats> {
  late final SongLibrary _library = context.read<SongLibrary>();
  HistoryStats? _stats;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _library.addListener(_load);
    _library.takesChanged.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _library.removeListener(_load);
    _library.takesChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    final entries = await loadSingHistory(_library);
    if (mounted && seq == _seq) setState(() => _stats = summarizeHistory(entries));
  }

  @override
  Widget build(BuildContext context) {
    // The songs shown in the Library (hidden ones left out).
    final hidden = context.watch<AppSettings>().hiddenSongs;
    final songs = context.watch<SongLibrary>().songs.where((s) => !hidden.contains(s.id)).toList();
    final stats = _stats;
    String whole(double v) => '${v.round()}';
    final best = stats?.best;
    final ready = songs.where((s) => s.stage == PrepStage.done).length;
    return StatsCard(icon: Icons.library_music_outlined, title: tr('library.statsTitle'), tiles: [
      StatTile(icon: Icons.library_music_outlined, color: const Color(0xFFBF5AF2), label: tr('library.stat.songs'), value: songs.length.toDouble(), format: whole),
      StatTile(icon: Icons.check_circle_outline, color: const Color(0xFF30D158), label: tr('library.stat.ready'), value: ready.toDouble(), format: whole),
      StatTile(icon: Icons.mic_none, color: const Color(0xFFFF4FA3), label: tr('library.stat.sung'), value: (stats?.songs ?? 0).toDouble(), format: whole),
      StatTile(icon: Icons.equalizer, color: const Color(0xFFFF9F0A), label: tr('history.stat.takes'), value: (stats?.takes ?? 0).toDouble(), format: whole),
      StatTile(
        icon: Icons.timer_outlined,
        color: const Color(0xFF64D2FF),
        label: tr('history.stat.time'),
        value: (stats?.sung.inSeconds ?? 0).toDouble(),
        format: (v) => formatSungTime(Duration(seconds: v.round())),
      ),
      if (best != null)
        StatTile(
          icon: Icons.emoji_events_outlined,
          color: trophyColor,
          label: tr('history.stat.best'),
          value: best.take.total!,
          format: (v) => v.toStringAsFixed(1),
          valueColor: rankColor(best.take.rank),
          trailing: RankChip(rank: best.take.rank, fontSize: 12),
          note: best.song.title,
          highlight: true,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultsScreen(song: best.song, take: best.take))),
        ),
    ]);
  }
}
