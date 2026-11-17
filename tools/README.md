# tools/: PS1 readers, emulator harness, preview

Python 3 tools for taking apart a PS1 game you own. They need `numpy` and `Pillow`
(`python3 -m pip install numpy pillow`). Run them with `python3 -I` so nothing in the current folder
can shadow a standard module. Everything they write (`cache/`, `gamedata/`, `emu/`) is git-ignored and
must never be committed: it is read from your disc.

## Disc and format readers (any PS1 game)

| Tool | What it does |
|---|---|
| `disc.py <game.cue> <out_dir>` | Reads a CUE/BIN image, extracts every ISO 9660 file from the data track into `<out_dir>/files/`, copies Form 2 streams (`.STR`, `.44D`) as raw 2352-byte sectors, and wraps CD-audio tracks as WAV in `<out_dir>/music/`. |
| `tim.py` | Decodes TIM images (4, 8, 16 and 24-bit, with palettes) to PNG. |
| `vram.py` | Emulates the PS1's 1024x512 video memory: loads TIM images (and texture sets made of TIMs) at their own VRAM positions, then samples texture pages with a palette, texture windows and the semi-transparency bit. |
| `vab.py <file.VAB> <out_dir>` | Decodes a VAB sound bank (SPU ADPCM) to WAV files with loop points, plus `index.json` (programs, tones, pitch). |
| `sfxlabel.py <sfx_dir>` | Adds rough labels to the decoded sounds from duration, envelope and spectrum ("explosion", "engine loop"...). Low confidence; nothing is checked by ear. |
| `xa.py` | Decodes CD-XA ADPCM audio. |
| `str.py` | Splits STR movies into frames' MDEC bitstreams and decodes their XA audio. Video is not decoded to pixels (that needs an MDEC decoder). |

## Headless emulator harness

| Tool | What it does |
|---|---|
| `build_core.sh` | Clones [PCSX-ReARMed](https://github.com/libretro/pcsx_rearmed) and builds its libretro core into `emu/pcsx_rearmed/` (git-ignored). `--ref=COMMIT` pins a version. The core uses its built-in HLE BIOS, so no BIOS file is needed. |
| `emu_harness.py` | A minimal libretro front end in `ctypes`: no window, no audio. Loads your `.cue`, runs frames, presses buttons, reads the 2 MB of PS1 RAM, saves and loads states, saves frames as PNG. `PS1_CORE` overrides the core path. |
| `nav.py` | Scripted menu navigation and contact sheets of frames. Reads the disc path from `PS1_CUE`. |
| `measure.py` | The first driving-measurement script of the Twisted Metal example: starts a match for each car and measures top speed, acceleration, braking, coasting and turn rate per game tick. The RAM addresses in it are Twisted Metal's; for another game they are what you find in step 4 of the guide. Run it from `tools/` with `PS1_CUE` set; it writes `data/tuning.json` at the repo root. |

Example, from the repo root:

```bash
tools/build_core.sh
cd tools && PS1_CUE="/path/to/Your Game.cue" python3 -I -c "
import emu_harness as E, nav
emu = E.Emulator(nav.CUE)
emu.run(600)                      # 10 seconds at 60 frames per second
emu.screenshot('../cache/boot.png')
print(emu.ram()[:16])"
```

## Preview

| Tool | What it does |
|---|---|
| `preview.py <model> <textures> <out.png> [object]` | Software renderer for decoded models: GTE-style lighting, texture windows, blend modes, sprites, perspective camera. It reads models through the Twisted Metal DMD decoder (`games/twisted-metal/dmd.py`), so it is the template for a preview of your own game's model format. |

## Deployment helper

| Tool | What it does |
|---|---|
| `make_deploy_data.py SRC OUT` | Copies a `gamedata/` folder for a container image, converting the music WAVs to OGG Vorbis (needs `ffmpeg`) and rewriting `manifest.json` with the same checksum rules. Used by `deploy/docker/assemble.sh`. |
