<#
Join a RetroArch netplay host (Windows).
  .\join.ps1 -HostAddress <address> -Game "C:\path\Game.cue" [-Nick Name] [-Port 55435]
Use the same game (same dump) and the same RetroArch and core versions as the host.
#>
param([Parameter(Mandatory=$true)][string]$HostAddress, [Parameter(Mandatory=$true)][string]$Game, [string]$Nick = "Guest", [int]$Port = 55435)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"
if (-not (Test-Path $Game)) { throw "Game file not found: $Game" }
$ra = Find-RetroArch; $core = Find-Core $ra
& $ra -L $core --appendconfig "$PSScriptRoot\netplay.cfg" --connect $HostAddress --port $Port --nick $Nick $Game
