// Tiny "store" (no compression) ZIP builder that works on File objects without reading
// them all into memory at once. Used to hand a CUE sheet plus its BIN tracks to the
// emulator as one in-browser file. Nothing here touches the network.
(function () {
  "use strict";
  const TABLE = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    TABLE[n] = c >>> 0;
  }
  function crcUpdate(crc, bytes) {
    for (let i = 0; i < bytes.length; i++) crc = TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
    return crc;
  }
  async function crc32(file, onProgress) {
    let crc = 0xffffffff;
    const step = 8 * 1024 * 1024;
    for (let off = 0; off < file.size; off += step) {
      const buf = new Uint8Array(await file.slice(off, off + step).arrayBuffer());
      crc = crcUpdate(crc, buf);
      if (onProgress) onProgress(Math.min(off + step, file.size));
    }
    return (crc ^ 0xffffffff) >>> 0;
  }
  function le(n, bytes) {
    const a = new Uint8Array(bytes);
    for (let i = 0; i < bytes; i++) a[i] = Math.floor(n / Math.pow(2, 8 * i)) & 0xff;
    return a;
  }
  // files: array of File. Returns a Blob (application/zip). Entries are stored, not compressed.
  async function buildZip(files, onProgress) {
    const enc = new TextEncoder();
    const parts = [];
    const central = [];
    let offset = 0;
    let done = 0;
    const total = files.reduce((s, f) => s + f.size, 0) || 1;
    for (const f of files) {
      const name = enc.encode(f.name);
      const crc = await crc32(f, (n) => onProgress && onProgress((done + n) / total));
      done += f.size;
      if (f.size >= 0xffffffff) throw new Error(f.name + " is 4 GB or larger, which this simple zip cannot hold. Use a CHD file instead.");
      const local = [
        le(0x04034b50, 4), le(20, 2), le(0x0800, 2), le(0, 2), le(0, 2), le(0x21, 2),
        le(crc, 4), le(f.size, 4), le(f.size, 4), le(name.length, 2), le(0, 2), name,
      ];
      const localLen = local.reduce((s, p) => s + p.length, 0);
      parts.push(...local, f);
      central.push([
        le(0x02014b50, 4), le(20, 2), le(20, 2), le(0x0800, 2), le(0, 2), le(0, 2), le(0x21, 2),
        le(crc, 4), le(f.size, 4), le(f.size, 4), le(name.length, 2), le(0, 2), le(0, 2),
        le(0, 2), le(0, 2), le(0, 4), le(offset, 4), name,
      ]);
      offset += localLen + f.size;
    }
    let cdSize = 0;
    for (const entry of central) for (const p of entry) { parts.push(p); cdSize += p.length; }
    parts.push(le(0x06054b50, 4), le(0, 2), le(0, 2), le(files.length, 2), le(files.length, 2),
      le(cdSize, 4), le(offset, 4), le(0, 2));
    return new Blob(parts, { type: "application/zip" });
  }
  window.ClubZip = { buildZip: buildZip, crc32: crc32 };
})();
