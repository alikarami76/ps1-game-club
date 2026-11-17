"""Read PlayStation .STR movies (raw 2352-byte sectors): audio to WAV, video documented.

Usage: python3 -I tools/str.py <movie.STR> <out_dir>
Writes <out_dir>/<name>.wav (the XA ADPCM track) and <out_dir>/<name>.json (stream info).

Container: video and audio sectors are interleaved (submode 0x42 = video, 0x64 = audio,
EOF marker sectors at the end). Audio is CD-XA ADPCM, decoded by xa.py.
Video sectors each carry a 32-byte header at the start of their user data, then a slice
of the frame's MDEC bitstream:
    u16 0x0160 magic, u16 0x8001, u16 chunk index, u16 chunk count,
    u32 frame number, u32 bitstream bytes, u16 width, u16 height,
    u16 MDEC code count (in 32-bit words), u16 0x3800, u16 quantiser scale,
    u16 version (1 in all four movies here), u32 0.
The frames are MDEC bitstreams (variable-length codes per 8x8 block, 16x16 macroblocks
in Cr Cb Y1-Y4 order; 320x240 at 15 fps, 10 sectors per frame). Decoding
them to pixels needs an MDEC emulation (VLC -> inverse quantise -> IDCT -> YCbCr); that
is not done here, but frame() returns the reassembled bitstream for each frame.
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xa  # noqa: E402


def video_sectors(data):
    for i, sec in enumerate(xa.sectors(data)):
        if sec[18] & 0x02 and sec[24:26] == b"\x60\x01":
            yield i, sec


def frames(data):
    """Yield (frame_number, width, height, quant, version, bitstream_bytes)."""
    cur, parts = None, {}
    for _, sec in video_sectors(data):
        idx, cnt, fno, size, w, h, _, _, q, ver = struct.unpack_from("<HHIIHHHHHH", sec, 24 + 4)
        if cur != fno:
            cur, parts = fno, {}
        parts[idx] = sec[24 + 32:24 + 32 + 2048 - 32]
        if len(parts) == cnt:
            bs = b"".join(parts[k] for k in sorted(parts))[:size]
            yield fno, w, h, q, ver, bs
            cur, parts = None, {}


def info(data):
    n = len(data) // xa.SECTOR
    fr = list(frames(data))
    audio = xa.decode_stream(data)
    vid = sum(1 for _ in video_sectors(data))
    res = dict(sectors=n, video_sectors=vid, frames=len(fr),
               size=sorted({(f[1], f[2]) for f in fr}), versions=sorted({f[4] for f in fr}),
               quant=sorted({f[3] for f in fr}),
               sectors_per_frame=round(n / max(len(fr), 1), 2),
               audio=[dict(file=k[0], channel=k[1], rate=v[0], stereo=v[1],
                           seconds=round(len(v[2]) / v[0], 2)) for k, v in audio.items()])
    res["fps"] = round(150 / (n / max(len(fr), 1)), 2)  # discs play at 2x: 150 sectors/s
    return res, audio


def extract(path, out_dir):
    name = os.path.splitext(os.path.basename(path))[0]
    os.makedirs(out_dir, exist_ok=True)
    data = open(path, "rb").read()
    res, audio = info(data)
    for (fn, ch), (rate, stereo, pcm) in audio.items():
        xa.write_wav(os.path.join(out_dir, f"{name}.wav" if len(audio) == 1
                                  else f"{name}_f{fn}_c{ch}.wav"), pcm, rate, stereo)
    json.dump(res, open(os.path.join(out_dir, name + ".json"), "w"), indent=1)
    print(name, res)


if __name__ == "__main__":
    extract(sys.argv[1], sys.argv[2])
