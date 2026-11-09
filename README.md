# rbx-mcp

Roblox Studio MCP server — verification, native GUI building, computable assets (NPC armor), terrain generation, game kits — plus routing to the official Studio MCP and Blender bridges. Zero-dep Node (`.mjs`, no npm install needed). **57 tools.**

## Pieces

```
agent ──stdio──> rbx-mcp serve ──HTTP──> broker 127.0.0.1:58420 <── long-poll ── Studio plugin (RbxMcp.lua)
                     │                        ▲ autostarted at login (Windows Startup folder)
                     ├─ upstreams (studio.*, rbx3d.*, blender.*) — routed MCP tools
                     └─ dashboard http://127.0.0.1:58420/
```

The broker is a **system service**, not a per-agent process: `rbx-mcp install` writes a hidden startup launcher, so `127.0.0.1:58420` is always up. `serve` attaches to it via HTTP (embedded fallback when standalone). The plugin auto-connects with retry + watchdog — zero clicks after install.

## Install

```bash
node packages/rbx-mcp/bin/rbx-mcp.mjs install     # plugin + agent configs + broker autostart
```

Plugin auto-connects on load — drop `plugin/RbxMcp.lua` into `%LOCALAPPDATA%\Roblox\Plugins` and **restart Studio** (once). Then: **Game Settings → Security → Allow HTTP Requests**.

## Tool groups (57)

| Group | Tools |
|---|---|
| Core | `rbx_studios` `rbx_ping` `rbx_run_luau` `rbx_get_tree` `rbx_inspect` `rbx_console` `rbx_select` |
| Scripts | `rbx_read_script` `rbx_write_script` (optimistic hash) `rbx_find_replace` `rbx_sync_pull` `rbx_sync_push` |
| Instances | `rbx_create_instance` `rbx_set_properties` `rbx_set_attribute` `rbx_tag` `rbx_move` `rbx_clone` `rbx_delete` |
| Batch/undo | `rbx_batch` (one waypoint, many ops) `rbx_checkpoint` `rbx_undo` |
| Verify | `rbx_snapshot` `rbx_diff` `rbx_gui_audit` `rbx_security_scan` `rbx_validate_asset` `rbx_lint` `rbx_format` `rbx_typecheck` |
| GUI | `rbx_build_gui` (12 native patterns + themes) `rbx_gui_theme` `rbx_wrap_image` |
| 3D/NPC | `rbx_rig_npc` `rbx_fit_accessory` `rbx_attach_part` `rbx_equip_npc` `rbx_npc_behavior` `rbx_import_mesh` `rbx_mesh_watch` `rbx_insert_asset` `rbx_render_thumbnail` `rbx_build_animation` |
| Terrain | `rbx_terrain_generate` (fBm + ridged mountains, flatten zones, water) `rbx_terrain_smooth` `rbx_terrain_clear` |
| Knowledge | `rbx_api_class` `rbx_api_enum` (official API dump, cached) `rbx_docs` (create.roblox.com markdown) `rbx_skill` `rbx_kits` |
| Systems | `rbx_apply_kit` `rbx_install_module` `rbx_play_state` |
| Routing | `rbx_upstream_status` `rbx_call_upstream` `studio.__status` (+ all `studio.*`/`rbx3d.*`/`blender.*` passthroughs) |

## Agent usage

1. `rbx_studios` → studio_id
2. Build/verify with `rbx_*` tools; screenshots/play-mode route through `studio.*` upstream
3. `rbx_skill` loads knowledge packs (verification-loop, gui-patterns, armor-rigging, terrain, upstream-routing)
4. Use `rbx_batch` for multi-step builds — one waypoint, one undo

## Layout

- `src/mcp.mjs` — zero-dep MCP stdio server + upstream clients (stdio + streamable HTTP)
- `src/broker.mjs` — localhost bridge: long-poll, exactly-once leases, chunked results, `/api/state`, dashboard
- `src/router.mjs` — upstream MCP multiplexing (`rbx-mcp.config.json`)
- `src/tools.mjs` — tool schemas (dense descriptions = embedded docs)
- `src/localtools.mjs` — snapshot diff, selene/stylua/luau-lsp, kit+skill catalogs, API dump, docs, mesh watch
- `src/install.mjs` — plugin copy + client config writers
- `plugin/RbxMcp.lua` — self-contained Studio plugin (drop-in .lua, auto-connect)
- `ui/index.html` — dashboard (light, minimal)
- `kits/*.lua` — game-system templates (obby, economy, …)
- `vendor/manifest.json` — pinned OSS Luau modules
- `skills/*.md` — on-demand knowledge packs
- `test/selftest.mjs` — protocol-level self-test (fake plugin, no Studio needed): `npm test`
