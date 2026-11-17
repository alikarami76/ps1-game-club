# Shared helpers for host.ps1 and join.ps1 (Windows PowerShell 5.1 or PowerShell 7). Dot-sourced.
function Find-RetroArch {
  if ($env:RETROARCH) { return $env:RETROARCH }
  $candidates = @(
    "$env:APPDATA\RetroArch\retroarch.exe",
    "C:\RetroArch-Win64\retroarch.exe",
    "$env:ProgramFiles\RetroArch\retroarch.exe",
    "${env:ProgramFiles(x86)}\RetroArch\retroarch.exe",
    "$env:LOCALAPPDATA\Programs\RetroArch\retroarch.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command retroarch.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "RetroArch not found. Install it, or set `$env:RETROARCH to the path of retroarch.exe."
}
function Find-Core($ra) {
  if ($env:PCSX_CORE) { return $env:PCSX_CORE }
  $dirs = @((Join-Path (Split-Path $ra) "cores"), "$env:APPDATA\RetroArch\cores")
  foreach ($d in $dirs) {
    $p = Join-Path $d "pcsx_rearmed_libretro.dll"
    if (Test-Path $p) { return $p }
  }
  throw "PCSX-ReARMed core not found. In RetroArch use Load Core > Download a Core > Sony - PlayStation (PCSX ReARMed), or set `$env:PCSX_CORE."
}
