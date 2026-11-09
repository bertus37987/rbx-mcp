# gen_gothic.py — procedural "gothic" modular-kit generator for the rbx-mcp pipeline.
#
# Runs BOTH:
#   * standalone : "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b --python gen_gothic.py
#   * inside rbx3d MCP's `run_bpy` tool (exec'd in a live Blender; __file__ may be
#     absent -> falls back to cwd, override with env var RBX_GOTHIC_OUT if needed).
#
# Conventions (rbx3d AGENTS.md): 1 Blender unit = 1 stud, +Z up.
#
# Axis mapping — measured on Blender 5.2.1's wm.obj_export with
#   forward_axis='NEGATIVE_Z', up_axis='Y':
#       OBJ(x,y,z) = (Blender.x, Blender.z, -Blender.y)
#   So for the exported piece to occupy x:[0,w] y:[0,h] z:[0,d] with its
#   lower-left-front corner (Roblox -X/-Y/-Z mins) at the origin, the piece is
#   built in Blender space at  x:[0,w]  y:[-d,0]  z:[0,h]  — front face on the
#   y=0 plane facing +Y, depth extending -Y.  finalize() snaps the bbox corner
#   (x_min, y_max, z_min) to the origin anyway, so trim may protrude +Y freely.
#
# Each piece: build parts -> EXACT booleans -> bevel -> join into ONE mesh ->
# triangulate -> outward flat normals -> pivot snap -> export to
# <script_dir>/out/<piece>.obj -> delete.  <= ~800 tris, < 3000 verts (asserted).
#
# NOTE on modifiers: bpy.ops.object.modifier_apply proved unreliable in this
# headless build (produced swapped operand results for booleans), so modifiers
# are baked by evaluating the depsgraph (new_from_object) — context-free and
# deterministic.  bpy.ops.object.join and transform_apply do work headless.

import bpy
import bmesh
import math
import os
import traceback
from math import radians
from mathutils import Vector

# ---------------------------------------------------------------- paths
try:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
except NameError:  # exec'd via run_bpy — no __file__
    SCRIPT_DIR = os.getcwd()
OUT_DIR = os.environ.get("RBX_GOTHIC_OUT", os.path.join(SCRIPT_DIR, "out"))
os.makedirs(OUT_DIR, exist_ok=True)

MAX_VERTS = 3000  # hard assert per piece
RESULTS = {}      # name -> (verts, tris)

# ---------------------------------------------------------------- helpers

def clear_scene():
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        try:
            bpy.ops.object.mode_set(mode='OBJECT')
        except Exception:
            pass
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for coll in (bpy.data.meshes, bpy.data.curves):
        for block in list(coll):
            if block.users == 0:
                coll.remove(block)


def _apply_xform(obj, loc=True, rot=True, scale=True):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=loc, rotation=rot, scale=scale)


def box(name, cx, cy, cz, sx, sy, sz, rot=(0.0, 0.0, 0.0)):
    """Axis box (optionally pre-rotated) centered at (cx,cy,cz); sizes = full dims."""
    bpy.ops.mesh.primitive_cube_add(location=(cx, cy, cz), rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = (sx / 2.0, sy / 2.0, sz / 2.0)
    _apply_xform(o)
    return o


def cyl(name, cx, cy, cz, r, h, n=12, rot=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=n, radius=r, depth=h, location=(cx, cy, cz), rotation=rot)
    o = bpy.context.active_object
    o.name = name
    _apply_xform(o)
    return o


def cone(name, cx, cy, cz, r1, r2, h, n=4, rot=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cone_add(
        vertices=n, radius1=r1, radius2=r2, depth=h,
        location=(cx, cy, cz), rotation=rot)
    o = bpy.context.active_object
    o.name = name
    _apply_xform(o)
    return o


def mesh_obj(name, verts, faces):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.validate(verbose=False)
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def prism_y(name, outline_xz, y0, y1):
    """Extrude a closed XZ outline (list of (x,z)) along Y from y0 to y1."""
    n = len(outline_xz)
    verts = [(x, y0, z) for x, z in outline_xz] + [(x, y1, z) for x, z in outline_xz]
    faces = [tuple(range(n)), tuple(range(2 * n - 1, n - 1, -1))]
    for i in range(n):
        j = (i + 1) % n
        faces.append((i, n + j, n + i, j))
    return mesh_obj(name, verts, faces)


def pointed_arch(cx, y0, y1, hw, z_bot, z_spring, z_apex):
    """Pointed (gothic) arch prism: rect to springline + triangular peak."""
    outline = [
        (cx - hw, z_bot), (cx + hw, z_bot), (cx + hw, z_spring),
        (cx, z_apex), (cx - hw, z_spring),
    ]
    return prism_y("arch", outline, y0, y1)


def round_arch(cx, y0, y1, hw, z_bot, z_spring, segs=8):
    """Round-topped arch prism: rect to springline + semicircular cap (r = hw)."""
    outline = [(cx - hw, z_bot), (cx + hw, z_bot)]
    for i in range(segs + 1):
        a = math.pi * (i / segs)  # right spring corner -> apex -> left corner
        outline.append((cx + hw * math.cos(a), z_spring + hw * math.sin(a)))
    return prism_y("rarch", outline, y0, y1)


def bake_modifiers(obj):
    """Apply ALL modifiers by evaluating the depsgraph — no ops context needed."""
    if not obj.modifiers:
        return
    dg = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(dg)
    me = bpy.data.meshes.new_from_object(ev, depsgraph=dg)
    me.name = obj.data.name + "_baked"
    obj.modifiers.clear()
    old = obj.data
    obj.data = me
    if old and old.users == 0:
        bpy.data.meshes.remove(old)


def join(name, objs):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    o = bpy.context.active_object
    o.name = name
    _apply_xform(o)
    return o


def bool_diff(target, cutter):
    """EXACT boolean difference; cutter object is consumed (deleted)."""
    m = target.modifiers.new('cut', 'BOOLEAN')
    m.operation = 'DIFFERENCE'
    try:
        m.solver = 'EXACT'
    except Exception:
        pass
    m.object = cutter
    bake_modifiers(target)
    bpy.data.objects.remove(cutter, do_unlink=True)
    target.data.validate(verbose=False)
    target.data.update()


def bevel(obj, w=0.15, seg=2):
    m = obj.modifiers.new('bev', 'BEVEL')
    m.width = w
    m.segments = seg
    try:
        m.limit_method = 'ANGLE'
    except Exception:
        pass
    bake_modifiers(obj)


def signed_volume(me):
    v = 0.0
    for p in me.polygons:
        idx = p.vertices
        if len(idx) < 3:
            continue
        a = me.vertices[idx[0]].co
        for i in range(1, len(idx) - 1):
            b = me.vertices[idx[i]].co
            c = me.vertices[idx[i + 1]].co
            v += a.dot(b.cross(c))
    return v / 6.0


def finalize(obj):
    """Triangulate + outward normals + flat shade + pivot snap
    ((x_min, y_max, z_min) -> origin, matching the OBJ axis mapping).
    Returns (verts, tris)."""
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.to_mesh(me)
    bm.free()
    me.update()
    if signed_volume(me) < 0.0:  # whole shell wound inward -> flip
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
        bm.to_mesh(me)
        bm.free()
        me.update()
    for p in me.polygons:
        p.use_smooth = False
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    zs = [v.co.z for v in me.vertices]
    off = Vector((min(xs), max(ys), min(zs)))  # -> OBJ (0,0,0) lower-left-front
    for v in me.vertices:
        v.co = v.co - off
    me.update()
    return len(me.vertices), len(me.polygons)


def export_obj(obj, path):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    if hasattr(bpy.ops.wm, 'obj_export'):  # Blender 3.3+ native exporter
        try:
            props = bpy.ops.wm.obj_export.get_rna_type().properties.keys()
        except Exception:
            props = ()
        kw = dict(filepath=path,
                  forward_axis='NEGATIVE_Z', up_axis='Y',
                  export_selected_objects=True,
                  export_triangulated_mesh=True,
                  apply_modifiers=True,
                  export_normals=True, export_uv=False,
                  export_materials=False,
                  export_object_groups=False)
        if props:  # keep only params this Blender actually exposes
            kw = {k: v for k, v in kw.items()
                  if k == 'filepath' or k in props}
        bpy.ops.wm.obj_export(**kw)
    else:  # legacy python exporter fallback
        bpy.ops.export_scene.obj(filepath=path, use_selection=True,
                                 axis_forward='-Z', axis_up='Y',
                                 use_triangles=True, use_materials=False)

# ---------------------------------------------------------------- pieces
# Build frame: x in [0,w], y in [-d,0] (front face on the y=0 plane), z in [0,h].

def p_wall_plain():
    # 8w x 16h x 4d, slight bevel + top trim band -> one mesh
    body = box("wp_body", 4, -2, 8, 8, 4, 16)
    bevel(body, 0.15, 2)
    band = box("wp_band", 4, -2, 15.4, 8.5, 4.5, 1.2)   # proud 0.25 all sides
    base = box("wp_base", 4, -2, 0.4, 8.3, 4.3, 0.8)    # bottom kick
    return join("wall_plain", [body, band, base])


def p_wall_window():
    wall = box("ww_body", 4, -2, 8, 8, 4, 16)
    hole = pointed_arch(4, -5.0, 1.0, 1.2, 5.0, 10.5, 13.2)
    bool_diff(wall, hole)
    # inset frame ring: proud 0.2 of the front face (+Y), jamb 0.9 into the wall
    outer = pointed_arch(4, -0.7, 0.2, 1.5, 4.8, 10.7, 13.5)
    inner = pointed_arch(4, -1.0, 0.6, 1.0, 5.2, 10.3, 12.6)
    bool_diff(outer, inner)
    return join("wall_window", [wall, outer])


def p_wall_doorway():
    wall = box("wd_body", 4, -2, 8, 8, 4, 16)
    hole = round_arch(4, -5.0, 1.0, 1.6, -0.1, 7.0, segs=10)  # apex 8.6
    bool_diff(wall, hole)
    # U-shaped door frame (no bottom bar: inner cutter runs below the floor)
    outer = round_arch(4, -0.8, 0.2, 1.8, -0.2, 7.2, segs=10)
    inner = round_arch(4, -1.1, 0.6, 1.4, -0.7, 6.9, segs=10)
    bool_diff(outer, inner)
    return join("wall_doorway", [wall, outer])


def p_merlon_run():
    parts = [box("mr_band", 12, -1.5, 1.0, 24, 3, 2)]  # solid base band
    # 8 crenels, 2w x 2h x 1.5d, pitch 3 (1 gap), 0.5 margin each end, front-flush
    for i in range(8):
        parts.append(box(f"mr_c{i}", 1.5 + 3 * i, -0.75, 3.0, 2, 1.5, 2))
    return join("merlon_run", parts)


def p_buttress():
    # foot column fills 6x8 footprint, 16 tall (front face y=0)
    foot = box("bt_foot", 3, -4, 8, 6, 8, 16)
    # flying strut: box rising toward -Y (the wall side), embedded in foot top
    slope = box("bt_slope", 3, -4.25, 17.25, 6, 2.8, 11, rot=(radians(36), 0, 0))
    # pinnacle toward the back top + pyramid cap -> 24h total
    pin = box("bt_pin", 3, -5, 19, 4, 4, 6)
    cap = cone("bt_cap", 3, -5, 23, 2.9, 0.0, 2.0, n=4, rot=(0, 0, radians(45)))
    return join("buttress", [foot, slope, pin, cap])


def p_corner_tower():
    parts = [cyl("ct_main", 8, -8, 16, 8, 32, n=16)]
    parts.append(cyl("ct_crown", 8, -8, 31, 9, 2, n=16))  # crown ring z 30..32
    for i in range(12):  # crenel blocks on the rim
        a = math.tau * i / 12.0
        parts.append(box(f"ct_c{i}", 8 + 8.5 * math.cos(a), -8 + 8.5 * math.sin(a),
                         33, 1.2, 2.2, 2.0, rot=(0, 0, a)))
    return join("corner_tower", parts)


def p_stair_run():
    # 8 solid steps, each 8w x 2h rise x 3d tread; lowest step at the front
    # (y=0), ascending +Z while stepping -Y (forward +Z in OBJ space)
    parts = []
    for i in range(8):
        h = 2 * (i + 1)
        parts.append(box(f"st_{i}", 4, -(3 * i + 1.5), h / 2.0, 8, 3, h))
    return join("stair_run", parts)


def p_arch_large():
    # two 4x20x4 columns with a 16 gap (total span 24), front faces y=0
    col_l = box("al_coll", 2, -2, 10, 4, 4, 20)    # x [0,4]
    col_r = box("al_colr", 22, -2, 10, 4, 4, 20)   # x [20,24]
    cap_l = box("al_capl", 2, -2, 20.4, 4.8, 4.8, 0.8)
    cap_r = box("al_capr", 22, -2, 20.4, 4.8, 4.8, 0.8)
    # pointed arch: wedge boxes rotated +/-40 deg about Y, interpenetrating at peak
    w_l = box("al_wl", 8, -2, 23.8, 13, 4, 3.5, rot=(0, radians(-40), 0))
    w_r = box("al_wr", 16, -2, 23.8, 13, 4, 3.5, rot=(0, radians(40), 0))
    return join("arch_large", [col_l, col_r, cap_l, cap_r, w_l, w_r])


def p_gate_frame():
    # gatehouse face 24w x 28h x 6d recessed 1 behind flanking 6x24x6 towers
    slab = box("gf_slab", 12, -4, 14, 24, 6, 28)             # y [-7,-1]
    hole = round_arch(12, -8, 2, 5.0, -0.1, 9.0, segs=8)    # 10w x 14h apex
    bool_diff(slab, hole)
    tow_l = box("gf_towl", 3, -3, 12, 6, 6, 24)             # x [0,6], y [-6,0]
    tow_r = box("gf_towr", 21, -3, 12, 6, 6, 24)            # x [18,24]
    cap_l = box("gf_capl", 3, -3, 24.4, 7, 7, 0.8)
    cap_r = box("gf_capr", 21, -3, 24.4, 7, 7, 0.8)
    # portcullis jamb ring proud of the slab face (slab front at y=-1)
    outer = round_arch(12, -1.6, -0.55, 5.5, -0.2, 9.5, segs=8)
    inner = round_arch(12, -2.0, -0.2, 4.5, -0.7, 8.6, segs=8)
    bool_diff(outer, inner)
    parts = [slab, tow_l, tow_r, cap_l, cap_r, outer]
    # merlon teeth along the slab top edge
    for i in range(6):
        parts.append(box(f"gf_m{i}", 2.0 + 4 * i, -1.75, 29, 2, 1.5, 2))
    return join("gate_frame", parts)


def p_spire_cap():
    # 4 stacked shrinking cylinders (~8h each) + pyramid tip -> 36h
    parts = [
        cyl("sc_1", 6, -6, 4, 6, 8, n=12),    # 12 dia
        cyl("sc_2", 6, -6, 12, 5, 8, n=12),   # 10 dia
        cyl("sc_3", 6, -6, 20, 4, 8, n=12),   # 8 dia
        cyl("sc_4", 6, -6, 28, 2, 8, n=12),   # 4 dia
        cone("sc_tip", 6, -6, 34, 2.4, 0.0, 4, n=8),  # pyramid tip
    ]
    return join("spire_cap", parts)


def p_pillar():
    plinth = box("pl_plinth", 2.5, -2.5, 0.75, 5, 5, 1.5)
    shaft = cyl("pl_shaft", 2.5, -2.5, 9.75, 2, 16.5, n=8)  # 8-gon gothic shaft
    neck = cyl("pl_neck", 2.5, -2.5, 18.2, 2.3, 0.5, n=8)
    capital = box("pl_cap", 2.5, -2.5, 19.25, 5, 5, 1.5)
    return join("pillar", [plinth, shaft, neck, capital])


def p_roof_hip():
    # 16w x 12d footprint, 8 high: bottom quad + ridge (len 4) -> 4 slopes
    b0 = (0, 0, 0); b1 = (16, 0, 0); b2 = (16, -12, 0); b3 = (0, -12, 0)
    r0 = (6, -6, 8); r1 = (10, -6, 8)
    verts = [b0, b1, b2, b3, r0, r1]
    faces = [
        (0, 4, 5, 1),   # front slope (y=0 side)
        (2, 5, 4, 3),   # back slope
        (1, 5, 2),      # +X end triangle
        (3, 4, 0),      # -X end triangle
        (0, 3, 2, 1),   # bottom
    ]
    return mesh_obj("roof_hip", verts, faces)


PIECES = [
    ("wall_plain", p_wall_plain),
    ("wall_window", p_wall_window),
    ("wall_doorway", p_wall_doorway),
    ("merlon_run", p_merlon_run),
    ("buttress", p_buttress),
    ("corner_tower", p_corner_tower),
    ("stair_run", p_stair_run),
    ("arch_large", p_arch_large),
    ("gate_frame", p_gate_frame),
    ("spire_cap", p_spire_cap),
    ("pillar", p_pillar),
    ("roof_hip", p_roof_hip),
]

# ---------------------------------------------------------------- driver

def run():
    clear_scene()
    for name, fn in PIECES:
        try:
            obj = fn()
            nv, nt = finalize(obj)
            assert nv < MAX_VERTS, f"{nv} verts >= {MAX_VERTS}"
            path = os.path.join(OUT_DIR, name + ".obj")
            export_obj(obj, path)
            RESULTS[name] = (nv, nt)
            flag = " *over 800 tris*" if nt > 800 else ""
            print(f"[OK] {name:14s} verts={nv:5d} tris={nt:5d}{flag} -> {path}")
            bpy.data.objects.remove(obj, do_unlink=True)
        except Exception:
            print(f"[FAIL] {name}\n{traceback.format_exc()}")
    print("PIECES: " + repr(RESULTS))
    print(f"DONE {len(RESULTS)}/{len(PIECES)} exported to {OUT_DIR}")


run()
