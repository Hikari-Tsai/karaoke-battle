// RMS loudness curve (dB) from a WAV file, for the scorer's expression metric.
// Handles PCM16 / float32 RIFF WAVs (as written by ffmpeg and the engine),
// any channel count (averaged to mono), streamed in chunks.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class EnergyData {
  EnergyData(this.times, this.rmsDb);
  final List<double> times;
  final List<double> rmsDb;
  Map<String, dynamic> toJson() => {'times': times, 'rms_db': rmsDb};
}

/// Returns null when the file is missing or not a supported WAV.
Future<EnergyData?> wavEnergyCurve(String path, {double hop = 0.016, double timeOffset = 0}) async {
  final f = File(path);
  if (!await f.exists()) return null;
  final raf = await f.open();
  try {
    final header = await raf.read(12);
    if (header.length < 12 || String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' || String.fromCharCodes(header.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    int? format, channels, sampleRate, bits;
    int dataOffset = -1, dataLength = 0;
    var pos = 12;
    final len = await raf.length();
    while (pos + 8 <= len) {
      await raf.setPosition(pos);
      final ch = await raf.read(8);
      if (ch.length < 8) break;
      final id = String.fromCharCodes(ch.sublist(0, 4));
      final size = ByteData.sublistView(ch).getUint32(4, Endian.little);
      if (id == 'fmt ') {
        final fmt = ByteData.sublistView(await raf.read(math.min(size, 40)));
        format = fmt.getUint16(0, Endian.little);
        channels = fmt.getUint16(2, Endian.little);
        sampleRate = fmt.getUint32(4, Endian.little);
        bits = fmt.getUint16(14, Endian.little);
        if (format == 0xFFFE && size >= 26) format = fmt.getUint16(24, Endian.little); // WAVE_FORMAT_EXTENSIBLE
      } else if (id == 'data') {
        dataOffset = pos + 8;
        dataLength = math.min(size, len - dataOffset);
        break;
      }
      pos += 8 + size + (size & 1);
    }
    if (format == null || channels == null || sampleRate == null || bits == null || dataOffset < 0) return null;
    final isFloat = format == 3 && bits == 32;
    final isPcm16 = format == 1 && bits == 16;
    if (!isFloat && !isPcm16) return null;
    final bytesPerSample = bits ~/ 8;
    final frameBytes = bytesPerSample * channels;
    final hopFrames = math.max(1, (hop * sampleRate).round());
    final totalFrames = dataLength ~/ frameBytes;
    final nHops = totalFrames ~/ hopFrames;
    final times = List<double>.filled(nHops, 0);
    final rms = List<double>.filled(nHops, -90);
    await raf.setPosition(dataOffset);
    final chunkHops = math.max(1, (4 * 1024 * 1024) ~/ (hopFrames * frameBytes));
    var h = 0;
    while (h < nHops) {
      final hopsNow = math.min(chunkHops, nHops - h);
      final bytes = await raf.read(hopsNow * hopFrames * frameBytes);
      final bd = ByteData.sublistView(bytes);
      for (var k = 0; k < hopsNow; k++) {
        var acc = 0.0;
        final base = k * hopFrames * frameBytes;
        for (var i = 0; i < hopFrames; i++) {
          var s = 0.0;
          for (var c = 0; c < channels; c++) {
            final o = base + (i * channels + c) * bytesPerSample;
            s += isFloat ? bd.getFloat32(o, Endian.little) : bd.getInt16(o, Endian.little) / 32768.0;
          }
          s /= channels;
          acc += s * s;
        }
        final r = math.sqrt(acc / hopFrames);
        times[h + k] = (h + k) * hopFrames / sampleRate + timeOffset;
        rms[h + k] = r > 1e-6 ? 20 * math.log(r) / math.ln10 : -120;
      }
      h += hopsNow;
    }
    return EnergyData(times, rms);
  } catch (_) {
    return null;
  } finally {
    await raf.close();
  }
}
