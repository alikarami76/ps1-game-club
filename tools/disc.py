"""Read a PlayStation disc image (CUE + BIN) and extract its ISO 9660 files.

Usage: python3 -I tools/disc.py <path/to/game.cue> <out_dir>
"""
import os
import re
import struct
import sys

SECTOR = 2352
USER_DATA_OFFSET = 24  # Mode 2 Form 1: 12 sync + 4 header + 8 subheader


def parse_cue(cue_path):
    """Return the list of (bin_path, track_type) in disc order."""
    base = os.path.dirname(cue_path)
    tracks, current_file = [], None
    with open(cue_path, encoding="latin1") as f:
        for line in f:
            line = line.strip()
            m = re.match(r'FILE "(.+)" BINARY', line)
            if m:
                current_file = os.path.join(base, m.group(1))
            m = re.match(r"TRACK (\d+) (\S+)", line)
            if m:
                tracks.append((current_file, m.group(2)))
    return tracks


class DataTrack:
    def __init__(self, bin_path):
        self.f = open(bin_path, "rb")

    def sector(self, lba):
        self.f.seek(lba * SECTOR + USER_DATA_OFFSET)
        return self.f.read(2048)

    def read(self, lba, size):
        count = (size + 2047) // 2048
        data = b"".join(self.sector(lba + i) for i in range(count))
        return data[:size]

    def walk(self, lba=None, size=None, path=""):
        """Yield (path, lba, size) for every file on the disc."""
        if lba is None:
            root = self.sector(16)[156:190]
            lba, size = struct.unpack("<I", root[2:6])[0], struct.unpack("<I", root[10:14])[0]
        data = self.read(lba, size)
        i = 0
        while i < len(data):
            length = data[i]
            if length == 0:
                i = (i // 2048 + 1) * 2048
                continue
            rec = data[i:i + length]
            i += length
            e_lba = struct.unpack("<I", rec[2:6])[0]
            e_size = struct.unpack("<I", rec[10:14])[0]
            name = rec[33:33 + rec[32]].decode("latin1")
            if name in ("\x00", "\x01"):
                continue
            name = name.split(";")[0]
            if rec[25] & 2:
                yield from self.walk(e_lba, e_size, path + name + "/")
            else:
                yield path + name, e_lba, e_size


def extract(cue_path, out_dir):
    tracks = parse_cue(cue_path)
    data_bin = next(p for p, t in tracks if t.startswith("MODE2"))
    disc = DataTrack(data_bin)
    count = 0
    for path, lba, size in disc.walk():
        dest = os.path.join(out_dir, "files", path)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if path.upper().endswith(".STR") or path.upper().endswith(".44D"):
            # Movies and interleaved streams use Form 2 sectors; copy raw 2352-byte sectors.
            disc.f.seek(lba * SECTOR)
            with open(dest, "wb") as out:
                for _ in range((size + 2047) // 2048):
                    out.write(disc.f.read(SECTOR))
        else:
            with open(dest, "wb") as out:
                out.write(disc.read(lba, size))
        count += 1
    # CD audio tracks are raw 44.1 kHz stereo 16-bit PCM; wrap them as WAV.
    music_dir = os.path.join(out_dir, "music")
    os.makedirs(music_dir, exist_ok=True)
    n = 0
    for bin_path, kind in tracks:
        if kind != "AUDIO":
            continue
        n += 1
        with open(bin_path, "rb") as src:
            src.seek(2 * SECTOR)  # skip the 2-second pregap (INDEX 01 at 00:02:00)
            pcm = src.read()
        with open(os.path.join(music_dir, f"track{n + 1:02d}.wav"), "wb") as out:
            out.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE")
            out.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, 44100, 44100 * 4, 4, 16))
            out.write(b"data" + struct.pack("<I", len(pcm)) + pcm)
    print(f"extracted {count} files and {n} music tracks to {out_dir}")


if __name__ == "__main__":
    extract(sys.argv[1], sys.argv[2])
