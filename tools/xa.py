"""Decode CD-ROM XA ADPCM audio from raw 2352-byte sector files to WAV.

Usage: python3 -I tools/xa.py <raw_sectors_file> <out_dir>
Writes <out_dir>/<name>_f<file>_c<channel>.wav for every audio channel found.

A Mode 2 sector has a 12-byte sync, 4-byte header and an 8-byte sub-header
(file, channel, submode, coding, repeated twice). Audio sectors have submode bit 2
(0x04) set. The coding byte says: bit 0 stereo, bit 2 18900 Hz (else 37800 Hz),
bit 4 8-bit (else 4-bit). Each audio sector holds 18 groups of 128 bytes: 16 parameter
bytes (shift/filter per sound unit) then 28 words of 4-bit samples. A group has 8 sound
units of 28 samples; for stereo the even units are left and the odd units right.
"""
import os
import struct
import sys
from collections import defaultdict

import numpy as np

SECTOR = 2352
K0 = (0, 60, 115, 98, 122)
K1 = (0, 0, -52, -55, -60)


def sectors(data):
    for i in range(len(data) // SECTOR):
        yield data[i * SECTOR:(i + 1) * SECTOR]


def is_audio(sec):
    return sec[18] & 0x04 and not sec[18] & 0x02


def coding_info(coding):
    return dict(stereo=bool(coding & 1), rate=18900 if coding & 4 else 37800,
                bits=8 if coding & 16 else 4)


class XADecoder:
    """Stateful decoder for one channel (keeps filter history between sectors)."""

    def __init__(self, stereo):
        self.stereo = stereo
        self.hist = [[0, 0], [0, 0]]

    def sector(self, sec):
        """Decode one 4-bit audio sector. Return (n, 2) int16 for stereo, (n,) for mono."""
        body = sec[24:24 + 18 * 128]
        chans = [[], []]
        for g in range(18):
            grp = body[g * 128:(g + 1) * 128]
            for u in range(8):
                hdr = grp[u if u < 4 else u + 4]
                shift, filt = hdr & 15, min(hdr >> 4, 4)
                if shift > 12:
                    shift = 9
                k0, k1 = K0[filt], K1[filt]
                c = (u & 1) if self.stereo else 0
                s1, s2 = self.hist[c]
                out = chans[c]
                for k in range(28):
                    b = grp[16 + (u >> 1) + 4 * k]
                    n = (b >> (4 * (u & 1))) & 15
                    if n > 7:
                        n -= 16
                    v = ((n << 12) >> shift) + ((k0 * s1 + k1 * s2 + 32) >> 6)
                    v = max(-32768, min(32767, v))
                    s2, s1 = s1, v
                    out.append(v)
                self.hist[c] = [s1, s2]
        if self.stereo:
            return np.stack([np.array(chans[0], np.int16), np.array(chans[1], np.int16)], axis=1)
        return np.array(chans[0], np.int16)


def decode_stream(data):
    """Decode all audio in raw sectors. Return {(file, channel): (rate, stereo, pcm)}."""
    decs, out, info = {}, defaultdict(list), {}
    for sec in sectors(data):
        if not is_audio(sec):
            continue
        key = (sec[16], sec[17])
        ci = coding_info(sec[19])
        if ci["bits"] != 4:
            raise ValueError("8-bit XA not supported")
        if key not in decs:
            decs[key] = XADecoder(ci["stereo"])
            info[key] = ci
        out[key].append(decs[key].sector(sec))
    return {k: (info[k]["rate"], info[k]["stereo"], np.concatenate(v)) for k, v in out.items()}


def write_wav(path, pcm, rate, stereo):
    ch = 2 if stereo else 1
    raw = pcm.astype("<i2").tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(raw)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, ch, rate, rate * ch * 2, ch * 2, 16))
        f.write(b"data" + struct.pack("<I", len(raw)) + raw)


def extract(path, out_dir):
    name = os.path.splitext(os.path.basename(path))[0]
    os.makedirs(out_dir, exist_ok=True)
    streams = decode_stream(open(path, "rb").read())
    for (fn, ch), (rate, stereo, pcm) in sorted(streams.items()):
        dest = os.path.join(out_dir, f"{name}_f{fn}_c{ch}.wav")
        write_wav(dest, pcm, rate, stereo)
        print(f"{dest}: {len(pcm) / rate:.2f}s {rate} Hz {'stereo' if stereo else 'mono'}")
    return streams


if __name__ == "__main__":
    extract(sys.argv[1], sys.argv[2])
