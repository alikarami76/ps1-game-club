# Native play: RetroArch with PCSX-ReARMed and built-in netplay

This is the sturdier way to play a PS1 game with friends. RetroArch runs on macOS, Windows and Linux, the PCSX-ReARMed core emulates the PlayStation (it works with no Sony BIOS), and RetroArch's own netplay shares each player's controller over the network.

You supply the game. Nothing here includes or downloads games or a BIOS.

## What netplay can and cannot do

Netplay shares **controller input**. Every player's computer runs the same game and they all get the same button presses, so the games stay in step.

- It works for games that already have a **local two-or-more player mode**, up to the number of players the game supports.
- A PS1 **multitap** allows up to 8 players in the games that support it. Turn on the core option `pcsx_rearmed_multitap` for those.
- It does **not** add multiplayer to a single-player game. If the game has no second-player mode, netplay has nothing to share. Adding online multiplayer to such a game needs a remake, which is what the remake kit elsewhere in this repository is for.
- Everyone needs the **same game** (same dump, same region) and the **same RetroArch and core versions**. Games drift apart if the files differ.

## 1. Install

1. Install RetroArch from <https://www.retroarch.com> (or `brew install --cask retroarch`, your Linux package manager, or Flatpak `org.libretro.RetroArch`).
2. Open RetroArch, then **Load Core > Download a Core > Sony - PlayStation (PCSX ReARMed)**.
3. Optional: if you own a PlayStation, you can copy your own BIOS file (for example `scph5501.bin`) into RetroArch's `system` folder and set the core option *BIOS Selection* to `auto`. The default `HLE` option needs no BIOS.

Keep your game as a `.cue` plus its `.bin` files in one folder, or as a `.chd` or `.pbp` file.

## 2. Host a game

macOS and Linux:

```sh
./host.sh "/path/to/Game.cue" MyName
```

Windows (PowerShell):

```powershell
.\host.ps1 -Game "C:\Games\Game.cue" -Nick MyName
```

The host is player 1. Tell your friends your address (see "Finding the address" below) and the port, `55435` by default.

## 3. Join a game

macOS and Linux:

```sh
./join.sh 192.0.2.10 "/path/to/Game.cue" FriendName
```

Windows (PowerShell):

```powershell
.\join.ps1 -HostAddress 192.0.2.10 -Game "C:\Games\Game.cue" -Nick FriendName
```

Replace `192.0.2.10` with the host's address. The joiner loads their own copy of the same game, connects, and becomes player 2 (then 3, and so on).

You can also do it by hand inside RetroArch: load the game, open the Quick Menu, then **Netplay > Host > Start Netplay Host**, or on a friend's machine **Netplay > Join > Enter Address**.

## Settings the scripts apply

The scripts pass `netplay.cfg` with `--appendconfig`, so it only applies to that run and never changes your normal RetroArch settings. It sets:

| Setting | Value | Why |
| --- | --- | --- |
| `netplay_ip_port` | `55435` | Default RetroArch netplay port (TCP). |
| `netplay_input_latency_frames_min` / `_range` | `2` / `3` | A small delay buffer that keeps play smooth on a home network. Raise both for internet play. |
| `netplay_check_frames` | `600` | Notices if the two games drift apart. |
| `netplay_nat_traversal` | `true` | Asks a UPnP router to open the port. |
| `netplay_public_announce` | `false` | Keeps your game off the public lobby. |
| `netplay_use_mitm_server` | `false` | No third-party relay unless you turn it on. |

`pcsx_rearmed.opt` holds core options (BIOS choice, dynamic recompiler, multitap). Copy it to `<RetroArch config folder>/config/PCSX-ReARMed/PCSX-ReARMed.opt` if you want those values. The config folder is:

- macOS: `~/Library/Application Support/RetroArch`
- Linux: `~/.config/retroarch` (Flatpak: `~/.var/app/org.libretro.RetroArch/config/retroarch`)
- Windows: the folder that holds `retroarch.exe` (or `%APPDATA%\RetroArch`)

## Finding the address

- Same home or office network (LAN): the host's local address, for example from `ipconfig` (Windows), `ipconfig getifaddr en0` (macOS) or `hostname -I` (Linux).
- Over the internet: the host's public address, and the host forwards **TCP port 55435** on the router to their computer. If that is not possible, turn on `netplay_use_mitm_server` in RetroArch's Netplay settings to go through RetroArch's public relay (it adds delay), or use a VPN or overlay network that puts everyone on one virtual LAN.

## Finding RetroArch and the core

The scripts look in the usual places. Override them with environment variables when yours is elsewhere:

```sh
RETROARCH=/path/to/retroarch PCSX_CORE=/path/to/pcsx_rearmed_libretro.so ./host.sh "Game.cue"
```

On Windows set `$env:RETROARCH` and `$env:PCSX_CORE` first.

## Troubleshooting

- *Games drift apart or show a desync warning:* check everyone has the identical dump and the same core version. Try turning the dynamic recompiler off in the core options on every machine.
- *Buttons feel late:* lower `netplay_input_latency_frames_min`, or move the players onto a wired or closer connection.
- *Nobody can connect:* check the host's firewall allows TCP 55435, and on the internet that the router forwards it.
- *Black screen with no BIOS:* some games need a real BIOS. Use your own dump, as described above.
