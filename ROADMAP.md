# rbx-mcp — Improvement Roadmap (cinematic worlds)

Goal: go from "working builder" (Minas Tirith tier-1 result) to a tool that
produces genuinely impressive, detailed, living worlds. Ordered by impact.

## P0 — Visual quality unlocks (the biggest gap)

### 1. Modular kit pipeline — `rbx_kit_build`  ⭐ top priority
Minas Tirith was monolithic boxes. Real cities = ~30-50 detailed pieces,
instanced thousands of times (official Roblox modular-kit method).

- Kit spec JSON → Blender batch-build (rbx3d/blender upstream: walls, arches,
  gothic windows, merlons, buttresses, stairs, gate pieces, trims — all on a
  fixed snap grid, e.g. 8-stud increments, uniform pivots)
- Import each piece ONCE via EditableMesh (slow import is fine — it's per piece,
  not per instance) → then `clone` — clones share MeshId = free instancing
- New plugin cmd `kit_place {piece, cells}` places snapped clones
- Result: real 3D detail (tracery, mouldings) at part-level performance

### 2. Builder library in plugin — `rbx_build {recipe, params}`
Ship Lua builder modules inside the plugin (not per-call run_luau):
`gothic_arch, crenellation, buttress, spire, roofline, curtain_wall, courtyard,
interior_shell, stair_flight` — correct proportions + detail passes baked in.
Turns "753 raw parts" into "753 detailed parts" at zero extra cost.

### 3. VFX authoring — `rbx_vfx`
ParticleEmitter preset factory: `weather.rain/snow/embers/mist`, `fire.torch/
brazier/chimney_smoke`, `magic.portal/rune`, `banner.wave` (attachment+beam),
Explosion presets. Minas Tirith had torches only — VFX is what reads as "alive".

### 4. Lighting v2 — extend `rbx_lighting`
- `LightingStyle` write (probe: Technology read is blocked, write may work)
- classic `FogStart/FogEnd` + `FogColor` (cheap depth cue)
- interior lighting recipes (Realistic style needs ≥1-stud shells — pair with
  builder library)
- Sky presets: starfield, moon, custom star/sun counts

### 5. Materials — `rbx_set_material`
`MaterialService`/`MaterialVariant` custom terrain materials + SurfaceAppearance
hints on parts; expose Roblox's full material palette (we used ~4 of 20+).

## P1 — Living worlds

### 6. System libraries in `install_module` manifest
Battle-tested, multi-file (our repo-tree install already handles it):
`SimplePath` (NPC pathfinding), `ZonePlus` (zones/triggers/quests),
`RaycastHitbox` + `FastCast` (melee/projectile combat),
`ProfileService` (data persistence), `MrDialogue` (branching dialogue),
`TopbarPlus`, `Cmdr`. Agent gets production systems, not hand-rolled slop.

### 7. NPC population — `rbx_populate`
Crowd system: N NPCs, `HumanoidDescription` outfits/variants, jobs+schedules
(guards on patrol loops, vendors at stalls, ambient walkers), overhead name
tags, random idle animation pools. Uses SimplePath when installed, else
waypoint fallback.

### 8. Dialogue kit — `rbx_dialog` (own kit, no dependency)
Branching trees as Luau tables → ProximityPrompt → `build_gui` dialog pattern
→ server-authoritative conditions/actions/quest hooks.

### 9. World system — `rbx_world`
Server script: day/night cycle (ClockTime tween + atmosphere transitions),
weather states (rain/snow/storm = VFX + audio + fog), ambient audio zones.
A static dawn looks good; a living cycle looks cinematic.

## P2 — Cinematics & verification

### 10. Cutscene — `rbx_cutscene`
Catmull-Rom camera spline through waypoints, DOF rack-focus, letterbox GUI,
shake. For trailers + scene showcase + the screenshot-verify loop below.

### 11. Screenshot verify loop — `rbx_capture`
No Lua pixel-readback (engine limit). Chain: stage camera via `rbx_cutscene`
→ capture via upstream `studio.screen_capture` or OS-level (cua-driver) →
agent inspects image → fix pass. We did this manually on Minas Tirith —
productize it as `rbx_scenario` steps: `{shot:{camera...}, expect:{...}}`.

### 12. Scenario v2
New expectation types: `parts_in_region`, `memory_mb`, `screenshot` (stores
latest capture ref), `event` (wait for signal). Plus `record`→replay.

## P3 — Performance & interiors

### 13. `rbx_optimize` — StreamingEnabled on, per-region part audit,
StreamingMeshLOD, CanCollide=false + CanQuery=false on decor, physics sleep.

### 14. Interior kit — furniture/props builders + interior lighting recipe;
Minas Tirith is currently a shell city.

### 15. Audio — `rbx_audio`: positional emitters, ambience zones, music layers,
SoundService.AmbientReverb presets (cave/cathedral/field).

## P4 — Pipeline hardening

- **EditableMesh import speed**: chunk `AddVertex`/`AddTriangle` across
  `task.wait()` inside the plugin so >90s leases don't kill it (observed:
  lease death killed the 680-vert tower import mid-flight — run under
  `task.spawn`, poll progress)
- **Texture upload**: `studio.upload_image` upstream for decals/UI art
- **Save**: investigate `plugin:SavePlace()`-equivalent or prompt user
- **Rojo scaffold**: `rbx_project_scaffold` — real project.json + src tree so
  teams can git/CI the world

## Not doing (deliberate)
- In-Studio chat UI (agents call tools directly)
- Image generation for UI (native GuiObjects > textures)
- Marketplace plugin publish (local install is the product)
