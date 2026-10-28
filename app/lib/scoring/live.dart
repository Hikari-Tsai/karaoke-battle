/// Real-time helper: compares a live pitch frame with the reference notes.
library;

import 'models.dart';

/// Colour category of a live frame.
enum LiveCategory {
  /// Within [LiveComparator.goodCents] of the reference note (chroma-wise).
  good,

  /// Within [LiveComparator.nearCents].
  near,

  /// Voiced but farther than [LiveComparator.nearCents] from the note.
  off,

  /// Voiced while the reference has no note at this time.
  noNote,

  /// Unvoiced (f0 <= 0 or low confidence).
  unvoiced,
}

/// Result of [LiveComparator.compare].
class LiveComparison {
  const LiveComparison({
    required this.category,
    this.noteIndex,
    this.note,
    this.centsDeviation,
  });

  final LiveCategory category;

  /// Index of the current reference note, if any.
  final int? noteIndex;
  final ReferenceNote? note;

  /// Signed chroma-wise deviation in cents, in `(-600, 600]`
  /// (null when unvoiced or without a note).
  final double? centsDeviation;

  Map<String, dynamic> toJson() => {
    'category': category.name,
    'note_index': noteIndex,
    'cents_deviation': centsDeviation,
  };
}

/// Maps `(time, f0)` live frames to the current reference note and a
/// chroma-wise cents deviation, after applying the chroma [shift] `k`
/// chosen by the scorer (0 before scoring).
class LiveComparator {
  LiveComparator(
    this.reference, {
    this.shift = 0,
    this.confidenceThreshold = 0.4,
    this.goodCents = 50,
    this.nearCents = 100,
    this.latencySeconds = 0,
  });

  final ReferenceNotes reference;

  /// Chroma shift in semitones added to the sung pitch (0..11).
  int shift;

  /// Frames with a confidence below this are reported as [LiveCategory.unvoiced].
  final double confidenceThreshold;
  final double goodCents;
  final double nearCents;

  /// Seconds subtracted from the frame time before the lookup
  /// (input/analysis latency compensation).
  final double latencySeconds;

  int _cursor = 0;

  /// Index of the note covering [time] (`onset <= time < offset`), or null.
  int? noteIndexAt(double time) {
    final notes = reference.notes;
    if (notes.isEmpty) return null;
    // Fast path: monotonic playback keeps the cursor near the answer.
    var i = _cursor.clamp(0, notes.length - 1);
    if (time < notes[i].onset) {
      i = _lowerBound(time);
    } else {
      while (i + 1 < notes.length && notes[i + 1].onset <= time) {
        i++;
      }
    }
    _cursor = i;
    final n = notes[i];
    return (time >= n.onset && time < n.offset) ? i : null;
  }

  /// Last note index with `onset <= time` (0 when time precedes all notes).
  int _lowerBound(double time) {
    final notes = reference.notes;
    var lo = 0;
    var hi = notes.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (notes[mid].onset <= time) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Compares a live frame at [time] (s) with F0 [f0Hz].
  LiveComparison compare(double time, double f0Hz, {double confidence = 1.0}) {
    final idx = noteIndexAt(time - latencySeconds);
    final note = idx == null ? null : reference.notes[idx];
    final voiced =
        f0Hz > 0 && f0Hz.isFinite && confidence >= confidenceThreshold;
    if (!voiced) {
      return LiveComparison(
        category: LiveCategory.unvoiced,
        noteIndex: idx,
        note: note,
      );
    }
    if (note == null) {
      return const LiveComparison(category: LiveCategory.noNote);
    }
    final cents = chromaDelta(hzToMidi(f0Hz) + shift, note.pitch) * 100.0;
    final a = cents.abs();
    final cat = a <= goodCents
        ? LiveCategory.good
        : a <= nearCents
        ? LiveCategory.near
        : LiveCategory.off;
    return LiveComparison(
      category: cat,
      noteIndex: idx,
      note: note,
      centsDeviation: cents,
    );
  }

  /// Compares an engine live frame `[time, f0_hz, confidence, rms_db, source]`.
  LiveComparison compareFrame(List<double> frame) => compare(
    frame[0],
    frame.length > 1 ? frame[1] : 0.0,
    confidence: frame.length > 2 ? frame[2] : 1.0,
  );

  /// Resets the internal note cursor (call when seeking).
  void reset() => _cursor = 0;
}
