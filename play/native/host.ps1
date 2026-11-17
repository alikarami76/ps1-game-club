<#
Host a RetroArch netplay game (Windows).
  .\host.ps1 -Game "C:\path\Game.cue" [-Nick Name] [-Port 55435]
Friends then run join.ps1 with your address. Netplay shares controller input: it works for
games that already have a local 2+ player mode.
#>
param([Parameter(Mandatory=$true)][string]$Game, [string]$Nick = "Host", [int]$Port = 55435)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"
if (-not (Test-Path $Game)) { throw "Game file not found: $Game" }
$ra = Find-RetroArch; $core = Find-Core $ra
Write-Host "Hosting on port $Port (TCP). Friends join with: .\join.ps1 -HostAddress <your-address> -Game <their copy> -Port $Port"
& $ra -L $core --appendconfig "$PSScriptRoot\netplay.cfg" --host --port $Port --nick $Nick $Game
