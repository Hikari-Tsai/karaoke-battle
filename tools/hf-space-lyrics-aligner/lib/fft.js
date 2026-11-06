// Mixed-radix complex FFT (radix 4, 2, 3, 5 and a generic one), a port of
// KISS FFT's kf_work / butterflies. Needed because MDX-Net uses n_fft 7680
// and Whisper n_fft 400, neither a power of two.
//
// Data is interleaved [re0, im0, re1, im1, ...] in Float64Arrays.
//
// The mixed-radix structure follows KISS FFT:
//   Copyright (c) 2003-2010, Mark Borgerding. All rights reserved.
//   Redistribution and use in source and binary forms, with or without
//   modification, are permitted provided that the following conditions are met:
//   * Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//   * Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//   * Neither the author nor the names of any contributors may be used to
//     endorse or promote products derived from this software without specific
//     prior written permission.
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//   AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//   IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//   ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
//   LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//   CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//   SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//   INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//   CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//   ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//   POSSIBILITY OF SUCH DAMAGE.

export class FFT {
  constructor(n, inverse = false) {
    this.n = n;
    this.inverse = inverse;
    this.tw = new Float64Array(2 * n);
    const sign = inverse ? 1 : -1;
    for (let i = 0; i < n; i++) {
      const ph = (sign * 2 * Math.PI * i) / n;
      this.tw[2 * i] = Math.cos(ph);
      this.tw[2 * i + 1] = Math.sin(ph);
    }
    this.factors = [];
    let p = 4;
    let m = n;
    do {
      while (m % p) {
        if (p === 4) p = 2;
        else if (p === 2) p = 3;
        else p += 2;
        if (p * p > m) p = m;
      }
      m /= p;
      this.factors.push(p, m);
    } while (m > 1);
    this.scratch = new Float64Array(2 * Math.max(...this.factors.filter((_, i) => i % 2 === 0)));
  }

  /** out = FFT(input); both interleaved complex of length n (no scaling). */
  transform(input, out) {
    this.work(out, 0, input, 0, 1, 0);
    return out;
  }

  work(out, o, f, fi, fstride, fac) {
    const p = this.factors[fac];
    const m = this.factors[fac + 1];
    const end = o + 2 * p * m;
    if (m === 1) {
      for (let k = o; k < end; k += 2) {
        out[k] = f[fi];
        out[k + 1] = f[fi + 1];
        fi += 2 * fstride;
      }
    } else {
      for (let k = o; k < end; k += 2 * m) {
        this.work(out, k, f, fi, fstride * p, fac + 2);
        fi += 2 * fstride;
      }
    }
    switch (p) {
      case 2: this.bfly2(out, o, fstride, m); break;
      case 3: this.bfly3(out, o, fstride, m); break;
      case 4: this.bfly4(out, o, fstride, m); break;
      case 5: this.bfly5(out, o, fstride, m); break;
      default: this.bflyGeneric(out, o, fstride, m, p);
    }
  }

  bfly2(F, o, fstride, m) {
    const tw = this.tw;
    for (let k = 0; k < m; k++) {
      const a = o + 2 * k;
      const b = a + 2 * m;
      const wr = tw[2 * k * fstride], wi = tw[2 * k * fstride + 1];
      const tr = F[b] * wr - F[b + 1] * wi;
      const ti = F[b] * wi + F[b + 1] * wr;
      F[b] = F[a] - tr;
      F[b + 1] = F[a + 1] - ti;
      F[a] += tr;
      F[a + 1] += ti;
    }
  }

  bfly3(F, o, fstride, m) {
    const tw = this.tw;
    const epi3i = tw[2 * fstride * m + 1];
    for (let k = 0; k < m; k++) {
      const a = o + 2 * k, b = a + 2 * m, c = a + 4 * m;
      const w1r = tw[2 * k * fstride], w1i = tw[2 * k * fstride + 1];
      const w2r = tw[4 * k * fstride], w2i = tw[4 * k * fstride + 1];
      const s1r = F[b] * w1r - F[b + 1] * w1i, s1i = F[b] * w1i + F[b + 1] * w1r;
      const s2r = F[c] * w2r - F[c + 1] * w2i, s2i = F[c] * w2i + F[c + 1] * w2r;
      const s3r = s1r + s2r, s3i = s1i + s2i;
      const s0r = (s1r - s2r) * epi3i, s0i = (s1i - s2i) * epi3i;
      const br = F[a] - s3r * 0.5, bi = F[a + 1] - s3i * 0.5;
      F[a] += s3r;
      F[a + 1] += s3i;
      F[c] = br + s0i;
      F[c + 1] = bi - s0r;
      F[b] = br - s0i;
      F[b + 1] = bi + s0r;
    }
  }

  bfly4(F, o, fstride, m) {
    const tw = this.tw;
    const inv = this.inverse;
    for (let k = 0; k < m; k++) {
      const a = o + 2 * k, b = a + 2 * m, c = a + 4 * m, d = a + 6 * m;
      const w1 = 2 * k * fstride, w2 = 4 * k * fstride, w3 = 6 * k * fstride;
      const s0r = F[b] * tw[w1] - F[b + 1] * tw[w1 + 1], s0i = F[b] * tw[w1 + 1] + F[b + 1] * tw[w1];
      const s1r = F[c] * tw[w2] - F[c + 1] * tw[w2 + 1], s1i = F[c] * tw[w2 + 1] + F[c + 1] * tw[w2];
      const s2r = F[d] * tw[w3] - F[d + 1] * tw[w3 + 1], s2i = F[d] * tw[w3 + 1] + F[d + 1] * tw[w3];
      const s5r = F[a] - s1r, s5i = F[a + 1] - s1i;
      const ar = F[a] + s1r, ai = F[a + 1] + s1i;
      const s3r = s0r + s2r, s3i = s0i + s2i;
      const s4r = s0r - s2r, s4i = s0i - s2i;
      F[c] = ar - s3r;
      F[c + 1] = ai - s3i;
      F[a] = ar + s3r;
      F[a + 1] = ai + s3i;
      if (inv) {
        F[b] = s5r - s4i; F[b + 1] = s5i + s4r;
        F[d] = s5r + s4i; F[d + 1] = s5i - s4r;
      } else {
        F[b] = s5r + s4i; F[b + 1] = s5i - s4r;
        F[d] = s5r - s4i; F[d + 1] = s5i + s4r;
      }
    }
  }

  bfly5(F, o, fstride, m) {
    const tw = this.tw;
    const yar = tw[2 * fstride * m], yai = tw[2 * fstride * m + 1];
    const ybr = tw[4 * fstride * m], ybi = tw[4 * fstride * m + 1];
    for (let u = 0; u < m; u++) {
      const i0 = o + 2 * u, i1 = i0 + 2 * m, i2 = i0 + 4 * m, i3 = i0 + 6 * m, i4 = i0 + 8 * m;
      const s0r = F[i0], s0i = F[i0 + 1];
      const t1 = 2 * u * fstride, t2 = 4 * u * fstride, t3 = 6 * u * fstride, t4 = 8 * u * fstride;
      const s1r = F[i1] * tw[t1] - F[i1 + 1] * tw[t1 + 1], s1i = F[i1] * tw[t1 + 1] + F[i1 + 1] * tw[t1];
      const s2r = F[i2] * tw[t2] - F[i2 + 1] * tw[t2 + 1], s2i = F[i2] * tw[t2 + 1] + F[i2 + 1] * tw[t2];
      const s3r = F[i3] * tw[t3] - F[i3 + 1] * tw[t3 + 1], s3i = F[i3] * tw[t3 + 1] + F[i3 + 1] * tw[t3];
      const s4r = F[i4] * tw[t4] - F[i4 + 1] * tw[t4 + 1], s4i = F[i4] * tw[t4 + 1] + F[i4 + 1] * tw[t4];
      const s7r = s1r + s4r, s7i = s1i + s4i;
      const s10r = s1r - s4r, s10i = s1i - s4i;
      const s8r = s2r + s3r, s8i = s2i + s3i;
      const s9r = s2r - s3r, s9i = s2i - s3i;
      F[i0] = s0r + s7r + s8r;
      F[i0 + 1] = s0i + s7i + s8i;
      const s5r = s0r + s7r * yar + s8r * ybr, s5i = s0i + s7i * yar + s8i * ybr;
      const s6r = s10i * yai + s9i * ybi, s6i = -(s10r * yai) - s9r * ybi;
      F[i1] = s5r - s6r; F[i1 + 1] = s5i - s6i;
      F[i4] = s5r + s6r; F[i4 + 1] = s5i + s6i;
      const s11r = s0r + s7r * ybr + s8r * yar, s11i = s0i + s7i * ybr + s8i * yar;
      const s12r = -(s10i * ybi) + s9i * yai, s12i = s10r * ybi - s9r * yai;
      F[i2] = s11r + s12r; F[i2 + 1] = s11i + s12i;
      F[i3] = s11r - s12r; F[i3 + 1] = s11i - s12i;
    }
  }

  bflyGeneric(F, o, fstride, m, p) {
    const tw = this.tw;
    const n = this.n;
    const s = this.scratch;
    for (let u = 0; u < m; u++) {
      for (let q1 = 0, k = u; q1 < p; q1++, k += m) {
        s[2 * q1] = F[o + 2 * k];
        s[2 * q1 + 1] = F[o + 2 * k + 1];
      }
      for (let q1 = 0, k = u; q1 < p; q1++, k += m) {
        let twidx = 0;
        let r = s[0], i = s[1];
        for (let q = 1; q < p; q++) {
          twidx += fstride * k;
          if (twidx >= n) twidx -= n;
          const wr = tw[2 * twidx], wi = tw[2 * twidx + 1];
          r += s[2 * q] * wr - s[2 * q + 1] * wi;
          i += s[2 * q] * wi + s[2 * q + 1] * wr;
        }
        F[o + 2 * k] = r;
        F[o + 2 * k + 1] = i;
      }
    }
  }
}

/** Periodic Hann window (torch.hann_window default). */
export function hannPeriodic(n) {
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n);
  return w;
}

/**
 * STFT / ISTFT with torch semantics (center=True, reflect padding, onesided,
 * not normalised), as the app's engine/src/dsp/stft.cpp.
 */
export class Stft {
  constructor(nFft, hop) {
    this.nFft = nFft;
    this.hop = hop;
    this.bins = nFft / 2 + 1;
    this.window = hannPeriodic(nFft);
    this.fwd = new FFT(nFft, false);
    this.inv = new FFT(nFft, true);
    this.bufIn = new Float64Array(2 * nFft);
    this.bufOut = new Float64Array(2 * nFft);
  }

  numFrames(samples) {
    return 1 + Math.floor(samples / this.hop);
  }

  /**
   * Forward STFT of x (n samples). Calls emit(frame, re, im) with the
   * bins of each frame (views valid only during the call).
   */
  forward(x, n, emit) {
    const { nFft, hop, window, bufIn, bufOut, bins } = this;
    const pad = nFft / 2;
    const frames = this.numFrames(n);
    const re = new Float64Array(bins), im = new Float64Array(bins);
    for (let f = 0; f < frames; f++) {
      for (let j = 0; j < nFft; j++) {
        let i = f * hop + j - pad;
        if (i < 0) i = -i;
        if (i >= n) i = 2 * n - 2 - i;
        bufIn[2 * j] = x[i] * window[j];
        bufIn[2 * j + 1] = 0;
      }
      this.fwd.transform(bufIn, bufOut);
      for (let k = 0; k < bins; k++) {
        re[k] = bufOut[2 * k];
        im[k] = bufOut[2 * k + 1];
      }
      emit(f, re, im);
    }
    return frames;
  }

  /**
   * Inverse STFT: getFrame(f, re, im) fills the bins of frame f; returns
   * `length` samples (overlap-add, window-square normalisation, centre trim).
   */
  inverse(frames, length, getFrame) {
    const { nFft, hop, window, bufIn, bufOut, bins } = this;
    const pad = nFft / 2;
    const total = (frames - 1) * hop + nFft;
    const acc = new Float64Array(total), wsum = new Float64Array(total);
    const re = new Float64Array(bins), im = new Float64Array(bins);
    const scale = 1 / nFft;
    for (let f = 0; f < frames; f++) {
      getFrame(f, re, im);
      // Hermitian extension; imaginary parts of DC / Nyquist are ignored (c2r).
      bufIn[0] = re[0];
      bufIn[1] = 0;
      for (let k = 1; k < bins - 1; k++) {
        bufIn[2 * k] = re[k];
        bufIn[2 * k + 1] = im[k];
        bufIn[2 * (nFft - k)] = re[k];
        bufIn[2 * (nFft - k) + 1] = -im[k];
      }
      bufIn[2 * (bins - 1)] = re[bins - 1];
      bufIn[2 * (bins - 1) + 1] = 0;
      this.inv.transform(bufIn, bufOut);
      const start = f * hop;
      for (let i = 0; i < nFft; i++) {
        acc[start + i] += bufOut[2 * i] * scale * window[i];
        wsum[start + i] += window[i] * window[i];
      }
    }
    const out = new Float32Array(length);
    for (let i = 0; i < length; i++) {
      const j = i + pad;
      if (j < total && wsum[j] > 1e-8) out[i] = acc[j] / wsum[j];
    }
    return out;
  }
}
