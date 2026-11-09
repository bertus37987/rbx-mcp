# Living Worlds — population, dialogue, cycles, audio

A static city looks dead. These tools make it feel inhabited.

## Population — `rbx_populate`

`{count, area:{center,radius}, jobs:[{type:'patrol'|'idle'|'vendor'|'guard', waypoints?}], names:[...]}`
→ real R15 rigs, randomized descriptions, BillboardGui name tags, per-job
behavior scripts. Density rule: ~1 NPC per 40-60 studs of street — more reads
as crowd, less as ghost town.

## Dialogue — `rbx_apply_kit {kit:"dialog"}`

Materializes: `RbxDialog` engine module (line/choice/branch/action nodes,
server-authoritative sessions) + ProximityPrompt wiring + typewriter UI.
Trees are plain Luau tables — conditions/actions hook game state.

## World system — `rbx_apply_kit {kit:"world"}`

Server script: day/night cycle (ClockTime tween, cfg.cycle_minutes),
atmosphere lerp between dawn/noon/sunset/night, weather state machine
(clear→rain/snow by climate) driving VFX emitters + fog + sound.

## Audio — `rbx_audio`

`ambience.forest|cave|cathedral|city|night|wind` → Looped Sound on part with
RollOff distance; `music.layer` via SoundGroup; `reverb.*` sets
AmbientReverb. Layer: 1 ambience per district + 1 music layer + reverb preset.

## Modules that extend this (`rbx_install_module`)

- `SimplePath` — real pathfinding for patrols (drop-in over our waypoint walk)
- `ZonePlus` — zone triggers for quests/audio/ambience swaps
- `RaycastHitbox` + `FastCast` — melee/projectile combat
- `ProfileService` — session-locked data persistence
- `TopbarPlus` — consistent topbar icons

## Cinematics — `rbx_cutscene` / `kits/cutscene`

Catmull-Rom camera through waypoints + DOF + letterbox + skip-on-Space.
Pair with `rbx_scenario` `{shot:{camera}}` steps → `studio.screen_capture`
or OS screenshot for visual verification.
