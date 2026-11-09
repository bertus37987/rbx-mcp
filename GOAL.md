# GOAL — rbx-mcp: cinematic, high-quality, complex-game ready

The goal is NOT done until every criterion below is implemented AND verified
live in Studio. No stubs, no "documented but broken" paths.

## Acceptance criteria

### A. Mesh pipeline (foundation)
- [ ] `rbx_import_mesh` imports a real Blender OBJ as MeshPart via chunked
  EditableMesh (each broker call <90s; no lease-death mid-import)
- [ ] EcthelionTower.obj (680 verts) imports end-to-end and lands in Workspace
- [ ] `rbx_validate_asset` report attached to every import

### B. Visual quality
- [ ] `rbx_vfx` presets live: fire.torch/brazier, weather.rain/snow/mist,
  magic.portal, explosion, banner — verified by inspecting created emitters
- [ ] `rbx_build` recipes live: ≥10 builders (gothic_wall, gothic_arch,
  buttress, crenellated_wall, spire, stair_flight, curtain_wall, tower_stack,
  interior_shell, courtyard, colonnade, keep)
- [ ] `rbx_set_material` sets Material + MaterialVariant
- [ ] `rbx_lighting` v2: fog controls + sky presets (LightingStyle write
  probed, graceful if blocked)

### C. Modular kit pipeline (the star)
- [ ] `kits/mesh/gothic/` Blender generator produces ≥10 snap-grid pieces
- [ ] `rbx_kit_build` imports all pieces into ServerStorage.RbxKit.gothic
- [ ] `rbx_kit_place` instancing: place ≥20 clones of 3 pieces, MeshIds shared
- [ ] Showcase: Minas Tirith gate+tier-1 facade rebuilt with kit pieces,
  before/after screenshot captures verify visual upgrade

### D. Living worlds
- [ ] `rbx_populate` creates working NPC crowd (≥5 rigs, jobs, name tags)
- [ ] `kits/dialog` materializes a working dialogue (ProximityPrompt → GUI)
- [ ] `kits/world` runs a day/night + weather cycle in play mode
- [ ] manifest: SimplePath, ZonePlus, RaycastHitbox, FastCast, ProfileService,
  TopbarPlus install multi-file (repo paths verified, no 404s)

### E. Cinematic + verify + perf
- [ ] `rbx_cutscene` produces a camera-spline cutscene script
- [ ] `rbx_scenario` v2: parts_in_region/count_under/memory_mb expects +
  shot-step camera staging
- [ ] `rbx_optimize` audits a scene (collide/query/touch fixes, streaming)
- [ ] `rbx_audio` creates ambience/reverb presets

### F. GUI (extra focus)
- [ ] ≥6 new patterns: slider, toggle, dropdown, radial_menu, tabs_bar,
  keybind_hint, loading_screen, minimap_frame (as many as practical)
- [ ] `rbx_gui_animate` tween presets (slide_in/fade/bounce/pulse)
- [ ] `rbx_gui_component` behaviors (draggable, hover_fx, click_scale)
- [ ] `rbx_build_gui` composite 'game_hud' (health+stamina+minimap+hotbar
  layout in one call)

### G. Quality gates
- [ ] `test/selftest.mjs` green (protocol roundtrip)
- [ ] `test/live.mjs` extended to cover all new tools → ~85/85 green
- [ ] CAPABILITIES.md + README tool counts updated, skills written:
  kit-pipeline.md, vfx.md, living-worlds.md, gui-v2.md
- [ ] All work pushed to github.com/bertus37987/rbx-mcp

## Architecture (fixed decisions)
- Zero-dep .mjs, stdio MCP → system broker → plugin (single file RbxMcp.lua)
- Generation → Blender upstreams (rbx3d/blender/mixar); import → our MCP
- Kits = `kits/*.lua` + `builders/*.lua` (server prepends config, runs luau)
- New plugin commands return structured results; waypoint before mutations
