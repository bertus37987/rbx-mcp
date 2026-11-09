# rbx skill: upstream routing

rbx-mcp multiplexes other MCP servers under `server.tool` names.

## Why

- The official Studio MCP owns: screen_capture, playtests (Client/Server datamodels), open_cloud_invoke, generate_* AI tools, the rbx-* skills.
- rbx-mcp owns: verification (snapshot/diff/audits), native GUI building, armor/rig ops, terrain, kits, script sync + linting.
- Blender pipelines ride through `blender.*` / `rbx3d.*` upstreams (export GLB → rbx_import_mesh).

## Wiring

`rbx-mcp.config.json`:
```json
{ "upstreams": {
    "studio": { "kind": "http", "url": "http://127.0.0.1:<port>/mcp" },
    "rbx3d":  { "kind": "stdio", "command": "uvx", "args": ["rbx3d-mcp"] }
}}
```
Studio's port: Assistant → Settings → MCP Servers.

## Rules

- Check `rbx_upstream_status` before planning around studio.* tools.
- `studio.__status` explains how to connect when down.
- Prefer dedicated `studio.<tool>` tools; `rbx_call_upstream` is the escape hatch.
- Play datamodels: route `studio.execute_luau` with datamodel_type Client/Server — rbx-mcp's plugin only sees the Edit datamodel.
