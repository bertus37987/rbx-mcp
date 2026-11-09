# rbx-mcp — Capabilities & Gap Analysis

64 tools. Zero-dep Node, stdio MCP → persistent broker (127.0.0.1:58420,
Windows-autostart) → Studio plugin. Exactly-once leases, ChangeHistoryService
waypoints before every mutation, stale-instance freshness in `rbx_studios`.
Live-verified: 60/60 end-to-end checks against real Studio.

## Capability map

| Area | Tools | Status |
|---|---|---|
| Connection | rbx_studios (freshness), rbx_ping, rbx_console | ✅ live |
| Luau exec | rbx_run_luau (+error tracebacks), rbx_batch (1 waypoint) | ✅ live |
| Tree/inspect | rbx_get_tree (depth-paged), rbx_inspect, rbx_select | ✅ live |
| CRUD | rbx_create_instance (typed props + failed-props report), rbx_set_properties (BrickColor/Color3/Enum coercion), rbx_delete, rbx_clone, rbx_move, rbx_set_attribute, rbx_tag, rbx_find_replace (regex over all scripts) | ✅ live |
| Scripts | rbx_write_script (optimistic hash + auto-create), rbx_read_script | ✅ live |
| Undo | rbx_checkpoint, rbx_undo | ✅ live |
| Verification | rbx_snapshot, rbx_diff, rbx_gui_audit, rbx_security_scan, rbx_validate_asset | ✅ live |
| Native GUI | rbx_build_gui (12 real-GuiObject patterns), rbx_gui_theme, rbx_wrap_image (9-slice/aspect), rbx_ui_sounds (custom SFX wiring) | ✅ live |
| NPC/armor | rbx_rig_npc (real R15), rbx_fit_accessory (AFT-align), rbx_attach_part (attachment/mesh/bone), rbx_equip_npc | ✅ live |
| Animation | rbx_build_animation (pose tables→KeyframeSequence), rbx_npc_behavior (patrol/idle/chase) | ✅ live |
| Terrain | rbx_terrain_generate (fBm+ridged mountains, chunked WriteVoxels, water, flatten zones), rbx_terrain_smooth, rbx_terrain_clear | ✅ live |
| Environment | rbx_lighting (time-of-day, Atmosphere, Sky, Bloom/CC/SunRays/DoF, presets: dawn/sunset/night/noon/storm/overcast) | ✅ new |
| Game tests | rbx_scenario (stepwise cmd+expect runner, stop_on_fail) | ✅ new |
| Meshes | rbx_import_mesh (Content.fromFile GLB/FBX), rbx_mesh_watch (Blender watch-folder auto-import), rbx_render_thumbnail (viewport stage for screen_capture) | ✅ live |
| Assets | rbx_insert_asset (graceful on untrusted), rbx_kits, rbx_apply_kit (obby/economy...), rbx_install_module (11 OSS modules, multi-file tree install) | ✅ live |
| Sync | rbx_sync_pull (Rojo layout → git/lint), rbx_sync_push | ✅ live |
| Knowledge | rbx_api_class, rbx_api_enum (official API dump), rbx_docs, rbx_skill (5 packs), rbx_lint/format/typecheck (selene/stylua/luau-lsp) | ✅ live |
| Upstream | rbx_upstream_status, rbx_call_upstream, `studio.*`/`rbx3d.*`/`blender.*`/`mixar.*` passthrough | ✅ wired |

## Generation routing (deliberate)

| Need | Route | Why |
|---|---|---|
| Meshes/textures | `rbx3d.*`, `blender.*`, `mixar.*` → `rbx_mesh_watch`/`rbx_import_mesh` | Official `generate_mesh`/`generate_texture` quality is poor; Blender gives controllable, Roblox-convention assets |
| Animation | `rbx3d.*` (Blender clips) or `rbx_build_animation` (in-Studio) | Official has no usable clip authoring |
| Playtest/input/screenshots | `studio.*` upstream (start_stop_play, user_keyboard/mouse_input, character_navigation, screen_capture, get_console_output) | Only official can drive real play sessions + pixel capture |
| AI mesh from prompt | `mixar.enqueue_generation` | Credits, but real generation |

## Gaps vs ForgeGUI — honest assessment

| ForgeGUI has | Our status |
|---|---|
| Image-gen for UI graphics | Not replicated by design — we build native GuiObjects instead (resolution-independent, themeable). For icon art: `rbx_render_thumbnail` turntable + `rbx_wrap_image`. |
| One-click plugin install inside Studio | ✅ ours installs file + auto-connects, no Marketplace asset needed |
| Cloud asset pipeline | ❌ none — we can't upload to Roblox cloud (needs API key). Workaround: local files via `rbx_import_mesh`, asset IDs via `rbx_insert_asset`, upstream `studio.upload_image`/`store_image` |
| In-Studio chat UI | ❌ none — agents call tools directly; our dashboard is status/install only |
| Video/marketing content | out of scope (creator-generalist skills cover it if needed) |

## Known limitations (real, not marketing)

- **No pixel readback** — Roblox Lua can't capture viewport pixels. Visual
  verification = structural audits + `rbx_render_thumbnail` staging + upstream
  `studio.screen_capture` when connected.
- **`play_state` start/stop** may be blocked by plugin security — route via
  `studio.start_stop_play`.
- **`insert_asset`** fails on untrusted assets (Roblox-side, not fixable).
- **Luau lint/typecheck** need external binaries (selene/stylua/luau-lsp).
- Plugin reload requires Studio restart (file copied, code loads at startup).
- Multiple same-name siblings: `resolvePath` picks first — prefer unique names.

## creator-generalist audit (github.com/codepawl/creator-generalist)

MIT-licensed, no prompt injection (scan: instruction-overrides, exfiltration,
hidden commands — clean). Converted to Roblox-computable skills:
`lighting.md` (atmosphere/post FX), `game-build-verification.md` (QA gates→
rbx_scenario loop), `ui-sound.md` (design-sound→rbx_ui_sounds),
`blender-asset-pipeline.md`. Their 3D generalist references remain useful
reading for Blender-side work; scripts are AE/Python-toolchain specific, not
vendored.
