# Blender → Roblox Asset Pipeline (THE generation path)

Mesh/texture/animation generation goes through Blender upstreams — NOT the
official `studio.generate_mesh` (low quality, uncontrolled).

## Routing rule

- `rbx3d.*` — Roblox-native modeling+animation toolkit (Blender backend):
  conventions are already Roblox (1 unit = 1 stud, R15, ≤20k tris, one
  SurfaceAppearance per MeshPart). Prefer this first.
- `blender.*` (blender-lab) — general bpy: custom meshes, materials, retopo,
  UVs, texture baking, `generate_3d` for AI base meshes.
- `mixar.*` — prompt→3D generation (credits) + scene tabs.
- `studio.*` — ONLY playtest/input/screenshot/play-mode calls.

## Pipeline: generated mesh → equipped asset

1. `rbx3d.run_bpy` / `blender.execute_blender_code` — build or modify the model
   (or `mixar.enqueue_generation` for AI base → `mixar_call_status` poll).
2. `rbx3d.look` — visual check BEFORE export (silhouette, gaps, proportions).
3. Export GLB/FBX → get it into Studio, in order of quality:

   a) **Open Cloud upload (best, real assetId)** — `rbx3d.roblox_upload`
      needs `ROBLOX_API_KEY` + `ROBLOX_CREATOR_USER_ID`/`_GROUP_ID`
      (env or `C:/Users/willy/rbx3d-mcp/.env`). Uploaded FBX/GLB becomes a
      trusted asset → `rbx_insert_asset {asset_id}` places the real
      MeshPart incl. skinned meshes & SurfaceAppearance.
   b) **rbx_mesh_watch / rbx_import_mesh (local, no key)** — export to the
      watch dir; the plugin builds the mesh via `EditableMesh`
      (verified working; slow >~1k verts — chunk or prefer a).
   c) **studio.upload_image / store_image (upstream)** — images/decals/
      UI textures only; official MCP has no mesh upload.
4. `rbx_fit_accessory` / `rbx_attach_part` — mount onto R15 rigs
   (attachments: HatAttachment, WaistBackAttachment, GripPoint...).
5. `rbx_render_thumbnail` + upstream `studio.screen_capture` — verify in-scene.

## Animation path

`rbx3d` Blender animation tools → R15 skeleton → export clip → insert as
Animation asset; or `rbx_build_animation` for pose-table KeyframeSequences
directly in Studio (no export needed, fastest for simple loops).

## Budget rules (Roblox)

≤20k tris per MeshPart · 4 bone influences max · 1 SurfaceAppearance per part ·
textures ≤1024² for props · armor parts massless + CanCollide=false.
