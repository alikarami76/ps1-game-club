# Shared helpers for host.sh and join.sh. Sourced, not run.

die() { echo "Error: $*" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"

find_retroarch() {
  if [ -n "${RETROARCH:-}" ]; then echo "$RETROARCH"; return; fi
  for c in retroarch /Applications/RetroArch.app/Contents/MacOS/RetroArch /Applications/RetroArch\ Metal.app/Contents/MacOS/RetroArch; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return; fi
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  if command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1; then
    echo "flatpak run org.libretro.RetroArch"; return
  fi
  return 1
}

find_core() {
  if [ -n "${PCSX_CORE:-}" ]; then echo "$PCSX_CORE"; return; fi
  for d in \
    "$HOME/Library/Application Support/RetroArch/cores" \
    "$HOME/.config/retroarch/cores" \
    "$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores" \
    /usr/lib/libretro /usr/lib64/libretro /usr/lib/x86_64-linux-gnu/libretro /usr/local/lib/libretro \
    /Applications/RetroArch.app/Contents/Resources/cores
  do
    for ext in dylib so; do
      if [ -f "$d/pcsx_rearmed_libretro.$ext" ]; then echo "$d/pcsx_rearmed_libretro.$ext"; return; fi
    done
  done
  return 1
}

prepare() {
  RA="$(find_retroarch)" || die "RetroArch not found. Install it, or set RETROARCH=/path/to/retroarch."
  CORE="$(find_core)" || die "PCSX-ReARMed core not found. In RetroArch use Load Core > Download a Core > Sony - PlayStation (PCSX ReARMed), or set PCSX_CORE=/path/to/pcsx_rearmed_libretro.*"
  [ -n "${GAME:-}" ] && [ -f "$GAME" ] || die "Give the path of your own disc image (.cue, .chd, .pbp ...). See --help."
}
