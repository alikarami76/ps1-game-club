#!/bin/bash
# Leak check for ps1-game-club. Run before every commit:  scripts/leak_check.sh   (exit 0 = clean)
#
# It scans every file git would commit (tracked plus untracked, minus .gitignore'd) and fails on:
#   1. private words: personal and company names that must never be published. They are stored here only
#      as SHA-256 hashes, so this public script does not publish them itself; every lower-cased substring
#      of the right length is hashed and compared;
#   2. readable patterns: home-folder paths (/Users/<name>, /home/<name>), the 172.20.x LAN range, agent
#      scratchpad paths, private keys and access-key values;
#   3. game files by extension: disc images, BIOS files, PS1 formats, audio/video, save states;
#   4. game files by content (file magic): CD001 (ISO 9660), DXSPC / TXSPC (Twisted Metal DMD / TMS),
#      the TIM header 10 00 00 00, pBAV / VABp (VAB), RIFF (WAV and other RIFF files), the CD sector sync
#      pattern. Magic is checked at the start of every file and anywhere inside binary files; source code
#      that merely names a magic string (e.g. a decoder testing for b"TXSPC") is text and is allowed;
#   5. any binary file other than the PNG screenshots in docs/images/ (which must be real PNGs, <= 350 KB);
#   6. git-ignore gaps: gamedata/, cache/, emu/, dist/ and engine/.godot must be ignored if they exist;
#   7. the git identity (user.name, user.email, authors of existing commits) that a push would publish.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec python3 -I - "$ROOT" <<'EOF'
import hashlib, os, re, subprocess, sys

root = sys.argv[1]
os.chdir(root)

# 1. private words (sha256 of the lower-case word, word length). Substring match.
PRIVATE = [
    ("a8c6a80da67ceab3faaf89e8010d9cab058c07a3273ad749c6965ad900f1f046", 8),
    ("1579e689c5e11501b5878aaff12a6287238edafb2425bc49aa56c72822eeb2cc", 6),
    ("9c66dd6cf2e5c1dd32f42e68a9b6fb54f85eb9f53c5bc134a668869545504cca", 10),
    ("6e956453c07fe03aee9dfe7fdb3517083a8ebcca867365af63d94e8b31c0bb1e", 5),
    ("dfb44583ef7d6818a5ab68995f55fe5e01c1eae62083d1dc8a17d25bf1333139", 6),
    ("7b11367fb587693c8730d67be2858ca45d05f803f7078975909a217ccb215118", 5),
    ("1b48a65c9c2321945f3e7e785393ec89663c4029559fca73bb61c31f221ee176", 9),
    ("026011b1c964407cd682ee4ba000f10f976e730a5116e43261f4a7ac3641d0c4", 7),
    ("6fdfd1c7b8321ff9244ec506dc52878be14ff61a8022f6290846dacdecf6727e", 9),
]
# whole-token private words (too short for substring matching)
PRIVATE_TOKENS = {"94419b99b12c11133a4dfeccc3e17885974beb48f7827c48239aabfbcad238d8"}

READABLE = [
    (re.compile(r"/Users/(?!Shared/)[A-Za-z0-9._-]+"), "home-folder path"),
    (re.compile(r"/home/(?!tm\b)[a-z][a-z0-9._-]+/"), "home-folder path"),
    (re.compile(r"\b172\.20\.\d+"), "LAN address 172.20.x"),
    (re.compile(r"scratchpad|/private/tmp/claude|\.claude/", re.I), "agent scratchpad / .claude path"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    (re.compile(r"TM_ACCESS_KEY\s*[=:]\s*[\"']?[A-Za-z0-9_\-]{12,}"), "access key value"),
]
BAD_EXT = {".bin", ".cue", ".iso", ".img", ".chd", ".pbp", ".ecm", ".mdf", ".mds", ".tim", ".tms", ".dmd",
           ".vab", ".xa", ".str", ".wav", ".ogg", ".44d", ".exe", ".state", ".srm", ".mcr", ".dylib", ".so",
           ".dll", ".key", ".pem"}
BAD_NAME = re.compile(r"(^|/)(scph[^/]*|[^/]*bios[^/]*\.(bin|rom|img))$", re.I)
MAGIC_START = [b"CD001", b"DXSPC", b"TXSPC", b"pBAV", b"VABp", b"RIFF", b"\x10\x00\x00\x00",
               b"\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00"]
MAGIC_ANY = [b"CD001", b"DXSPC", b"TXSPC", b"pBAV", b"VABp", b"RIFF"]
SELF = "scripts/leak_check.sh"

files = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                       capture_output=True, check=True).stdout.decode().split("\0")
files = sorted(f for f in files if f and os.path.isfile(f))
lens = sorted({n for _, n in PRIVATE})
hashes = {h for h, _ in PRIVATE}
hits = []

def private_hit(text):
    for tok in re.findall(r"[a-z0-9_]+", text.lower()):
        if hashlib.sha256(tok.encode()).hexdigest() in PRIVATE_TOKENS:
            return True
        for n in lens:
            for i in range(0, len(tok) - n + 1):
                if hashlib.sha256(tok[i:i + n].encode()).hexdigest() in hashes:
                    return True
    return False

for f in files:
    data = open(f, "rb").read()
    ext = os.path.splitext(f)[1].lower()
    if ext in BAD_EXT or BAD_NAME.search(f):
        hits.append((f, "game, BIOS or secret file type " + ext))
    if private_hit(f):
        hits.append((f, "private word in the file name"))
    is_png = f.startswith("docs/images/") and ext == ".png"
    binary = b"\0" in data[:8192]
    if not binary:
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            binary = True
    for m in MAGIC_START:
        if data.startswith(m):
            hits.append((f, "starts with game-file magic %r" % m))
    if len(data) > 0x9320 and (data[0x8001:0x8006] == b"CD001" or data[0x9319:0x931E] == b"CD001"):
        hits.append((f, "ISO 9660 volume descriptor (disc image)"))
    if binary:
        if is_png:
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                hits.append((f, "screenshot is not a PNG"))
            if len(data) > 350_000:
                hits.append((f, "screenshot larger than 350 KB (%d bytes)" % len(data)))
            for m in (b"CD001", b"DXSPC", b"TXSPC", b"pBAV", b"VABp"):
                if m in data:
                    hits.append((f, "screenshot contains game-file magic %r" % m))
        else:
            hits.append((f, "binary file outside docs/images/"))
            for m in MAGIC_ANY:
                if m in data:
                    hits.append((f, "binary file contains game-file magic %r" % m))
        continue
    if f == SELF:
        continue
    for n, line in enumerate(text.splitlines(), 1):
        if private_hit(line):
            hits.append((f"{f}:{n}", "private word"))
        for rx, why in READABLE:
            if rx.search(line):
                hits.append((f"{f}:{n}", why))

# 7. the git identity that would be published with a commit (local config and existing commits)
ident = []
for key in ("user.name", "user.email"):
    r = subprocess.run(["git", "config", key], capture_output=True, text=True)
    ident.append(("git config " + key, r.stdout.strip()))
r = subprocess.run(["git", "log", "--all", "--format=%an <%ae> / %cn <%ce>"], capture_output=True, text=True)
ident += [("commit author/committer", line) for line in r.stdout.splitlines()]
# the repo owner's public GitHub identity is published with the repo anyway
PUBLIC_IDENTITY = ("alikarami76", "52026333+alikarami76@users.noreply.github.com")
for where, value in ident:
    for ok in PUBLIC_IDENTITY:
        value = value.replace(ok, "")
    if value and private_hit(value):
        hits.append((where, "private word in the git identity"))

for d in ("gamedata", "cache", "emu", "dist", "engine/.godot"):
    if os.path.lexists(d) and subprocess.run(["git", "check-ignore", "-q", d]).returncode != 0:
        hits.append((d, "exists but is not git-ignored"))

print(f"leak_check: scanned {len(files)} files")
for where, why in hits:
    print(f"  HIT {where}: {why}")
print(f"leak_check: {len(hits)} hit(s)")
sys.exit(1 if hits else 0)
EOF
