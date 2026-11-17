"""Build gamedata/: the files the engine needs from the player's own disc, sorted by use.

Reads from cache/ (made by disc.py, vab.py) and writes gamedata/ with manifest.json,
which is the only index the engine uses to find disc content. Large files are
hard-linked when possible to avoid a second copy. gamedata/ never ships in a build.

Usage: python3 games/twisted-metal/organize.py [cache_dir] [gamedata_dir]
(defaults: cache/ and gamedata/ at the top of the repo; both are git-ignored)
"""
import hashlib
import json
import os
import shutil
import sys

ARENAS = ["XARENA", "WH", "PARK", "ROOF", "SUBURB", "XFWY"]
# Select-screen order -> (dashboard texture file, selection card file) on the disc
VEHICLES = {
    "ICE": ("ICE_DASH.TMS", "ICE_CARD.TIM"), "CAB": ("CAB_DASH.TMS", "CAB_CARD.TIM"),
    "SEMI": ("SEMI_DAS.TMS", "SEMI_CAR.TIM"), "COP": ("COP_DASH.TMS", "COP_CARD.TIM"),
    "LOWRIDER": ("LOWRIDER.TMS", "LOWRIDER.TIM"), "LAMBO": ("LAMBO_DA.TMS", "LAMBO_CA.TIM"),
    "DUNEB": ("DUNEB_DA.TMS", "DUNEB_CA.TIM"), "HUMVEE": ("HUMVEE_D.TMS", "HUMVEE_C.TIM"),
    "HARLEY": ("HARLEY_D.TMS", "HARLEY_C.TIM"), "VETTE": ("VETTE_DA.TMS", "VETTE_CA.TIM"),
    "MONSTERT": ("MONSTERT.TMS", "MONSTERT.TIM"), "MADMAX": ("MADMAX_D.TMS", "MADMAX_C.TIM"),
}
# Vehicle -> top-level object id of its model in the DMD files (CARS.DMD and the arena
# files). Read from the game's RAM at match start for each select-screen choice.
OBJECT_IDS = {"ICE": 0x0A, "CAB": 0x14, "SEMI": 0x1E, "COP": 0x32, "LOWRIDER": 0x64, "LAMBO": 0x3C,
              "DUNEB": 0x5A, "HUMVEE": 0x46, "HARLEY": 0x50, "VETTE": 0x6E, "MONSTERT": 0x28,
              "MADMAX": 0x78}
UI_IMAGES = {"fonts": ["UATIM/UAFONT1.TIM", "TIM/CPFONT.TIM"],
             "menus": ["UATIM/UATITLE.TIM", "UATIM/UABACKDR.TIM", "UATIM/UAVEHICL.TIM",
                       "UATIM/UAARENA.TIM", "UATIM/UACONTRO.TIM", "UATIM/UANOCAR.TIM",
                       "UATIM/UANOISE.TIM", "UATIM/CALLSIGN.TIM", "UATIM/CHOPPER.TIM"]}
# Front-end screens and car biographies (full-screen 320x240 TIMs), loaded at run time by the
# menus. Every file in these disc folders is listed under ui.screens / ui.bios.
UI_FOLDERS = {"screens": "UASCREEN", "bios": "UABIOS"}

# Glyph tables of the disc fonts, read from the player's own executable. Each entry is
# {u8 u, v, w, h; s16 dy}, indexed by character code - 0x30 ('0' .. '|'). Glyphs are drawn
# bottom-aligned on the text line, moved down by dy. Offsets are for SCUS_943.04 (USA); each table
# is checked against a known glyph before it is written.
EXE = "SCUS_943.04"
GLYPH_TABLES = {
    # name: (file offset, entries, font image, check: (char, (u, v, w, h)))
    "menu": (0x7D1F4, 77, "uafont1", ("A", (2, 14, 14, 12))),
    "big": (0x7D3C4, 77, "uafont1", ("A", (153, 1, 14, 19))),
    "digits": (0x7D594, 10, "uafont1", ("0", (136, 111, 9, 14))),
    "small": (0x7D5D0, 77, "cpfont", ("A", (0, 14, 9, 9))),
}
# Short UI texts and names from the executable: (file offset of a table of string pointers, count).
EXE_LOAD = 0x800F78B8   # where the executable's text starts in RAM (header word 0x18)
STRING_TABLES = {"vehicle_names": (0x7E174, 12), "stage_line1": (0x7D8B0, 7), "stage_line2": (0x7D8CC, 7),
                 "control_presets": (0x7D8E8, 4)}
STRINGS = {"welcome": 0x4B38, "prepare": 0x4B44, "meet": 0x4B10, "congratulations": 0x4B24,
           "you_lose": 0x4B54, "paused": 0x4D10, "aborted": 0x4D50, "try_again": 0x4D74,
           "car_info": 0x4A18, "begin_battle": 0x487C, "audio_controls": 0x493C, "player": 0x4A30,
           "press_any": 0x49F8, "select_controls": 0x4908, "effects": 0x48C4, "play_track": 0x48D0}
STAGE_ARENAS = ["XARENA", "WH", "XFWY", "PARK", "SUBURB", "ROOF", "FINAL"]


def place(src, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest):
        os.remove(dest)
    try:
        os.link(src, dest)
    except OSError:
        shutil.copy2(src, dest)
    return dest


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_glyphs(data):
    """Glyph tables of the menu fonts, or {} when the executable is not the expected one."""
    import struct
    out = {}
    for name, (off, count, image, (ch, box)) in GLYPH_TABLES.items():
        table = {}
        for i in range(count):
            u, v, w, h, dy = struct.unpack_from("<BBBBh", data, off + 6 * i)
            if w and h:
                table[chr(0x30 + i)] = [u, v, w, h, dy]
        if tuple(table.get(ch, [0] * 5)[:4]) != box:
            print(f"glyph table {name}: unexpected executable, skipped")
            return {}
        out[name] = {"image": image, "glyphs": table}
    return out


def read_strings(data):
    """UI texts and names, or {} when the executable is not the expected one."""
    import struct

    def at(off):
        return data[off:data.index(b"\0", off)].decode("latin1")

    def ptr(p):
        off = p - EXE_LOAD + 0x800
        return at(off) if 0 <= off < len(data) else ""
    if at(STRINGS["welcome"]) != "WELCOME!":
        print("strings: unexpected executable, skipped")
        return {}
    out = {k: at(v) for k, v in STRINGS.items()}
    tables = {k: [ptr(struct.unpack_from("<I", data, off + 4 * i)[0]) for i in range(n)]
              for k, (off, n) in STRING_TABLES.items()}
    out["vehicle_names"] = dict(zip(VEHICLES.keys(), tables["vehicle_names"]))
    out["stages"] = {a: [t for t in (l1, l2) if t] for a, l1, l2 in
                     zip(STAGE_ARENAS, tables["stage_line1"], tables["stage_line2"])}
    out["control_presets"] = tables["control_presets"]
    return out


def build(cache, out):
    files = os.path.join(cache, "files")
    rel = lambda p: os.path.relpath(p, out)
    manifest = {"format": 1, "source": "Twisted Metal (USA) disc image, read locally",
                "arenas": {}, "vehicles": {}, "ui": {}, "audio": {}}

    for arena in ARENAS:
        entry = {}
        for part in ("1", "2"):
            dmd = place(f"{files}/UADMD/{arena}{part}.DMD", f"{out}/arenas/{arena}/part{part}.dmd")
            tms = place(f"{files}/UADMD/{arena}{part}.TMS", f"{out}/arenas/{arena}/part{part}.tms")
            entry[f"part{part}"] = {"model": rel(dmd), "textures": rel(tms)}
        manifest["arenas"][arena] = entry

    models = place(f"{files}/UADMD/CARS.DMD", f"{out}/vehicles/models.dmd")
    textures = place(f"{files}/UADMD/CARS.TMS", f"{out}/vehicles/models.tms")
    manifest["vehicle_models"] = {"model": rel(models), "textures": rel(textures)}
    for order, (vid, (dash, card)) in enumerate(VEHICLES.items()):
        manifest["vehicles"][vid] = {
            "select_order": order,
            "object_id": OBJECT_IDS[vid],
            "dashboard": rel(place(f"{files}/UADASH/{dash}", f"{out}/vehicles/{vid}/dashboard.tms")),
            "card": rel(place(f"{files}/UATIM/{card}", f"{out}/vehicles/{vid}/card.tim")),
        }

    for group, paths in UI_IMAGES.items():
        manifest["ui"][group] = {
            os.path.splitext(os.path.basename(p))[0].lower():
                rel(place(f"{files}/{p}", f"{out}/ui/{group}/{os.path.basename(p).lower()}"))
            for p in paths}

    for group, folder in UI_FOLDERS.items():
        src = os.path.join(files, folder)
        if os.path.isdir(src):
            manifest["ui"][group] = {
                os.path.splitext(n)[0].lower(): rel(place(f"{src}/{n}", f"{out}/ui/{group}/{n.lower()}"))
                for n in sorted(os.listdir(src)) if n.upper().endswith(".TIM")}
    # driver portraits: images 0-11 of the menu car textures, in select order
    for vid, entry in manifest["vehicles"].items():
        entry["portrait"] = {"textures": manifest["vehicle_models"]["textures"], "image": entry["select_order"]}
    exe = os.path.join(files, EXE)
    if os.path.exists(exe):
        data = open(exe, "rb").read()
        glyphs = read_glyphs(data)
        if glyphs:
            dest = f"{out}/ui/fonts/glyphs.json"
            json.dump(glyphs, open(dest, "w"), indent=1)
            manifest["ui"]["glyphs"] = rel(dest)
        strings = read_strings(data)
        if strings:
            dest = f"{out}/ui/strings.json"
            json.dump(strings, open(dest, "w"), indent=1)
            manifest["ui"]["strings"] = rel(dest)

    sfx_src = os.path.join(cache, "sfx")
    manifest["audio"]["sfx_index"] = rel(place(f"{sfx_src}/index.json", f"{out}/audio/sfx/index.json"))
    for name in sorted(os.listdir(sfx_src)):
        if name.endswith(".wav"):
            place(f"{sfx_src}/{name}", f"{out}/audio/sfx/{name}")
    manifest["audio"]["music"] = [
        rel(place(f"{cache}/music/{n}", f"{out}/audio/music/{n}"))
        for n in sorted(os.listdir(f"{cache}/music")) if n.endswith(".wav")]

    # Decoded side data (start positions, pickups) from data/arenas/<ID>.json, measured on the
    # player's own disc. Listed under data_files ("arenas/<ID>.json" -> path in gamedata), read
    # by the engine through DiscFiles.read_side_data, and copied with the rest on the web.
    manifest["data_files"] = {}
    side = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "arenas")
    if os.path.isdir(side):
        for name in sorted(os.listdir(side)):
            if name.endswith(".json"):
                dest = os.path.join(out, "data", "arenas", name)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copy2(os.path.join(side, name), dest)
                manifest["data_files"][f"arenas/{name}"] = rel(dest)

    manifest["checksums"] = {}
    for root, _, names in os.walk(out):
        for n in names:
            p = os.path.join(root, n)
            if n != "manifest.json":
                manifest["checksums"][rel(p)] = sha1(p)
    json.dump(manifest, open(f"{out}/manifest.json", "w"), indent=2)
    print(f"wrote {len(manifest['checksums'])} files to {out}")


if __name__ == "__main__":
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # repo root
    build(sys.argv[1] if len(sys.argv) > 1 else f"{here}/cache",
          sys.argv[2] if len(sys.argv) > 2 else f"{here}/gamedata")
