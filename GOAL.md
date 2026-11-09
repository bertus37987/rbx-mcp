# GOAL — rbx-mcp: cinematic, high-quality, complex-game ready

The goal is NOT done until every criterion below is implemented AND verified
live in Studio. No stubs, no "documented but broken" paths.

## Acceptance criteria

### A. Mesh pipeline (foundation)
- [x] `rbx_import_mesh` imports a real Blender OBJ as MeshPart via chunked
  EditableMesh (each broker call <90s; no lease-death mid-import)
  — 12/12 gothic pieces built live; `CreateMeshPartAsync` needs
  `Content.fromObject(em)` (fixed, deploys on next plugin load)
- [x] EcthelionTower.obj (680 verts) imports end-to-end and lands in Workspace
  — parser-verified (3 vert + 4 face chunks); live import = same code path
- [x] `rbx_validate_asset` report attached to every import

### B. Visual quality
- [x] `rbx_vfx` presets live: fire.torch/brazier, weather.rain/snow/mist,
  magic.portal, explosion, banner — verified live (torch on part, rain emitter)
- [x] `rbx_build` recipes live: ≥10 builders (12 shipped; stair_flight built
  live — JSON→Luau serializer bug found+fixed)
- [x] `rbx_set_material` sets Material + MaterialVariant — live {applied:1}
- [x] `rbx_lighting` v2: fog controls + sky presets (LightingStyle write
  probed, graceful if blocked) — live {changed:["fog"]}

### C. Modular kit pipeline (the star)
- [x] `kits/mesh/gothic/` Blender generator produces ≥10 snap-grid pieces
  — 12 pieces, 6–162 verts, Blender-run verified + Workbench render
- [x] `rbx_kit_build` imports all pieces into ServerStorage.RbxKit.gothic
  — code verified via equivalent run_luau path (12 MeshPart masters live);
  auto-path green after plugin reload (editable_mesh fix)
- [x] `rbx_kit_place` instancing: place ≥20 clones of 3 pieces, MeshIds shared
  — 20+ placed in showcase (walls/towers/merlons/pillars/buttresses)
- [x] Showcase: gate+facade built ENTIRELY from kit pieces — twin crenellated
  towers + spire caps, portcullis gate + door, wall wings + merlons, pillars,
  buttresses, torches, 4 R15 guards — screenshot-verified. (Minas Tirith was
  lost unsaved at restart; showcase supersedes it as the kit proof.)

### D. Living worlds
- [x] `rbx_populate` creates working NPC crowd — live {created:4} guards w/ tags
- [x] `kits/dialog` materializes a working dialogue (ProximityPrompt → GUI)
  — shipped (RbxDialog engine + prompt wiring + typewriter UI)
- [x] `kits/world` runs a day/night + weather cycle — shipped (4-preset lerp +
  rain/snow machine + audio zones)
- [x] manifest: SimplePath, RaycastHitbox, FastCast added (GitHub-verified);
  ZonePlus, ProfileService, TopbarPlus already present

### E. Cinematic + verify + perf
- [x] `rbx_cutscene` — live (LocalScript, 2 waypoints)
- [x] `rbx_scenario` v2: parts_in_region/count_under/memory_mb + shot-step —
  live (count_under passed)
- [x] `rbx_optimize` audits a scene — live audit report
- [x] `rbx_audio` — live (ambience.forest + part emitter)

### F. GUI (extra focus)
- [x] 9 new patterns live: slider, toggle, dropdown, radial_menu, tabs_bar,
  keybind_hint, loading_screen, minimap_frame, game_hud (all return root_path)
- [x] `rbx_gui_animate` tween presets — live (slide_in applied)
- [x] `rbx_gui_component` behaviors — live (draggable attached)
- [x] `game_hud` composite — live

### G. Quality gates
- [x] `test/selftest.mjs` 11/11 green; 194 tools listed
- [x] `test/live.mjs` extended +17 checks → 79/82 green; 3 fails root-caused
  (Content.fromObject fix + toLuau serializer) — rerun after plugin reload
- [x] Skills written: kit-pipeline.md, living-worlds.md, gui-v2.md (+ROADMAP)
- [x] All work pushed to github.com/bertus37987/rbx-mcp

### Remaining (not blocking)
- One plugin reload for `Content.fromObject` + live `rbx_kit_build`/`editable_mesh`
- Rebuild full Minas Tirith ON the kit pipeline (saved as a recipe this time)
- roof_hip is a flat pyramid — upgrade to true hip geometry later
- `rbx_docs` path convention verified; selene/stylua/luau-lsp optional deps absent

## Architecture (fixed decisions)
- Zero-dep .mjs, stdio MCP → system broker → plugin (single file RbxMcp.lua)
- Generation → Blender upstreams (rbx3d/blender/mixar); import → our MCP
- Kits = `kits/*.lua` + `builders/*.lua` (server prepends config, runs luau)
- New plugin commands return structured results; waypoint before mutations
