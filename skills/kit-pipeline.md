# Modular Kit Pipeline — real detail at part-level cost

The single biggest visual-quality lever. Instead of thousands of unique boxes,
build ~10-30 detailed pieces ONCE in Blender, import once, then instance
everywhere. Clones share the same MeshId → Roblox renders them as instances
(fast) and they look like real geometry (arches, tracery, mouldings).

## Flow

1. **Generate pieces** — `kits/mesh/<kit>/gen_<kit>.py` runs in Blender
   (rbx3d `run_bpy` or `blender -b --python`). Conventions: 1 BU = 1 stud,
   Z-up, ONE mesh object per piece (join sub-parts), flat shading,
   triangulated, pivot = lower-left-front at origin, dimensions on the kit's
   snap grid (gothic: 8 studs).
2. **Build library** — `rbx_kit_build {kit:"gothic"}` parses each OBJ
   (`src/mesh.mjs`), sends verts/faces to `editable_mesh` in ≤250-vert chunks
   (each call <90s lease), creates `ServerStorage.RbxKit.<kit>.<piece>` masters.
3. **Place instances** — `rbx_kit_place {kit, piece, transforms:[{pos,rot}]}`
   clones masters. `rbx_kit_pieces {kit}` lists the library.

## Rules

- Keep pieces ≤800 tris (Roblox limit 20k, but kits live on reuse)
- Grid discipline: every piece must tile on `spec.grid` — never eyeball
- Pivot convention is sacred: `lower-left-front` = predictable snapping
- One mesh object per piece (join!) — Roblox MeshPart ≠ multi-object model
- Generated OBJs are COMMITTED (`out/` not ignored) → `source:'files'` works
  without Blender installed
- Quality ceiling: Open Cloud upload (needs ROBLOX_API_KEY) gives real
  assetIds + textures — EditableMesh path is geometry-only

## When to use what

- `rbx_kit_build`+`kit_place` → hero architecture, repeated detail, big scenes
- `rbx_build` recipes → one-off parametric structures (walls, keeps)
- `rbx_create_instance`/`batch` → massing/blockout, gameplay parts
- `rbx_vfx` → atmosphere (fire/weather/magic/banners)
