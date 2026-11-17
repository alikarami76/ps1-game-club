# Which engine scripts are game-specific

The engine started as a remake of one game, Twisted Metal (USA, PS1). Its netcode, server, web hosting and
data-loading framework are game-independent; some scripts were written for Twisted Metal's own formats and
rules. Splitting those out would have meant a large refactor of a project that works, so they stay here and
this page says which is which. The project runs straight from this folder either way.

If you start a remake of another game, keep the **generic** parts, and treat the **Twisted Metal** parts as a
worked example to replace.

## Generic (any game)

| Area | Files |
|---|---|
| Networking: transport, wire format, delta snapshots | `scripts/net/transport.gd`, `proto.gd`, `snapshot.gd` |
| Dedicated server, lobbies, one World3D per match | `scripts/server/game_server.gd`, `lobby.gd`, `scenes/server.tscn` |
| HTTPS/WSS single-origin web server, self-signed certificate | `scripts/server/web_file_server.gd`, `server_tls.gd` |
| Access gate and proxy mode (`--behind-proxy`, `TM_ACCESS_KEY`) | `scripts/server/access_gate.gd` |
| Client connection, lobby browser | `scripts/autoload/net.gd` |
| Settings, roles, command line | `scripts/autoload/game.gd` |
| Game-data folder, desktop and browser (IndexedDB) | `scripts/autoload/game_data.gd`, `scripts/ui/web_data_import.gd` |
| Manifest-only reader of game data | `scripts/disc/disc_files.gd` |
| Content seams (swap where arenas, cars and sounds come from) | `scripts/providers/*`, `scripts/audio/audio_provider.gd` |
| Built-in stand-in content (no game data needed) | `scripts/providers/procedural_arena.gd`, `procedural_vehicles.gd`, `scripts/audio/procedural_audio.gd` |
| Prediction-friendly kinematic vehicle step, reconciliation, interpolation | `scripts/gameplay/vehicle.gd` (`sim_step`), `match.gd`, `net_stats.gd` |
| Bots | `scripts/gameplay/bot_ai.gd` (skill numbers calibrated on Twisted Metal) |
| Modern front end and HUD | `scripts/ui/main_menu.gd`, `hud.gd` |
| PS1 rendering helpers | `scripts/disc/vram.gd` (PS1 VRAM, TIM), `upscale.gd` (Scale2x), `atlas.gd`, `scripts/render/ps1_look.gd`, `ps1_settings.gd` |
| WAV and OGG loading | `scripts/audio/wav_loader.gd`, `sfx_player.gd` |
| Hosting script, export presets | `host.sh`, `export_presets.cfg` |
| Network tests | `tests/net/*` |

## Twisted Metal specific

| Area | Files |
|---|---|
| DMD model decoder (port of `games/twisted-metal/dmd.py`) | `scripts/disc/dmd.gd` |
| Manifest layout made by `games/twisted-metal/organize.py` | `scripts/disc/manifest.gd` |
| Arenas, cars, props, damage states from DMD/TMS | `scripts/disc/disc_arena_provider.gd`, `disc_vehicle_models.gd`, `disc_vehicle_visual.gd`, `disc_props.gd`, `mesh_builder.gd`, `spawn_sampler.gd`, `sky_follow.gd`, `viewer.gd` |
| Effect sprites from the arena TMS | `scripts/render/disc_fx.gd`, `scripts/gameplay/fx.gd` (disc half) |
| Measured driving model, weapons, ramming, wheel corners | `scripts/gameplay/vehicle_profile.gd`, `vehicle_profiles.gd`, `weapons.gd`, parts of `vehicle.gd` and `match.gd` |
| Destructible props and vehicle damage | `scripts/gameplay/destructibles.gd`, `vehicle_damage.gd` |
| One-player tournament structure | `scripts/gameplay/tournament.gd` |
| Measured chase camera | `scripts/gameplay/chase_camera.gd` |
| Original-layout front end and HUD, disc fonts | `scripts/ui/classic_front.gd`, `classic_hud.gd`, `classic_controls.gd`, `disc_ui.gd`, `bitmap_font.gd` |
| Sounds and music picked from the disc | `scripts/audio/disc_audio.gd`, `menu_sounds.gd` |
| Measured numbers shipped with the engine | `data/tuning.json` (engine format; the full measurement is `games/twisted-metal/data/tuning.json`) |
| Fidelity harness, engine side | `scripts/render/fidelity_capture.gd`, `scripts/tests/fidelity_runner.gd` |
| Disc tests (cross-checks against the Python decoder) | `tests/disc/*` |

`HANDOFF_NETWORKING.md` and `HANDOFF_DISC_LOADER.md` are the working notes from building the engine, kept
because they record the measurements and the bugs found on the way. The ports and test commands in them
refer to this folder.
