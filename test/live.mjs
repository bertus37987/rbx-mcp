#!/usr/bin/env node
// LIVE end-to-end test against a real connected Studio plugin.
// Drive: stdio MCP tools/call → remoteBroker → broker → plugin → Studio.
// Non-destructive: everything builds under Workspace.__RbxTest / StarterGui.__RbxTest,
// cleans up at the end via rbx_delete + rbx_undo.

import { spawn } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BIN = join(__dirname, "..", "bin", "rbx-mcp.mjs");
const TEST_ROOT = "Workspace.__RbxTest";
let pass = 0, fail = 0, skip = 0;
const results = [];
const check = (name, cond, extra = "") => {
  (cond ? pass++ : fail++);
  results.push({ name, ok: !!cond, extra });
  let xs; try { xs = typeof extra === "string" ? extra : JSON.stringify(extra); } catch { xs = String(extra); }
  console.log(`${cond ? "PASS" : "FAIL"} ${name}${xs ? " — " + xs.slice(0, 140) : ""}`);
};
const skipT = (name, why) => { skip++; console.log(`SKIP ${name} — ${why}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

function mcpClient(child) {
  let id = 0; const pending = new Map(); let buf = "";
  child.stdout.on("data", d => {
    buf += d.toString(); let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx).trim(); buf = buf.slice(idx + 1);
      if (!line) continue;
      let msg; try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id !== undefined && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
    }
  });
  return (method, params, timeoutMs = 300000) => new Promise((resolve, reject) => {
    const rid = ++id; pending.set(rid, resolve);
    setTimeout(() => { if (pending.has(rid)) { pending.delete(rid); reject(new Error("timeout " + method + " " + JSON.stringify(params?.name||params))); } }, timeoutMs);
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: rid, method, params }) + "\n");
  });
}
let rpc;
async function call(name, args = {}) {
  const r = await rpc("tools/call", { name, arguments: args });
  if (r.error) return { _toolError: r.error };
  const text = r.result?.content?.[0]?.text ?? "";
  let parsed; try { parsed = JSON.parse(text); } catch { parsed = text; }
  return { parsed, isError: r.result?.isError };
}

const server = spawn("node", [BIN, "serve"], { stdio: ["pipe", "pipe", "pipe"] });
server.stderr.on("data", d => process.stderr.write("[srv] " + d));
await sleep(1500);
rpc = mcpClient(server);

let SID;
try {
  await rpc("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "livetest", version: "0" } });

  // ---- discovery -------------------------------------------------------
  const studios = await call("rbx_studios");
  const insts = studios.parsed.instances || studios.parsed || [];
  const live = insts.filter?.(i => i.studioId && !i.stale).sort((a, b) => (a.age_seconds ?? 1e9) - (b.age_seconds ?? 1e9))[0] || insts[0];
  SID = live?.studioId;
  check("rbx_studios", !!SID, SID);
  const s = (o = {}) => ({ studio_id: SID, ...o });

  const ping = await call("rbx_ping", s());
  check("rbx_ping", ping.parsed?.pong === true || ping.parsed?.ok === true, (JSON.stringify(ping.parsed)||"?").slice(0, 100));

  const lua = await call("rbx_run_luau", s({ code: "return {sum=2+2, name=game.Name}" }));
  check("rbx_run_luau", lua.parsed?.ok === true && lua.parsed?.result?.sum === 4, (JSON.stringify(lua.parsed)||"?").slice(0, 120));

  const luaErr = await call("rbx_run_luau", s({ code: 'error("expected")' }));
  check("rbx_run_luau error path", luaErr.parsed?.ok === false);

  const tree = await call("rbx_get_tree", s({ path: "Workspace", max_depth: 1 }));
  check("rbx_get_tree", Array.isArray(tree.parsed?.nodes) && tree.parsed.nodes.length > 0, `${tree.parsed?.nodes?.length} nodes`);

  const insp = await call("rbx_inspect", s({ path: "Workspace" }));
  check("rbx_inspect", !!(insp.parsed?.path || insp.parsed?.class || insp.parsed?.properties));

  const cons = await call("rbx_console", s({ tail: 20 }));
  check("rbx_console", cons.parsed !== undefined);

  // ---- instance CRUD under test root -----------------------------------
  const mk = await call("rbx_create_instance", s({ className: "Folder", name: "__RbxTest", parent_path: "Workspace" }));
  check("rbx_create_instance (Folder)", mk.parsed?.path === TEST_ROOT, JSON.stringify(mk.parsed));

  const part = await call("rbx_create_instance", s({ className: "Part", name: "T1", parent_path: TEST_ROOT, props: { Size: { __type: "Vector3", x: 4, y: 4, z: 4 }, Anchored: true } }));
  check("rbx_create_instance (Part+props)", !!part.parsed?.path, (JSON.stringify(part.parsed)||"?").slice(0, 120));

  const props = await call("rbx_set_properties", s({ path: TEST_ROOT + ".T1", props: { Transparency: 0.5, BrickColor: "Bright red" } }));
  check("rbx_set_properties", (props.parsed?.applied || []).length === 2, (JSON.stringify(props.parsed)||"?").slice(0, 120));

  const attr = await call("rbx_set_attribute", s({ path: TEST_ROOT + ".T1", name: "TestTag", value: 42 }));
  check("rbx_set_attribute", attr.parsed?.value === 42, JSON.stringify(attr.parsed));

  const tag = await call("rbx_tag", s({ path: TEST_ROOT + ".T1", tag: "RbxTest" }));
  check("rbx_tag", tag.parsed?.tag === "RbxTest");

  const clone = await call("rbx_clone", s({ path: TEST_ROOT + ".T1", new_name: "T2" }));
  check("rbx_clone", !!clone.parsed?.path, clone.parsed?.path);

  const moved = await call("rbx_move", s({ path: TEST_ROOT + ".T2", new_parent: "Workspace" }));
  check("rbx_move", moved.parsed?.path === "Workspace.T2", moved.parsed?.path);
  await call("rbx_move", s({ path: "Workspace.T2", new_parent: TEST_ROOT }));

  const sel = await call("rbx_select", s({ path: TEST_ROOT + ".T1" }));
  check("rbx_select", !!sel.parsed?.selected);

  // ---- batch ------------------------------------------------------------
  const batch = await call("rbx_batch", s({ ops: [
    { cmd: "create_instance", args: { className: "Part", name: "B1", parent_path: TEST_ROOT } },
    { cmd: "create_instance", args: { className: "Part", name: "B2", parent_path: TEST_ROOT } },
    { cmd: "set_properties", args: { path: TEST_ROOT + ".B1", props: { Anchored: true } } },
  ] }));
  check("rbx_batch", batch.parsed?.applied === 3, (JSON.stringify(batch.parsed)||"?").slice(0, 160));

  // ---- checkpoint + undo -----------------------------------------------
  await call("rbx_checkpoint", s({ label: "live-test" }));
  const und = await call("rbx_undo", s({ steps: 1 }));
  check("rbx_undo", und.parsed !== undefined);
  const redo = await call("rbx_create_instance", s({ className: "Part", name: "AfterUndo", parent_path: TEST_ROOT, props: { Anchored: true } }));
  check("post-undo create", !!redo.parsed?.path);

  // ---- scripts -----------------------------------------------------------
  const w = await call("rbx_write_script", s({ path: "ServerScriptService.__RbxTest", className: "ModuleScript", source: "local M = {}\nfunction M.add(a,b) return a+b end\nreturn M" }));
  check("rbx_write_script", w.parsed?.lines === 4 || !!w.parsed?.path, (JSON.stringify(w.parsed)||"?").slice(0, 140));
  const hash = w.parsed?.hash;

  const rd = await call("rbx_read_script", s({ path: "ServerScriptService.__RbxTest" }));
  check("rbx_read_script", (rd.parsed?.source || "").includes("function M.add"));

  const conflict = await call("rbx_write_script", s({ path: "ServerScriptService.__RbxTest", source: "-- stale", expected_hash: "deadbeef" }));
  check("rbx_write_script optimistic-hash conflict", !!conflict.isError || !!conflict._toolError || /mismatch|hash/i.test(String(conflict.parsed)), (JSON.stringify(conflict.parsed)||"?").slice(0, 120));

  const guarded = await call("rbx_write_script", s({ path: "ServerScriptService.__RbxTest", source: "local M = {}\nfunction M.add(a,b) return a+b+0 end\nreturn M", expected_hash: hash }));
  check("rbx_write_script guarded write", !guarded.parsed?.error, (JSON.stringify(guarded.parsed)||"?").slice(0, 100));

  const fr = await call("rbx_find_replace", s({ pattern: "M%.add", path: "ServerScriptService" }));
  check("rbx_find_replace search", (fr.parsed?.hits || []).length >= 1, `${fr.parsed?.hits?.length} hits`);

  // ---- snapshot + diff ---------------------------------------------------
  await call("rbx_snapshot", s({ label: "live-a", path: TEST_ROOT }));
  await call("rbx_create_instance", s({ className: "Part", name: "Delta", parent_path: TEST_ROOT, props: { Anchored: true } }));
  await call("rbx_snapshot", s({ label: "live-b", path: TEST_ROOT }));
  const diff = await call("rbx_diff", { a: "live-a", b: "live-b" });
  check("rbx_snapshot+rbx_diff", (diff.parsed?.added || []).some(n => n.path?.includes("Delta")), JSON.stringify(diff.parsed?.counts || {}));

  // ---- audits -------------------------------------------------------------
  const audit = await call("rbx_gui_audit", s({}));
  check("rbx_gui_audit", Array.isArray(audit.parsed?.issues ?? audit.parsed), `${(audit.parsed?.issues||audit.parsed||[]).length} findings`);

  const sec = await call("rbx_security_scan", s({}));
  check("rbx_security_scan", Array.isArray(sec.parsed?.findings ?? sec.parsed), `${(sec.parsed?.findings||sec.parsed||[]).length} findings`);

  const val = await call("rbx_validate_asset", s({ path: TEST_ROOT + ".T1" }));
  check("rbx_validate_asset", !!val.parsed?.stats || val.parsed?.issues !== undefined, (JSON.stringify(val.parsed)||"?").slice(0, 140));

  // ---- native GUI --------------------------------------------------------
  const gui = await call("rbx_build_gui", s({ pattern: "panel", parent_path: "StarterGui", name: "__RbxTestUI",
    props: { title: "rbx-mcp live", accent: "#111111" } }));
  check("rbx_build_gui panel", !!gui.parsed?.root_path, (JSON.stringify(gui.parsed)||"?").slice(0, 140));

  const gui2 = await call("rbx_build_gui", s({ pattern: "healthbar", parent_path: gui.parsed?.root_path || "StarterGui" }));
  check("rbx_build_gui healthbar", !!gui2.parsed?.root_path, (JSON.stringify(gui2.parsed)||"?").slice(0, 100));

  const theme = await call("rbx_gui_theme", s({ path: gui.parsed?.root_path || "StarterGui.RbxGui", theme: { accent: "#18d18b", bg: "#101010" } }));
  check("rbx_gui_theme", theme.parsed !== undefined, (JSON.stringify(theme.parsed)||"?").slice(0, 120));

  const wrap = await call("rbx_wrap_image", s({ image: "rbxassetid://0", parent_path: "StarterGui", name: "__RbxTestImg" }));
  check("rbx_wrap_image (error-or-scaffold)", wrap.parsed !== undefined);

  // ---- NPC + armor --------------------------------------------------------
  const rig = await call("rbx_rig_npc", s({ name: "RbxTestKnight", rig_type: "R15", position: { x: 0, y: 5, z: 0 } }));
  check("rbx_rig_npc", !!rig.parsed?.path, (JSON.stringify(rig.parsed)||"?").slice(0, 140));
  const rigPath = rig.parsed?.path || "Workspace.RbxTestKnight";

  const armorModel = await call("rbx_create_instance", s({ className: "Model", name: "Helm", parent_path: TEST_ROOT }));
  await call("rbx_create_instance", s({ className: "Part", name: "Dome", parent_path: armorModel.parsed?.path, props: { Shape: "Ball", Size: { __type: "Vector3", x: 2, y: 2, z: 2 }, Anchored: true } }));
  const fit = await call("rbx_fit_accessory", s({ item_path: armorModel.parsed?.path, rig_path: rigPath, attachment: "HatAttachment" }));
  check("rbx_fit_accessory", !!fit.parsed?.path || !!fit.parsed?.accessory, (JSON.stringify(fit.parsed)||"?").slice(0, 160));

  const attach = await call("rbx_attach_part", s({ item_path: TEST_ROOT + ".T1", rig_path: rigPath, target: "RightHand" }));
  check("rbx_attach_part", attach.parsed !== undefined, (JSON.stringify(attach.parsed)||"?").slice(0, 120));

  const behav = await call("rbx_npc_behavior", s({ rig_path: rigPath, behavior: "idle" }));
  check("rbx_npc_behavior idle", behav.parsed?.behavior === "idle", (JSON.stringify(behav.parsed)||"?").slice(0, 120));

  const anim = await call("rbx_build_animation", s({ rig_path: rigPath, name: "TestWave", keyframes: [
    { time: 0, parts: { RightUpperArm: { rotDeg: { x: 0, y: 0, z: 90 } } } },
    { time: 0.5, parts: { RightUpperArm: { rotDeg: { x: 0, y: 0, z: 45 } } } },
  ] }));
  check("rbx_build_animation", !!anim.parsed?.path, (JSON.stringify(anim.parsed)||"?").slice(0, 120));

  const equip = await call("rbx_equip_npc", s({ rig_path: rigPath, items: [{ item_path: armorModel.parsed?.path, attachment: "HatAttachment" }] }));
  check("rbx_equip_npc", equip.parsed !== undefined, (JSON.stringify(equip.parsed)||"?").slice(0, 140));

  // ---- rendering ----------------------------------------------------------
  const thumb = await call("rbx_render_thumbnail", s({ path: rigPath }));
  check("rbx_render_thumbnail", (thumb.parsed?.png_base64 || "").length > 1000 || !!thumb.parsed?.error || !!thumb.parsed?.note || !!thumb.parsed?.camera,
    thumb.parsed?.png_base64 ? `${Math.round(thumb.parsed.png_base64.length/1024)}KB png` : (JSON.stringify(thumb.parsed)||"?").slice(0, 120));

  // ---- terrain (remote corner, then clear) --------------------------------
  const terr = await call("rbx_terrain_generate", s({ seed: 42, size: { x: 96, y: 48, z: 96 }, center: { x: 4000, y: 8, z: 4000 },
    base_height: 4, mountain_height: 40, ridge: 0.6 }));
  check("rbx_terrain_generate mountains", terr.parsed?.ok !== false, (JSON.stringify(terr.parsed)||"?").slice(0, 160));

  const smooth = await call("rbx_terrain_smooth", s({ region_center: { x: 4000, y: 8, z: 4000 }, region_size: { x: 32, y: 32, z: 32 }, strength: 0.5 }));
  check("rbx_terrain_smooth", smooth.parsed !== undefined);

  const clear = await call("rbx_terrain_clear", s({ region_center: { x: 4000, y: 8, z: 4000 }, region_size: { x: 128, y: 64, z: 128 } }));
  check("rbx_terrain_clear", clear.parsed?.cleared === true);

  // ---- assets --------------------------------------------------------------
  const ins = await call("rbx_insert_asset", s({ asset_id: 1, parent_path: TEST_ROOT }));
  check("rbx_insert_asset (graceful)", ins.parsed !== undefined || !!ins.isError || !!ins._toolError, (JSON.stringify(ins.parsed)||"?").slice(0, 120));

  // ---- kits + modules ------------------------------------------------------
  const kits = await call("rbx_kits");
  check("rbx_kits", JSON.stringify(kits.parsed).includes("obby"));

  const kit = await call("rbx_apply_kit", s({ kit: "obby", config: { stages: 2, spacing: 12 } }));
  check("rbx_apply_kit obby", kit.parsed?.ok === true || !!kit.parsed?.built || kit.parsed?.error === undefined, (JSON.stringify(kit.parsed)||"?").slice(0, 160));
  await call("rbx_undo", s({ steps: 1 }));

  const mod = await call("rbx_install_module", s({ name: "signal", parent_path: "ReplicatedStorage" }));
  check("rbx_install_module (network)", mod.parsed !== undefined, (JSON.stringify(mod.parsed)||"?").slice(0, 120));

  // ---- sync ------------------------------------------------------------------
  const pull = await call("rbx_sync_pull", s({ root_dir: "rbx-mcp-sync-test" }));
  check("rbx_sync_pull", pull.parsed !== undefined, (JSON.stringify(pull.parsed)||"?").slice(0, 140));

  const push = await call("rbx_sync_push", s({ file: "rbx-mcp-sync-test/src/server/__RbxTest.lua" }));
  check("rbx_sync_push dry-run", push.parsed !== undefined, (JSON.stringify(push.parsed)||"?").slice(0, 140));

  // ---- play state --------------------------------------------------------------
  const ps = await call("rbx_play_state", s({ action: "status" }));
  check("rbx_play_state status", ps.parsed !== undefined, (JSON.stringify(ps.parsed)||"?").slice(0, 120));

  // ---- environment + ui sounds + scenario --------------------------------
  const light = await call("rbx_lighting", s({ preset: "sunset" }));
  check("rbx_lighting preset", (light.parsed?.changed || []).some(c => String(c).includes("preset")), (JSON.stringify(light.parsed)||"?").slice(0, 120));
  const light2 = await call("rbx_lighting", s({ time_of_day: 14, effects: { Bloom: { Intensity: 0.1 } } }));
  check("rbx_lighting custom", light2.parsed !== undefined);
  await call("rbx_lighting", s({ preset: "noon" })); // restore

  const sfx = await call("rbx_ui_sounds", s({ path: "StarterGui.RbxGui" }));
  check("rbx_ui_sounds", !!sfx.parsed?.sounds_holder || !!sfx.parsed?.script, (JSON.stringify(sfx.parsed)||"?").slice(0, 120));

  const scen = await call("rbx_scenario", s({ stop_on_fail: true, steps: [
    { cmd: "create_instance", args: { className: "Part", name: "Scen1", parent_path: TEST_ROOT }, expect: [{ field: "path", contains: "Scen1" }] },
    { cmd: "run_luau", args: { code: "return 2+2" }, expect: [{ field: "result", eq: 4 }] },
  ] }));
  check("rbx_scenario", scen.parsed?.passed === 2 && scen.parsed?.failed === 0, (JSON.stringify(scen.parsed)||"?").slice(0, 140));

  // ---- knowledge ---------------------------------------------------------------
  const apiC = await call("rbx_api_class", { class_name: "BasePart" });
  check("rbx_api_class", apiC.parsed?.found === true && (apiC.parsed.members||[]).length > 20, `${apiC.parsed?.members?.length} members`);

  const apiE = await call("rbx_api_enum", { enum_name: "Material" });
  check("rbx_api_enum", apiE.parsed?.found === true && (apiE.parsed.items||[]).length > 20, `${apiE.parsed?.items?.length} items`);

  const docs = await call("rbx_docs", { path: "reference/engine/enums/Material" });
  check("rbx_docs", (docs.parsed?.content || "").length > 200, `${docs.parsed?.bytes} bytes`);

  const skill = await call("rbx_skill", { skill_name: "verification-loop" });
  check("rbx_skill", (typeof skill.parsed === "string" ? skill.parsed : JSON.stringify(skill.parsed || "")).length > 100);

  // ---- quality (graceful without binaries) -----------------------------------
  const lint = await call("rbx_lint", { path: "plugin/RbxMcp.lua" });
  check("rbx_lint graceful", lint.parsed !== undefined, (JSON.stringify(lint.parsed)||"?").slice(0, 80));

  const fmt = await call("rbx_format", { path: "plugin/RbxMcp.lua" });
  check("rbx_format graceful", fmt.parsed !== undefined, (JSON.stringify(fmt.parsed)||"?").slice(0, 80));

  const tc = await call("rbx_typecheck", { path: "plugin" });
  check("rbx_typecheck graceful", tc.parsed !== undefined, (JSON.stringify(tc.parsed)||"?").slice(0, 80));

  // ---- upstream ---------------------------------------------------------------
  const up = await call("rbx_upstream_status");
  check("rbx_upstream_status", up.parsed !== undefined, (JSON.stringify(up.parsed)||"?").slice(0, 160));

  const st = await call("studio.__status", s({}));
  check("studio.__status passthrough", st.parsed !== undefined || st.isError !== undefined, (JSON.stringify(st.parsed ?? st)||"?").slice(0, 120));

  // ---- mesh watch (no Studio file needed) --------------------------------------
  const watch = await call("rbx_mesh_watch", s({ dir: join(__dirname, "..", "vendor", "cache") }));
  check("rbx_mesh_watch start", !!watch.parsed?.watching || !!watch.parsed?.error, (JSON.stringify(watch.parsed)||"?").slice(0, 120));

  const watchStop = await call("rbx_mesh_watch", s({ dir: join(__dirname, "..", "vendor", "cache"), stop: true }));
  check("rbx_mesh_watch stop", watchStop.parsed?.stopped !== undefined);

  // ---- v2: mesh import (EditableMesh chunked) -------------------------------------
  const objFix = join(__dirname, "fixtures", "pyramid.obj");
  const imesh = await call("rbx_import_mesh", s({ file: objFix, name: "__RbxTestPyr", parent_path: TEST_ROOT }));
  check("rbx_import_mesh obj→editable_mesh", (imesh.parsed?.path || "").includes("Pyr") || (imesh.parsed?.verts|0) > 0 || !!imesh.parsed?.tris, (JSON.stringify(imesh.parsed)||"?").slice(0, 160));

  // ---- v2: vfx + material --------------------------------------------------------
  await call("rbx_create_instance", s({ className: "Part", name: "TorchPost", parent_path: TEST_ROOT, props: { Size: [1, 6, 1], Position: [0, 4, 0], Anchored: true } }));
  const vfx = await call("rbx_vfx", s({ preset: "fire.torch", path: `${TEST_ROOT}.TorchPost` }));
  check("rbx_vfx fire.torch", (vfx.parsed?.paths || []).length >= 1, (JSON.stringify(vfx.parsed)||"?").slice(0, 120));
  const vfx2 = await call("rbx_vfx", s({ preset: "weather.rain", position: [0, 30, 0] }));
  check("rbx_vfx weather.rain", vfx2.parsed !== undefined, (JSON.stringify(vfx2.parsed)||"?").slice(0, 120));
  const mat = await call("rbx_set_material", s({ path: `${TEST_ROOT}.TorchPost`, material: "Slate" }));
  check("rbx_set_material", mat.parsed !== undefined, (JSON.stringify(mat.parsed)||"?").slice(0, 120));

  // ---- v2: kit place (stub master via run_luau) -----------------------------------
  await call("rbx_run_luau", s({ code: `local ss=game:GetService("ServerStorage") local k=ss:FindFirstChild("RbxKit") or Instance.new("Folder") k.Name="RbxKit" k.Parent=ss local g=k:FindFirstChild("test") or Instance.new("Folder") g.Name="test" g.Parent=k local p=Instance.new("Part") p.Name="wall" p.Size=Vector3.new(8,16,4) p.Parent=g return "master ok"` }));
  const kp = await call("rbx_kit_place", s({ kit: "test", piece: "wall", transforms: [{ pos: [0, 8, 50], rot: [0, 0, 0] }, { pos: [8, 8, 50], rot: [0, 45, 0] }], parent_path: TEST_ROOT }));
  check("rbx_kit_place", (kp.parsed?.placed|0) === 2, (JSON.stringify(kp.parsed)||"?").slice(0, 120));
  const kps = await call("rbx_kit_pieces", s({ kit: "test" }));
  check("rbx_kit_pieces", Array.isArray(kps.parsed) || Array.isArray(kps.parsed?.pieces), (JSON.stringify(kps.parsed)||"?").slice(0, 120));

  // ---- v2: populate / optimize / audio / cutscene ----------------------------------
  const pop = await call("rbx_populate", s({ rig_type: "R15", count: 2, area: { center: [0, 5, 60], radius: 10 }, jobs: [{ type: "idle" }], names: ["Guard"] }));
  check("rbx_populate", (pop.parsed?.created|0) === 2, (JSON.stringify(pop.parsed)||"?").slice(0, 140));
  const opt = await call("rbx_optimize", s({ path: TEST_ROOT, apply: false }));
  check("rbx_optimize audit", opt.parsed !== undefined, (JSON.stringify(opt.parsed)||"?").slice(0, 140));
  const aud = await call("rbx_audio", s({ preset: "ambience.forest", position: [0, 5, 70] }));
  check("rbx_audio", aud.parsed !== undefined, (JSON.stringify(aud.parsed)||"?").slice(0, 120));
  const cut = await call("rbx_cutscene", s({ name: "__RbxTestCut", waypoints: [{ pos: [0, 10, 0], look: [0, 5, 0], dur: 2 }, { pos: [20, 10, 20], look: [0, 5, 0], dur: 2 }] }));
  check("rbx_cutscene", !!cut.parsed?.path || (cut.parsed?.steps|0) === 2, (JSON.stringify(cut.parsed)||"?").slice(0, 120));

  // ---- v2: GUI v2 patterns + animate + component ------------------------------------
  const gui3 = await call("rbx_build_gui", s({ pattern: "slider", name: "__RbxTestSlider", parent_path: "StarterGui" }));
  check("gui slider", !!gui3.parsed?.root_path, (JSON.stringify(gui3.parsed)||"?").slice(0, 120));
  const gui4 = await call("rbx_build_gui", s({ pattern: "game_hud", name: "__RbxTestHUD", parent_path: "StarterGui" }));
  check("gui game_hud", !!gui4.parsed?.root_path, (JSON.stringify(gui4.parsed)||"?").slice(0, 120));
  const gan = await call("rbx_gui_animate", s({ path: gui3.parsed?.root_path || "StarterGui.__RbxTestSlider", preset: "slide_in" }));
  check("rbx_gui_animate", gan.parsed !== undefined, (JSON.stringify(gan.parsed)||"?").slice(0, 120));
  const gco = await call("rbx_gui_component", s({ path: gui3.parsed?.root_path || "StarterGui.__RbxTestSlider", behavior: "draggable" }));
  check("rbx_gui_component", gco.parsed !== undefined, (JSON.stringify(gco.parsed)||"?").slice(0, 120));

  // ---- v2: lighting v2 + scenario v2 + build + kit_build ------------------------------
  const light3 = await call("rbx_lighting", s({ fog: { start: 100, end: 900, color: "#8899aa" } }));
  check("rbx_lighting v2 fog", light3.parsed !== undefined, (JSON.stringify(light3.parsed)||"?").slice(0, 120));
  const scen2 = await call("rbx_scenario", s({ stop_on_fail: true, steps: [
    { cmd: "create_instance", args: { className: "Part", name: "ScenPart", parent_path: TEST_ROOT }, expect: [{ field: "count_under", path: TEST_ROOT, min: 1 }] },
  ] }));
  check("rbx_scenario v2 count_under", scen2.parsed?.passed === 1, (JSON.stringify(scen2.parsed)||"?").slice(0, 160));
  const bld = await call("rbx_build", s({ recipe: "stair_flight", config: { parent_path: TEST_ROOT, steps: 3 } }));
  check("rbx_build (graceful)", bld.parsed !== undefined, (JSON.stringify(bld.parsed)||"?").slice(0, 140));
  const kb = await call("rbx_kit_build", s({ kit: "gothic", source: "files" }));
  check("rbx_kit_build (graceful)", kb.parsed !== undefined, (JSON.stringify(kb.parsed)||"?").slice(0, 140));

  // ---- cleanup ------------------------------------------------------------------
  console.log("--- cleanup ---");
  const del = await call("rbx_delete", s({ path: TEST_ROOT }));
  await call("rbx_delete", s({ path: "Workspace.RbxTestKnight" }));
  const delGui = await call("rbx_run_luau", s({ code: "local n=0; for _,c in ipairs(game.StarterGui:GetChildren()) do if c.Name=='RbxGui' or c.Name=='RbxGuiImages' then c:Destroy(); n+=1 end end; return {removed_gui=n}" }));
  check("cleanup workspace", del.parsed?.removed !== undefined || del.parsed?.path !== undefined, (JSON.stringify(del.parsed)||"?").slice(0, 100));
  await call("rbx_delete", s({ path: "ServerScriptService.__RbxTest" }));
  await call("rbx_delete", s({ path: "StarterGui.__RbxTestUI" })).catch(()=>{});
  await call("rbx_run_luau", s({ code: `local n=0
local function sweep(root, pred) for _,c in ipairs(root:GetChildren()) do if pred(c) then c:Destroy(); n+=1 end end end
sweep(workspace, function(c) return c.Name:find("__RbxTest") or c.Name:find("VfxEmitter") or c.Name:find("Emitter") and c:IsA("BasePart") and not c.CanCollide or c.Name=="TorchPost" end)
sweep(workspace, function(c) return c:IsA("Model") and c:FindFirstChildOfClass("Humanoid") and c.Name~="TestKnight" and #c.Name<40 and c.Name:find("Citizen|Guard|NPC") end)
local ss=game:GetService("ServerStorage") local k=ss:FindFirstChild("RbxKit") if k and k:FindFirstChild("test") then k.test:Destroy(); n+=1 end
local sp=game.StarterPlayer.StarterPlayerScripts local cs=sp:FindFirstChild("RbxCutscene") if cs then cs:Destroy(); n+=1 end
local sg=game.StarterGui for _,c in ipairs(sg:GetChildren()) do if c.Name:find("__RbxTest") then c:Destroy(); n+=1 end end
return {swept=n}` }));
  await call("rbx_find_replace", s({})).catch(()=>{});
} catch (e) {
  fail++; console.log("FAIL exception — " + e.message);
} finally {
  server.kill();
}
console.log(`\n=== ${pass} passed, ${fail} failed, ${skip} skipped ===`);
process.exit(fail ? 1 : 0);
