"""Tick-by-tick prediction diff: python3 -I tests/net/pred_diff.py OUT_DIR [N]

Run a lobby with tracing on the server and the clients, for example:
  SERVER_FLAGS=--trace-pred tests/net/run_lobby.sh /tmp/tp 8931 "A:8" 60 --trace-pred --arena=WH/part1
Lines: [tp-s] server state after each consumed input (slot, server tick st, input tick in),
[tp-c] client state after predicting input tick t, [tp-r] each received ack with the server
state and the error against pred_hist[ack]. For every correction over 25 cm this prints the
server and first-predicted client state for the ticks around it, so you can see whether the
inputs, the starting state or a single step differ.
"""
import collections, glob, math, re, sys

d = sys.argv[1]
show = int(sys.argv[2]) if len(sys.argv) > 2 else 3
rx = re.compile(r"\[(tp-[scr]) ([^\n]*)")


def kv(s):
    return dict(re.findall(r"(\w+)=([-\d.,e]+)", s))


def dist(a, b):
    return math.dist([float(x) for x in a.split(",")], [float(x) for x in b.split(",")])


srv = collections.defaultdict(dict)
for line in open(d + "/server.log", errors="replace"):
    m = rx.search(line)
    if m and m.group(1) == "tp-s":
        k = kv(m.group(2))
        srv[int(k["slot"])][int(k["in"])] = k
for f in sorted(glob.glob(d + "/client_*.log")):
    cl, recs, slot = {}, [], None
    for line in open(f, errors="replace"):
        m = rx.search(line)
        if not m:
            continue
        k = kv(m.group(2))
        slot = int(k["slot"])
        if m.group(1) == "tp-c":
            cl.setdefault(int(k["t"]), k)   # first prediction, before any replay
        elif m.group(1) == "tp-r":
            recs.append(k)
    S = srv[slot]
    nb = sum(1 for t, c in cl.items() if t in S and c["live"] == "1" and (c["b"] != S[t]["b"] or c["s"] != S[t]["s"]))
    big = [r for r in recs if float(r["err"]) > 0.25]
    print(f, "slot", slot, "ticks", len(cl), "server inputs", len(S), "live input mismatches", nb, "acks", len(recs), "over 25 cm", len(big))
    for r in big[:show]:
        a = int(r["ack"])
        print("  ack", a, "client tick", r["ct"], "err", r["err"])
        for t in range(a - 4, a + 2):
            c, s = cl.get(t), S.get(t)
            if c and s:
                print("   t", t, "in c/s", c["b"], c["s"], "/", s["b"], s["s"], "srv tick", s["st"], "dpos %.3f" % dist(c["p"], s["p"]),
                      "pos c/s", c["p"], s["p"], "vel c/s", c["v"], s["v"], "floor c/s", c["f"], s["f"])
