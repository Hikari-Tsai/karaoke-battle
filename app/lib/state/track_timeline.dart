// A take's track timeline: what played under the singer and when it changed
// (accompaniment, original mix or MIDI guide), on the song timeline.

/// One entry of a take's track timeline: from [t] seconds on the song
/// timeline, [track] (`inst`, `mix` or `midi`) played under the singer.
class TrackSwitch {
  const TrackSwitch(this.t, this.track);
  final double t;
  final String track;

  Map<String, dynamic> toJson() => {'t': t, 'track': track};

  static const _tracks = {'inst', 'mix', 'midi'};

  /// A take's `track_timeline`, or [] when missing or malformed (older takes).
  static List<TrackSwitch> listFromJson(Object? j, {int max = 1000}) {
    if (j is! List) return const [];
    final out = <TrackSwitch>[];
    for (final e in j.take(max)) {
      if (e is! Map) return const [];
      final t = e['t'], track = e['track'];
      if (t is! num ||
          !t.isFinite ||
          t < 0 ||
          track is! String ||
          !_tracks.contains(track))
        return const [];
      out.add(TrackSwitch(t.toDouble(), track));
    }
    return out;
  }
}
