"""Decode a PlayStation VAB sound bank (header + SPU ADPCM samples) to WAV files.

Usage: python3 -I tools/vab.py <file.VAB> <out_dir>
Writes <out_dir>/vag_NN.wav (mono, 16-bit, with a 'smpl' loop chunk when the
sample loops) and <out_dir>/index.json (programs -> tones -> samples).

VAB layout: 32-byte header ("pBAV", version, id, file size, programs, tones,
samples, master volume/pan), 128 program records (16 bytes), one 16-tone block
(32 bytes per tone) for each program that has tones, 256 u16 sample sizes (in
units of 8 bytes), then the SPU ADPCM body. Sample numbers in tones are 1-based.
"""
import json
import os
import struct
import sys

import numpy as np

SPU_RATE = 44100  # the SPU plays at this rate when the pitch register is 0x1000
K0 = (0, 60, 115, 98, 122)
K1 = (0, 0, -52, -55, -60)


def decode_adpcm(data):
    """Decode SPU ADPCM. Return (int16 samples, loop_start, loop_end) in samples.

    loop_start/loop_end are None when the sample does not loop. A block's flag
    byte: bit0 = end, bit1 = repeat (loop back), bit2 = loop start.
    """
    out = np.zeros(len(data) // 16 * 28, dtype=np.int16)
    s1 = s2 = 0
    loop_start = loop_end = None
    for b in range(len(data) // 16):
        blk = data[b * 16:b * 16 + 16]
        shift, filt, flags = blk[0] & 15, min(blk[0] >> 4, 4), blk[1]
        if shift > 12:
            shift = 9
        k0, k1 = K0[filt], K1[filt]
        if flags & 4 and loop_start is None:
            loop_start = b * 28
        for i in range(28):
            n = (blk[2 + i // 2] >> (4 * (i & 1))) & 15
            if n > 7:
                n -= 16
            v = ((n << 12) >> shift) + ((k0 * s1 + k1 * s2 + 32) >> 6)
            v = max(-32768, min(32767, v))
            s2, s1 = s1, v
            out[b * 28 + i] = v
        if flags & 1 and flags & 2 and loop_end is None:
            loop_end = (b + 1) * 28
            if loop_start is None:
                loop_start = 0
        if flags & 1:
            out = out[:(b + 1) * 28]
            break
    return out, loop_start, loop_end


def parse_vab(data):
    """Return dict with programs (tone lists), sample byte ranges and header."""
    if data[:4] != b"pBAV":
        raise ValueError("not a VAB")
    ver, vab_id, fsize = struct.unpack_from("<III", data, 4)
    _, ps, ts, vs, mvol, pan = struct.unpack_from("<HHHHBB", data, 0x10)
    progs = [struct.unpack_from("<BBBBBBHII", data, 0x20 + 16 * i) for i in range(128)]
    tone_base = 0x20 + 128 * 16
    programs, block = {}, 0
    for pnum, p in enumerate(progs):
        if p[0] == 0:
            continue
        tones = []
        for t in range(p[0]):
            r = struct.unpack_from("<16B4H4H", data, tone_base + (block * 16 + t) * 32)
            tones.append(dict(
                tone=t, priority=r[0], mode=r[1], volume=r[2], pan=r[3], center=r[4],
                fine=r[5], note_min=r[6], note_max=r[7], adsr1=r[16], adsr2=r[17],
                program=r[18], vag=r[19]))
        programs[pnum] = dict(volume=p[1], priority=p[2], mode=p[3], pan=p[4], tones=tones)
        block += 1
    sizes_at = tone_base + block * 512
    sizes = struct.unpack_from("<256H", data, sizes_at)
    pos, vags = sizes_at + 512, {}
    for i in range(1, vs + 1):
        vags[i] = (pos, sizes[i] * 8)
        pos += sizes[i] * 8
    if pos > len(data):
        raise ValueError("sample table runs past end of file")
    return dict(version=ver, programs=programs, vags=vags, master_volume=mvol)


def write_wav(path, pcm, rate, loop=None):
    chunks = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, rate, rate * 2, 2, 16)
    chunks += b"data" + struct.pack("<I", len(pcm) * 2) + pcm.astype("<i2").tobytes()
    if loop:
        chunks += b"smpl" + struct.pack("<I", 60) + struct.pack(
            "<IIIIIIIII", 0, 0, 1000000000 // rate, 60, 0, 0, 0, 1, 0)
        chunks += struct.pack("<IIIIII", 0, 0, loop[0], loop[1] - 1, 0, 0)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)


def extract(vab_path, out_dir):
    data = open(vab_path, "rb").read()
    vab = parse_vab(data)
    os.makedirs(out_dir, exist_ok=True)
    samples = {}
    for i, (pos, size) in vab["vags"].items():
        pcm, ls, le = decode_adpcm(data[pos:pos + size])
        name = f"vag_{i:02d}.wav"
        write_wav(os.path.join(out_dir, name), pcm, SPU_RATE, (ls, le) if le else None)
        samples[i] = dict(file=name, samples=len(pcm), seconds=round(len(pcm) / SPU_RATE, 3),
                          loop_start=ls if le else None, loop_end=le)
    index = dict(source=os.path.basename(vab_path), sample_rate=SPU_RATE,
                 rate_note=("WAVs are written at 44100 Hz, the SPU rate when a tone plays its "
                            "centre note. For other notes: rate = 44100 * 2**((note - center - "
                            "fine/128) / 12)."), samples=samples, programs={})
    for pnum, prog in vab["programs"].items():
        tones = []
        for t in prog["tones"]:
            s = samples.get(t["vag"])
            t = dict(t, file=s["file"] if s else None,
                     rate_at_c4=round(SPU_RATE * 2 ** ((60 - t["center"] - t["fine"] / 128) / 12)),
                     loop=bool(s and s["loop_end"]))
            tones.append(t)
        index["programs"][pnum] = dict(prog, tones=tones)
    with open(os.path.join(out_dir, "index.json"), "w") as f:
        json.dump(index, f, indent=1)
    print(f"decoded {len(samples)} samples, {len(index['programs'])} programs, "
          f"{sum(len(p['tones']) for p in index['programs'].values())} tones to {out_dir}")


if __name__ == "__main__":
    extract(sys.argv[1], sys.argv[2])
