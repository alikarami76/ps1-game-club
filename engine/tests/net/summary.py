"""Summarise a tests/net/run_lobby.sh run: python3 -I summary.py OUT_DIR"""
import glob, os, re, sys
out = sys.argv[1]
rows = []
hist_tot = [0, 0, 0, 0]
for p in sorted(glob.glob(os.path.join(out, "client_*.log"))):
    txt = open(p, errors="replace").read()
    m = re.findall(r"\[netstats-final\](.*)", txt)
    errs = len(re.findall(r"^(ERROR|SCRIPT ERROR)", txt, re.M))
    if not m:
        print(os.path.basename(p), "NO FINAL STATS", "errors=%d" % errs)
        continue
    kv = dict(re.findall(r"(\w+(?:>1m)?)=([-\d.]+)", m[-1]))
    d = re.search(r"recon_err avg=([\d.]+) m max=([\d.]+) m n=(\d+) >1m=(\d+)", m[-1])
    h = re.search(r"hist\(<5cm,<25cm,<1m,>=1m\)=\[([\d,]+)\]", m[-1])
    if h:
        hist_tot[:] = [a + int(b) for a, b in zip(hist_tot, h.group(1).split(","))]
    rows.append((os.path.basename(p), float(kv["in"]), float(kv["out"]), float(d.group(1)), float(d.group(2)), int(d.group(4)), int(kv["lost"]), errs, kv.get("rtt"), kv.get("interp")))
print("%-22s %8s %8s %9s %8s %5s %5s %4s %5s %6s" % ("client", "in B/s", "out B/s", "err avg m", "max m", ">1m", "lost", "errs", "rtt", "interp"))
for r in rows:
    print("%-22s %8.0f %8.0f %9.4f %8.3f %5d %5d %4d %5s %6s" % r)
if rows:
    n = len(rows)
    print("mean in %.0f B/s, out %.0f B/s, recon err avg %.4f m, worst %.3f m" % (sum(r[1] for r in rows) / n, sum(r[2] for r in rows) / n, sum(r[3] for r in rows) / n, max(r[4] for r in rows)))
tot = sum(hist_tot)
if tot:
    print("reconciliation error distribution: <5cm %.1f%%, 5-25cm %.1f%%, 25cm-1m %.1f%%, >=1m %.2f%% (of %d acks)" % tuple([100.0 * x / tot for x in hist_tot] + [tot]))
s = open(os.path.join(out, "server.log"), errors="replace").read()
for l in re.findall(r"^\[server-match\].*", s, re.M):
    print(l)
st = re.findall(r"^\[server-stats\].*", s, re.M)
if st:
    print(st[-1])
print("kills:", len(re.findall(r"\[match\] lobby \S+: kill", s)), " server errors:", len(re.findall(r"^(ERROR|SCRIPT ERROR)", s, re.M)))
