# rbx skill: terrain

`rbx_terrain_generate` writes voxel terrain in chunks (4-stud cells, 64³-cell writes, one task.wait per chunk — Studio never freezes).

## Parameter recipes

- Rolling hills: `{size:{x:512,z:512}, mountain_height:40, ridge:0, materials:"plains"}`
- Real mountains: `{size:{x:1024,z:1024}, base_height:10, mountain_height:220, ridge:0.75, materials:"alpine"}`
- Desert mesas: `{materials:"desert", ridge:0.3, mountain_height:90}`
- Volcanic: `{materials:"volcanic", ridge:0.8}`
- Lake: `water_level: <y>` — fills below-water cells with Water material.
- Build plateaus: `flatten_zones:[{x,z,r,h}]` — blend terrain height toward h inside radius r (spawn pads, city sites).

## Workflow

1. Small preview first (512²), check `studio.screen_capture`.
2. Scale up. 1024² ≈ 16 chunk writes per axis sweep.
3. `rbx_terrain_smooth` on the region to remove voxel stair-stepping.
4. Blend kit placement (rbx_kit_place or rbx_apply_kit) onto flattened zones.
