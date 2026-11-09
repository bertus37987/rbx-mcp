# rbx skill: armor / rigging — computable 3D assets

Turn arbitrary meshes into equipped NPC gear.

## Flow

1. `rbx_import_mesh {file}` — local FBX/GLB/OBJ → MeshPart (Blender: GLB, 1 BU = 1 stud, Y-up).
   Or `rbx_insert_asset {asset_id}` for catalog/creator-store items.
2. `rbx_validate_asset {path}` — collision fidelity Box, CanCollide=false on decor, anchored check.
3. `rbx_rig_npc {rig_type: "R15", name, position, description}` — fresh Humanoid rig.
4. Per piece: `rbx_fit_accessory {item_path, rig_path, attachment, mode}`.
   - `mode:"accessory"` → proper Accessory object (Handle + Attachment aligned to body attachment). Correct for Marketplace-style gear.
   - `mode:"weld"` → WeldConstraint to the limb, Massless+no-collide. Better for fixed NPC armor sets.
   - Slot names: HatAttachment, NeckAttachment, LeftShoulderAttachment / RightShoulderAttachment, WaistFrontAttachment / WaistCenterAttachment / WaistBackAttachment, BodyFrontAttachment / BodyBackAttachment.
5. Whole sets in one call: `rbx_equip_npc {rig_path, items:[{item_path, attachment, mode, offset_cframe}]}`.
6. Proof: `rbx_render_thumbnail {rig_path}` → `studio.screen_capture` upstream.

## Attachment math (already implemented)

Accessory alignment = `Handle.CFrame = bodyAttachment.WorldCFrame * handleAttachment.CFrame:Inverse()`.
Extra orientation fixes go in `offset_cframe` {pos={x,y,z}, rotDeg={x,y,z}}.

## Failures to expect

- CreateHumanoidModelFromDescription may fail in exotic states → rig_npc falls back to a minimal block rig (fallback_used=true).
- `rbx_attach_part mode:"bone"` needs skinned bones — classic R15 rigs have attachments, not Bones.
