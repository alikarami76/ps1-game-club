"""Reference counts from games/twisted-metal/dmd.py, to diff against tests/disc/dmd_counts_test.gd.

Run from the repo root:  python3 -I engine/tests/disc/dmd_counts_ref.py [gamedata_dir] > ref.txt
colsum is the sum of every vertex colour component dmd.vertex_colors() returns (polygons and
sprites), so it checks the lighting port too.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "games", "twisted-metal"))
import dmd  # noqa: E402

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "..", "gamedata")
m = json.load(open(os.path.join(root, "manifest.json")))
files = [(f"{a}/{p}", d["model"]) for a, parts in m["arenas"].items() for p, d in parts.items()]
files.append(("vehicles", m["vehicle_models"]["model"]))
for name, rel in files:
    data = open(os.path.join(root, rel), "rb").read()
    for i, o in enumerate(dmd.objects(data)):
        polys = sum(len(x.polygons) for x in o.meshes)
        verts = sum(len(x.vertices) for x in o.meshes)
        spr = sum(len(x.sprites) for x in o.meshes)
        tex = sum(1 for x in o.meshes for p in x.polygons if p.uvs)
        nrm = sum(len(x.normals) for x in o.meshes)
        tw = sum(1 for x in o.meshes for p in x.polygons if p.texwin)
        cs = sum(sum(c) for x in o.meshes for p in x.polygons for c in dmd.vertex_colors(x, p))
        cs += sum(sum(c) for x in o.meshes for _, p in x.sprites for c in dmd.vertex_colors(x, p))
        print(f"{name} obj {i} id {o.id:#x} meshes {len(o.meshes)} polys {polys} verts {verts} "
              f"sprites {spr} textured {tex} normals {nrm} texwin {tw} colsum {cs}")
