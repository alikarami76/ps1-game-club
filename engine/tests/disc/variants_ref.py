"""Scratch cross-check of switch/animation variants (Python side)."""
import json, math, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "games", "twisted-metal"))
import dmd
root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "..", "gamedata")
m = json.load(open(os.path.join(root, "manifest.json")))
files = [(f"{a}/{p}", d["model"]) for a, parts in m["arenas"].items() for p, d in parts.items()]
files.append(("vehicles", m["vehicle_models"]["model"]))
def cnt(ms):
    cs = sum(sum(c) for x in ms for p in x.polygons for c in dmd.vertex_colors(x, p))
    cs += sum(sum(c) for x in ms for _, p in x.sprites for c in dmd.vertex_colors(x, p))
    v = sum(abs(math.floor(x.vertices[k][c] + 0.5)) for x in ms for p in x.polygons for k in p.indices for c in range(3))
    v += sum(abs(math.floor(ce[c] + 0.5)) for x in ms for ce, _ in x.sprites for c in range(3))
    return "%d/%d/%d/%d/%d" % (len(ms), sum(len(x.polygons) for x in ms), sum(len(x.sprites) for x in ms), cs, int(v))
for name, rel in files:
    data = open(os.path.join(root, rel), "rb").read()
    for i, o in enumerate(dmd.objects(data)):
        ctx = sum(x.switch_node + x.state * 7 + x.anim_node * 3 + x.frame + x.tag * 5 + x.tag_node + x.split_node + x.split_side * 11 for x in o.meshes)
        print(f"{name} obj {i} ctx {ctx}")
        for s in o.switches:
            print(f"{name} obj {i} sw {s.offset:#x} id {s.id:#x} slot {s.slot} count {s.count} def {s.default} parent {s.parent} states " + " ".join(cnt(st) for st in s.states))
        for a in o.animations:
            print(f"{name} obj {i} anim {a.offset:#x} id {a.id:#x} delay {a.delay} {a.first}-{a.last} mode {a.mode} def {a.default} parent {a.parent} frames " + " ".join(cnt(f) for f in a.frames))
        pts = [(16800, 4300, 150), (10800, 5200, 7700), (4600, 1800, 7900), (10800, 6200, 8500), (0, 0, 0)]
        for sp in o.splits:
            org = ",".join("%d" % c for c in sp.origin)
            regs = ";".join(",".join(str(v) for v in m) + "|" + ",".join(str(v) for v in lo) + "|" + ",".join(str(v) for v in sz) for m, lo, sz in sp.regions)
            print(f"{name} obj {i} split {sp.offset:#x} origin {org} parent {sp.parent} regions {regs} out {cnt(sp.outside)} in {cnt(sp.inside)} contains " + "".join("1" if sp.contains(q) else "0" for q in pts))
