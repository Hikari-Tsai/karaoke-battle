import fs from 'fs';
export function readWav(path) {
  const b = fs.readFileSync(path);
  let p = 12, fmt = null, data = null;
  while (p + 8 <= b.length) {
    const id = b.toString('ascii', p, p + 4), size = b.readUInt32LE(p + 4);
    if (id === 'fmt ') fmt = { format: b.readUInt16LE(p + 8), ch: b.readUInt16LE(p + 10), sr: b.readUInt32LE(p + 12), bits: b.readUInt16LE(p + 22) };
    if (id === 'data') data = b.subarray(p + 8, p + 8 + size);
    p += 8 + size + (size & 1);
  }
  let fmtCode = fmt.format;
  if (fmtCode === 0xfffe) fmtCode = fmt.bits === 32 ? 3 : 1; // extensible: guess
  const n = data.length / (fmt.bits / 8) / fmt.ch;
  const planes = Array.from({ length: fmt.ch }, () => new Float32Array(n));
  const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
  for (let i = 0; i < n; i++) for (let c = 0; c < fmt.ch; c++) {
    const k = i * fmt.ch + c;
    planes[c][i] = fmtCode === 3 ? dv.getFloat32(k * 4, true) : fmt.bits === 16 ? dv.getInt16(k * 2, true) / 32768 : dv.getInt32(k * 4, true) / 2147483648;
  }
  return { sr: fmt.sr, planes, fmt };
}
