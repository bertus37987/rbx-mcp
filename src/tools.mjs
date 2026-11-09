#!/usr/bin/env node
// Tool registry. Descriptions are deliberately dense: usage rules, output
// contracts and failure semantics live INSIDE the schema descriptions — that
// embedded documentation is what makes agents use the tools correctly.

const S = { type: "string", description: "Connected Studio instance id — get values from rbx_studios." };

const COMMON = {
  studio_id: S,
};

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { parseObjFile, chunkMesh } from "./mesh.mjs";

function pluginTool(name, description, inputSchema, extraProps = {}) {
  return {
    name,
    description,
    inputSchema: { type: "object", properties: { ...COMMON, ...(inputSchema.properties || {}) }, required: ["studio_id", ...(inputSchema.required || [])] },
    annotations: { title: name.replace(/^rbx_/, "").replace(/_/g, " "), ...extraProps },
    plugin: inputSchema.__cmd || name.replace(/^rbx_/, ""),
    timeoutMs: inputSchema.__timeoutMs || 90000,
  };
}

export function buildTools({ broker, router, local }) {
  const P = (t) => ({
    ...t,
    handler: async (a) => {
      const { studio_id, ...args } = a;
      const payload = await broker.enqueue(studio_id, t.plugin, args, t.timeoutMs);
      return payload;
    },
  });

  // Stream a parsed OBJ through the plugin's `editable_mesh` cmd: vert chunks
  // (≤250) first, then face chunks (≤350) — faces keep GLOBAL 1-based indices,
  // the plugin accumulates. done=true on the last call → plugin builds the
  // MeshPart and returns {path,...}. Each call is its own lease, so a 100k-vert
  // import never dies mid-command (rbx-mcp GOAL A).
  async function streamEditableMesh(studioId, mesh, { name, parent_path = "Workspace", with_texture } = {}) {
    const { vertChunks, faceChunks } = chunkMesh(mesh);
    let batch = 0, res = null;
    for (const c of vertChunks) {
      res = await broker.enqueue(studioId, "editable_mesh", {
        name, parent_path, verts: c.verts, uvs: c.uvs, vbase: c.base, batch: batch++, done: false,
      }, 90000);
    }
    if (!faceChunks.length) faceChunks.push([]);
    for (const f of faceChunks) {
      const last = batch === vertChunks.length + faceChunks.length - 1;
      res = await broker.enqueue(studioId, "editable_mesh", {
        name, parent_path, faces: f, batch: batch++, done: last,
        with_texture: last ? with_texture : undefined,
      }, 90000);
    }
    return { ...(res && typeof res === "object" ? res : { result: res }), verts: mesh.verts.length, tris: mesh.faces.length, batches: batch };
  }

  const tools = [
    // ---------------------------------------------------------------- core
    {
      name: "rbx_studios",
      description: "List connected Roblox Studio instances (place name, plugin version, capabilities). Call first; pass returned studioId as studio_id on every other call.",
      inputSchema: { type: "object", properties: {} },
      annotations: { title: "studios", readOnlyHint: true, idempotentHint: true },
      handler: async () => {
        const st = await broker.state();
        const now = st.now || Date.now();
        return {
          instances: (st.instances || []).map(i => ({
            ...i,
            age_seconds: Math.round((now - (i.lastSeen || now)) / 1000),
            stale: now - (i.lastSeen || now) > 60000,
          })),
          hint: "Pass the studioId with the lowest age_seconds — entries >60s stale are dead plugin registrations.",
        };
      },
    },
    P(pluginTool("rbx_ping", "Verify the Studio plugin bridge is alive. Returns place + plugin version.", { properties: {} }, { readOnlyHint: true, idempotentHint: true })),
    P(pluginTool("rbx_run_luau", "Execute Luau code in Studio's edit-time environment (plugin security context). Returns {ok, result, ms}.\n\nFreezing rules — Studio runs on one thread: for bulk creation/edits split into chunks (~1000 items), call task.wait() once per chunk, and parent each chunk's container before the wait. A single large .Parent write scales with total subtree size and can freeze Studio or drop the bridge. Loops waiting for state must contain task.wait().\n\nThe result value is serialized: Instances→{path,class}, Vector3/CFrame/Color3→tagged tables. Returns are captured via `return <expr>` at the end of the code.", {
      properties: { code: { type: "string", description: "Luau source. Top-level `return` gives the result." } },
      required: ["code"],
      __timeoutMs: 120000,
    }, { destructiveHint: true })),
    P(pluginTool("rbx_get_tree", "Serialize the DataModel tree from `path` (default game root). Output: flat array of {name, className, path, childCount, unexplored?}. Depth default 3, max 10; beyond limit children collapse into counts — paginate by descending path. Filters: instance_type uses IsA() (case-sensitive, e.g. 'GuiObject'), keywords is case-insensitive comma list matching names.", {
      properties: {
        path: { type: "string" }, max_depth: { type: "number" }, head_limit: { type: "number", description: "Max rows, default 200" },
        instance_type: { type: "string" }, keywords: { type: "string" },
      },
    }, { readOnlyHint: true })),
    P(pluginTool("rbx_inspect", "Full property dump of one instance (scriptable props, attributes, tags). Use after rbx_get_tree for detail. Pass path like 'Workspace.MyPart'.", {
      properties: { path: { type: "string" } }, required: ["path"],
    }, { readOnlyHint: true })),
    P(pluginTool("rbx_console", "Read Studio output log entries [{message, type, time}] newest last. Filter: level 'Error'|'Warning'|'Print'|all, tail N (default 100).", {
      properties: { level: { type: "string" }, tail: { type: "number" } },
    }, { readOnlyHint: true })),

    // ------------------------------------------------------- edit & safety
    P(pluginTool("rbx_read_script", "Read a LuaSourceContainer's source. path e.g. 'ServerScriptService.Main'.", {
      properties: { path: { type: "string" } }, required: ["path"],
    }, { readOnlyHint: true })),
    P(pluginTool("rbx_write_script", "Replace a script's full source (atomic; creates the script if missing when className given). A ChangeHistoryService waypoint is recorded first — user can undo via Studio Edit>Undo. For new scripts pass className 'Script'|'LocalScript'|'ModuleScript' and source; for existing scripts only path+source. Returns {path, lines} + integrity hash for later rbx_write_script(expected_hash) guarded edits.", {
      properties: {
        path: { type: "string" }, className: { type: "string" }, source: { type: "string" },
        expected_hash: { type: "string", description: "Optimistic-lock guard: edit fails if current source hash differs (script changed since last read)" },
      },
      required: ["path", "source"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_create_instance", "Create Instance.new(className) at parent_path with props. props uses exact Roblox property names; invalid props are reported individually (never silently dropped). Returns created path.", {
      properties: {
        className: { type: "string" }, parent_path: { type: "string" }, name: { type: "string" },
        props: { type: "object", description: "Property map. Vector3/CFrame/Color3/UDim2/BrickColor/Enum accepted as tagged tables, e.g. {Size={x=1,y=2,z=3}} or {CFrame={pos={...},rotDeg={...}}}" },
      },
      required: ["className", "parent_path"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_set_properties", "Set multiple properties on one instance atomically (waypoint first). props = exact property names. Per-property errors are collected, not thrown. Returns {applied:[], failed:[{prop,error}]}.", {
      properties: { path: { type: "string" }, props: { type: "object" } }, required: ["path", "props"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_delete", "Destroy an instance (waypoint first). Returns removed path.", {
      properties: { path: { type: "string" } }, required: ["path"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_checkpoint", "Record a labeled ChangeHistoryService waypoint. Run BEFORE risky batch edits — checkpoint + rbx_undo restore the pre-state.", {
      properties: { label: { type: "string" } }, required: ["label"],
    })),
    P(pluginTool("rbx_undo", "Trigger Studio Undo (ChangeHistoryService). N steps (default 1). Reverts the most recent waypoints — use after failed batch ops.", {
      properties: { steps: { type: "number" } },
    }, { destructiveHint: true })),
    {
      ...pluginTool("rbx_snapshot", "Capture a structural snapshot of the DataModel subtree (paths + key props + script hashes). Server stores it under `label`; rbx_diff compares two snapshots — the proof a change did what it should. Options: path (default game), include_source_hashes (default true).", {
        properties: { path: { type: "string" }, include_source_hashes: { type: "boolean" }, label: { type: "string", description: "Required. Name the snapshot stores under — use semantic names like 'before-armor' / 'after-armor'" } },
        required: ["label"],
        __timeoutMs: 120000,
      }, { readOnlyHint: true }),
      handler: async (a) => {
        const { studio_id, label, ...args } = a;
        const payload = await broker.enqueue(studio_id, "snapshot", args, 120000);
        const file = local.saveSnapshot(label, payload);
        return { label, stored: file, nodes: (payload.nodes || []).length };
      },
    },

    // ------------------------------------------------------------- verify
    P(pluginTool("rbx_gui_audit", "Audit all ScreenGuis in StarterGui/PlayerGui for agent-classic mistakes: UDim2 offset pixels instead of scale (not resolution-safe), missing UICorner where sibling frames have it, TextScaled=false on small text, missing AspectRatioConstraint on sized ImageLabels, anchors not set for bottom/right elements, IgnoreGuiInset conflicts. Returns [{path, issue, severity, fix}] ordered by severity.", { properties: {} }, { readOnlyHint: true })),
    P(pluginTool("rbx_security_scan", "Scan every LuaSourceContainer for backdoor/malware patterns: require(<numeric assetid>), loadstring/getfenv/setfenv, HttpGet/PostAsync to non-roblox hosts, base64 blobs, nil-parented scripts, getObjects, market 'free model' loaders. Returns findings [{path, line, pattern, severity}] — run after inserting any third-party model.", { properties: {} }, { readOnlyHint: true })),
    P(pluginTool("rbx_validate_asset", "Validate a Model/MeshPart for game use: descendant/tri-proxy counts, unanchored parts, cosmetic parts with CanCollide=true (physics waste), missing PrimaryPart, missing textures/SurfaceAppearance, oversized extents (>2048 studs), naming hygiene. Returns {issues:[...], stats:{...}} — run before rbx_equip_npc or export.", {
      properties: { path: { type: "string" } }, required: ["path"],
    }, { readOnlyHint: true })),

    // ---------------------------------------------------------------- gui
    P(pluginTool("rbx_build_gui", "Build REAL GuiObject trees (not images) from parametric UI patterns — resolution-safe UDim2 scales, UICorner/UIStroke/UIPadding/UIGradient standard, AnchorPoint-aware.\n\nPatterns: 'panel' (titled frame), 'healthbar' (track+fill+label), 'inventory_grid' (UIGridLayout slots), 'dialog' (modal + buttons), 'toast' (auto-expire notification), 'button_row', 'stat_label', 'shop_card', 'menu_list' (scrolling list), 'progress' (XP/progress ring-bar), 'tabbed_panel', 'hud_stack' (anchored corner stack).\n\nAll patterns accept theme tokens {bg,fg,accent,font,corner,stroke} — same tokens across a set = consistent UI (the deterministic equivalent of style-reference locking). parent defaults to StarterGui. Returns {root_path, children:[paths]} for follow-up edits.", {
      properties: {
        pattern: { type: "string", description: "One of: panel, healthbar, inventory_grid, dialog, toast, button_row, stat_label, shop_card, menu_list, progress, tabbed_panel, hud_stack" },
        name: { type: "string" }, parent_path: { type: "string" },
        config: { type: "object", description: "Pattern params: e.g. inventory_grid {slots=24, columns=6}, healthbar {value=0.75, max=100}, dialog {title, body, buttons=[{text, id}]}" },
        theme: { type: "object", description: "{bg='#ffffff', fg='#111111', accent='#0a84ff', font='GothamBold', corner=12, stroke=1}" },
        position: { type: "object", description: "Anchor preset: {anchor='top_left|top|top_right|left|center|right|bottom_left|bottom|bottom_right', offset={x,y}} — scale-based, resolution-safe" },
      },
      required: ["pattern"],
      __timeoutMs: 120000,
    }, { destructiveHint: true })),
    P(pluginTool("rbx_gui_theme", "Apply/replace theme tokens on an existing GUI subtree (re-tints backgrounds, borders, fonts, corners) — makes a whole UI set consistent in one call.", {
      properties: { path: { type: "string" }, theme: { type: "object" } }, required: ["path", "theme"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_wrap_image", "Wrap an image asset (rbxassetid:// or rbxthumb://) into correct responsive scaffolding: AspectRatioConstraint (keeps ratio), optional ScaleType=Slice 9-slice with SliceCenter, anchor preset, scale size. Returns the created ImageLabel path — pair with rbx_build_gui parents.", {
      properties: {
        image: { type: "string" }, parent_path: { type: "string" }, name: { type: "string" },
        aspect: { type: "number", description: "e.g. 1.0 for square; dominant AspectRatioConstraint" },
        nine_slice: { type: "object", description: "{sliceCenter={x0,y0,x1,y1}, scale=1.0}" },
        position: { type: "object" },
      },
      required: ["image"],
    }, { destructiveHint: true })),

    // ----------------------------------------------------------- terrain
    P(pluginTool("rbx_terrain_generate", "Procedural terrain via chunked Terrain:WriteVoxels (no freeze: one task.wait per 64³-cell chunk).\n\nParams: center {x,z} or {x,y,z}, size {x,z}, base_height, mountain_height, roughness (fBm octaves gain), ridge (0-1: ridged-noise fold → sharp mountain crests), seed, water_level (optional → Water fill), materials profile 'alpine'|'desert'|'volcanic'|'plains' (height+slope rules: Grass→Rock→Snow; desert→Sand; volcanic→Basalt+Lava), flatten_zones [{x,z,r,h}] for build plateaus.\n\nMountains: ridge≥0.6 + mountain_height≥120 gives real peaks; ridge=0 gives rolling hills. Returns {chunks_written, region, stats}. Preview first with small size (512²), then scale up.", {
      properties: {
        center: { type: "object" }, size: { type: "object" }, base_height: { type: "number" },
        mountain_height: { type: "number" }, roughness: { type: "number" }, ridge: { type: "number" },
        seed: { type: "number" }, water_level: { type: "number" },
        materials: { type: "string" }, flatten_zones: { type: "array" },
      },
      required: ["size"],
      __timeoutMs: 300000,
    }, { destructiveHint: true })),
    P(pluginTool("rbx_terrain_smooth", "Smooth terrain in a region (Erode-ish passes) — after generation to remove voxel stair-stepping.", {
      properties: { region_center: { type: "object" }, region_size: { type: "object" }, strength: { type: "number" } },
      required: ["region_center", "region_size"], __timeoutMs: 180000,
    }, { destructiveHint: true })),

    // ---------------------------------------------- computable 3D / armor
    P(pluginTool("rbx_rig_npc", "Create an NPC rig: Players:CreateHumanoidModelFromDescription (R15/R6) — real Humanoid, correct limb attachments, ready for rbx_fit_accessory/animations. Args: rig_type 'R15'|'R6', position {x,y,z}, name, description (HumanoidDescription subset: body colors, scale {height,width,depth,head,proportion}, accessory ids). Returns rig path.", {
      properties: {
        rig_type: { type: "string" }, position: { type: "object" }, name: { type: "string" },
        description: { type: "object" },
      },
    }, { destructiveHint: true })),
    P(pluginTool("rbx_fit_accessory", "Turn a Model/MeshPart into a correctly-attached Accessory or weld on a rig — the Accessory-Fitting-Tool workflow automated.\n\nmode 'accessory': creates proper Accessory (Handle + matching Attachment), aligns attachment CFrame to the target body attachment (HatAttachment, WaistCenter, NeckAttachment, LeftShoulderAttachment, ...), parents into the rig, Humanoid:AddAccessory-equivalent wiring.\nmode 'weld': WeldConstraint/Motor6D to the target limb, Massless=true, CanCollide=false — for armor sets and NPC gear.\nReturns {path, attachment, mode}. Verify with rbx_render_thumbnail.", {
      properties: {
        item_path: { type: "string" }, rig_path: { type: "string" },
        attachment: { type: "string", description: "Target attachment name e.g. HatAttachment, WaistCenter, NeckAttachment, RightShoulderAttachment" },
        mode: { type: "string", description: "accessory|weld (default accessory)" },
        offset_cframe: { type: "object", description: "Optional extra CFrame offset {pos={x,y,z}, rotDeg={x,y,z}}" },
      },
      required: ["item_path", "rig_path", "attachment"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_attach_part", "Attach any Part/Model to a rig: modes 'attachment' (snap own Attachment onto target), 'mesh' (rigid weld at current pose), 'bone' (Motor6D to Bone for skinned rigs). Sets Massless + CanCollide=false automatically.", {
      properties: { item_path: { type: "string" }, rig_path: { type: "string" }, target: { type: "string" }, mode: { type: "string" } },
      required: ["item_path", "rig_path", "target", "mode"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_equip_npc", "Equip a whole armor/prop set onto a rig in one call. items: [{item_path, attachment, mode, offset_cframe}]. Runs all fits, returns per-item results + combined waypoint — the 'dress this NPC' primitive.", {
      properties: { rig_path: { type: "string" }, items: { type: "array" } },
      required: ["rig_path", "items"], __timeoutMs: 120000,
    }, { destructiveHint: true })),
    {
      ...pluginTool("rbx_import_mesh", "Import a local FBX/GLB/OBJ as MeshPart. FBX/GLB → AssetService:CreateMeshPartAsync(Content.fromFile) — works for Blender exports. .obj → server parses it, then streams vert/face chunks to the plugin's editable_mesh cmd (≤250 verts / ≤350 tris per call, separate leases — survives big imports). auto-runs rbx_validate_asset and reports stats. args: file (abs path), name, parent_path, with_texture (optional image file). For Blender→Roblox: export GLB 1BU=1stud, Y-up.", {
        properties: { file: { type: "string" }, name: { type: "string" }, parent_path: { type: "string" }, with_texture: { type: "string" } },
        required: ["file"], __timeoutMs: 120000,
      }, { destructiveHint: true }),
      handler: async (a) => {
        const { studio_id, ...args } = a;
        if (!/\.obj$/i.test(args.file || ""))
          return broker.enqueue(studio_id, "import_mesh", args, 120000);
        const mesh = parseObjFile(args.file);
        if (!mesh.verts.length) throw new Error(`no vertices parsed from ${args.file}`);
        return streamEditableMesh(studio_id, mesh, {
          name: args.name || basename(args.file).replace(/\.obj$/i, ""),
          parent_path: args.parent_path || "Workspace",
          with_texture: args.with_texture,
        });
      },
    },

    // ------------------------------------------------------- assets & kits
    P(pluginTool("rbx_insert_asset", "Insert a Creator-Store/Toolbox asset by assetId into Workspace (InsertService:LoadAsset). ALWAYS run rbx_security_scan afterwards — third-party models are the #1 backdoor vector.", {
      properties: { asset_id: { type: "number" }, parent_path: { type: "string" } },
      required: ["asset_id"], __timeoutMs: 120000,
    }, { destructiveHint: true })),
    P(pluginTool("rbx_render_thumbnail", "Stage an instance for a screenshot: isolates it on a plate at a fixed camera frame. THEN call studio.screen_capture (upstream) to capture pixels — returns {camera, bounds} ready for capture.", {
      properties: { path: { type: "string" }, padding: { type: "number" } },
      required: ["path"],
    })),
    P(pluginTool("rbx_play_state", "Get playtest state {running, mode} or control it: action 'play' (TestService:Run) | 'stop' (best-effort shutdown request — may be blocked by plugin security; use studio.start_stop_play upstream as the reliable stop).", {
      properties: { action: { type: "string" } },
    })),
    {
      name: "rbx_apply_kit",
      description: "Materialize a curated game-system kit: scripts + instances wired together.\n\nKits: 'obby' (spawn+checkpoints+killbricks+leaderstats), 'economy' (currency + save + shop remote), 'combat' (health/damage/cooldown + hitzones), 'dialog' (NPC dialog tree + UI), 'save' (session-locked profile), 'topbar' (topbar buttons). List config keys first via rbx_kits.\n\nconfig is kit-specific JSON (e.g. economy {currency='Coins'}). Returns created paths + any required rbx_install_module follow-ups.",
      inputSchema: { type: "object", properties: { ...COMMON, kit: { type: "string" }, config: { type: "object" }, parent_path: { type: "string" } }, required: ["studio_id", "kit"] },
      annotations: { title: "apply kit", destructiveHint: true },
      handler: async (a) => {
        const src = local.kitSource(a.kit);
        const code = `local KIT_CONFIG = ${JSON.stringify(a.config || {})}\nlocal PARENT_PATH = ${JSON.stringify(a.parent_path || "")}\n` + src;
        return broker.enqueue(a.studio_id, "run_luau", { code }, 120000);
      },
    },
    {
      name: "rbx_install_module",
      description: "Install a vetted OSS Luau module into ReplicatedStorage/Packages: topbarplus, zoneplus, profileservice, trove, signal, promise, testez, fusion, knit, cmdr. Server fetches pinned source (vendor/manifest.json), plugin writes the ModuleScript. Returns {installed, path, version}.",
      inputSchema: { type: "object", properties: { ...COMMON, name: { type: "string" } }, required: ["studio_id", "name"] },
      annotations: { title: "install module", destructiveHint: true },
      handler: async (a) => {
        const { mod, cached, exists } = local.moduleSource(a.name);
        if (mod.dir) { // multi-file module: fetch whole repo dir, plugin rebuilds require-tree
          const files = await local.fetchRepoDir(a.name, mod);
          return broker.enqueue(a.studio_id, "install_module", { name: a.name, files }, 120000);
        }
        let source;
        if (exists) source = readFileSync(cached, "utf8");
        else {
          const res = await fetch(mod.url);
          if (!res.ok) throw new Error(`fetch failed ${res.status} for ${mod.url}`);
          source = await res.text();
          mkdirSync(dirname(cached), { recursive: true });
          writeFileSync(cached, source);
        }
        return broker.enqueue(a.studio_id, "install_module", { name: a.name, source }, 120000);
      },
    },
    {
      name: "rbx_sync_pull",
      description: "Dump all LuaSourceContainers to disk as a Rojo-style tree (ServerScriptService→src/server, ReplicatedStorage→src/shared, StarterPlayerScripts→src/client, StarterGui→src/gui, Workspace→src/world). Enables git versioning + rbx_lint/rbx_format/rbx_typecheck on real files.",
      inputSchema: { type: "object", properties: { ...COMMON, root_dir: { type: "string", description: "absolute output dir" } }, required: ["studio_id", "root_dir"] },
      annotations: { title: "sync pull" },
      handler: async (a) => {
        const payload = await broker.enqueue(a.studio_id, "dump_scripts", {}, 120000);
        const dirOf = (p) => {
          const top = p.split(".")[0];
          if (/ServerScriptService/.test(top)) return "src/server";
          if (/ReplicatedStorage/.test(top)) return "src/shared";
          if (/StarterPlayer|StarterPack|StarterCharacterScripts|StarterPlayerScripts/.test(top)) return "src/client";
          if (/StarterGui|PlayerGui/.test(top)) return "src/gui";
          if (/Workspace/.test(top)) return "src/world";
          return "src/misc";
        };
        const files = [];
        for (const s of payload.scripts || []) {
          const rel = join(dirOf(s.path), ...s.path.split(".").slice(1).map(x => x.replace(/[^\w.-]/g, "_")));
          const file = join(a.root_dir, rel + (s.className === "ModuleScript" ? ".lua" : s.className === "LocalScript" ? ".client.lua" : ".server.lua"));
          mkdirSync(dirname(file), { recursive: true });
          writeFileSync(file, s.source || "");
          files.push(file);
        }
        return { root: a.root_dir, written: files.length, files: files.slice(0, 50) };
      },
    },
    {
      name: "rbx_sync_push",
      description: "Push a synced file back into its script instance (inverse of rbx_sync_pull). Reconstructs the instance path from the file's position under the synced root.",
      inputSchema: { type: "object", properties: { ...COMMON, file: { type: "string" } }, required: ["studio_id", "file"] },
      annotations: { title: "sync push", destructiveHint: true },
      handler: async (a) => {
        const norm = a.file.replace(/\\/g, "/");
        const m = norm.match(/\/(server|shared|client|gui|world|misc)\/(.+)\.(server\.|client\.)?lua$/);
        if (!m) throw new Error("file not inside a synced rbx tree (expected src/{server,shared,client,gui,world}/...) ");
        const topMap = { server: "ServerScriptService", shared: "ReplicatedStorage", client: "StarterPlayer.StarterPlayerScripts", gui: "StarterGui", world: "Workspace", misc: "ReplicatedStorage" };
        const segs = m[2].split("/").filter(Boolean);
        const path = [topMap[m[1]], ...segs].join(".");
        const source = readFileSync(a.file, "utf8");
        const className = a.file.endsWith(".client.lua") ? "LocalScript" : a.file.endsWith(".server.lua") ? "Script" : "ModuleScript";
        return broker.enqueue(a.studio_id, "write_script", { path, className, source }, 120000);
      },
    },

    // ------------------------------------------- extended edit & behavior
    P(pluginTool("rbx_select", "Select an instance in Studio's explorer (helps the human follow your work).", {
      properties: { path: { type: "string" } }, required: ["path"], __cmd: "select_instance",
    })),
    P(pluginTool("rbx_set_attribute", "Set an attribute on an instance (waypoint). Attributes are the standard mechanism for gameplay metadata (Stage, Damage, Cooldown...).", {
      properties: { path: { type: "string" }, name: { type: "string" }, value: {} }, required: ["path", "name", "value"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_tag", "Add/remove a CollectionService tag (used by systems like ZonePlus-style queries, 'Enemy', 'Interactive'). Pass remove=true to untag.", {
      properties: { path: { type: "string" }, tag: { type: "string" }, remove: { type: "boolean" } }, required: ["path", "tag"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_move", "Reparent an instance to new_parent (waypoint).", {
      properties: { path: { type: "string" }, new_parent: { type: "string" } }, required: ["path", "new_parent"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_clone", "Clone an instance (waypoint), optional new_name + parent_path.", {
      properties: { path: { type: "string" }, new_name: { type: "string" }, parent_path: { type: "string" } }, required: ["path"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_find_replace", "Regex search across all scripts (or under path). Without replacement → search hits [{path,line,text}]. With replacement → in-place edit (waypoint). For multi-line rewrites use rbx_write_script.", {
      properties: { path: { type: "string" }, pattern: { type: "string" }, replacement: { type: "string" } }, required: ["pattern"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_batch", "Execute multiple plugin commands sequentially under ONE waypoint: ops=[{cmd:'create_instance',args:{...}},...]. Stops at first failure (applied ops stay — rbx_undo reverts). Use for builds with many small ops; drastically fewer round-trips than single calls.", {
      properties: { ops: { type: "array", items: { type: "object" } } }, required: ["ops"],
      __timeoutMs: 300000,
    }, { destructiveHint: true })),

    P(pluginTool("rbx_terrain_clear", "Erase terrain in a region (FillBlock Air). Use to redo a generation or carve build sites.", {
      properties: { region_center: { type: "object" }, region_size: { type: "object" } }, required: ["region_center", "region_size"], __timeoutMs: 120000,
    }, { destructiveHint: true })),
    P(pluginTool("rbx_npc_behavior", "Attach a behavior Script to a rig: 'patrol' (walks Waypoint1..N parts, auto-created from args.waypoints [{x,y,z}]), 'idle' (wander near origin), 'chase' (pursue nearest player <60 studs). Script lives inside the rig model.", {
      properties: { rig_path: { type: "string" }, behavior: { type: "string" }, waypoints: { type: "array" } }, required: ["rig_path", "behavior"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_build_animation", "Build a KeyframeSequence from pose tables: keyframes=[{time, parts:{RightUpperArm:{pos={x,y,z},rotDeg={x,y,z}},...}}]. Stored under the rig — use with AnimationEditor or load via Animator. easing_style/priority/loop configurable.", {
      properties: { rig_path: { type: "string" }, name: { type: "string" }, keyframes: { type: "array" }, loop: { type: "boolean" }, priority: { type: "string" }, easing_style: { type: "string" } }, required: ["keyframes"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_lighting", "Control the environment: time_of_day (0-24), technology, any Lighting prop via props{}, atmosphere{density,haze,color,offset,decay}, sky{celestial bodies + texture ids}, effects{Bloom/ColorCorrection/SunRays/DepthOfField/ColorShift:{props}}. Or preset: dawn|sunset|night|noon|storm|overcast — tuned ambient+fog+post bundles. Returns changed list + final state.", {
      properties: { preset: { type: "string" }, time_of_day: { type: "number" }, technology: { type: "string" }, props: { type: "object" }, atmosphere: { type: "object" }, sky: { type: "object" }, effects: { type: "object" } },
    }, { destructiveHint: true })),
    P(pluginTool("rbx_ui_sounds", "Wire custom UI sound effects onto a GUI: creates __RbxUISounds folder (curated click/hover/open/close/error/success/pop rbxassetids, overridable via sounds{name=id}) + a LocalScript wiring MouseButton1Click/MouseEnter on all GuiButtons. volume configurable. Non-slop: subtle 0.35 volume, one script, no per-button spam.", {
      properties: { path: { type: "string" }, sounds: { type: "object" }, volume: { type: "number" } }, required: ["path"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_scenario", "Advanced game test: run a sequence of commands with expectations. steps=[{cmd,args,expect:[{field:'a.b',eq|contains:val|(exists if empty)}]}]. Each step executes a plugin command (create_instance, run_luau, build_gui, terrain_generate...), then checks results. stop_on_fail aborts. Returns {passed,failed,steps:[{i,cmd,ok,result|error|expect_failed}]} — THE game-build verification loop.", {
      properties: { steps: { type: "array" }, stop_on_fail: { type: "boolean" } }, required: ["steps"],
    }, { destructiveHint: true })),

    // ------------------------------------------ v2: vfx, worlds, kits, gui
    P(pluginTool("rbx_vfx", "Particle/VFX preset factory: fire.torch|brazier|campfire|chimney_smoke, weather.rain|snow|mist|embers|leaves, magic.portal|rune|heal, explosion.small|large, banner. path=existing part to attach to, or position=[x,y,z] to spawn an emitter anchor. props overrides emitter props {rate,size,lifetime,color...}. scale multiplies preset sizes/rates. Returns {paths}.", {
      properties: {
        preset: { type: "string" }, path: { type: "string" }, position: { type: "array" },
        scale: { type: "number" }, props: { type: "object" },
      },
      required: ["preset"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_set_material", "Set Material (Enum name e.g. 'Slate','Cobblestone','CrackedLava') and/or MaterialVariant on a part tree. variant={name,base,brickColor} creates/reuses a MaterialVariant under MaterialService and assigns it — the custom-material look without texture files. terrain={region_center,region_size,material} paints voxels instead.", {
      properties: {
        path: { type: "string" }, material: { type: "string" },
        variant: { type: "object", description: "{name, base, brickColor}" },
        terrain: { type: "object", description: "{region_center, region_size, material}" },
      },
      required: ["path"], __cmd: "material",
    }, { destructiveHint: true })),
    P(pluginTool("rbx_populate", "Spawn an NPC crowd: count rigs (rig_type 'R15'|'R6') scattered inside area {center=[x,y,z], radius} — each gets a job behavior from jobs [{type:'idle'|'patrol'|'chase'|...}] and optional display names[]. Returns {created, rigs:[paths]}. The 'living world' primitive — pair with rbx_npc_behavior for custom logic.", {
      properties: {
        rig_type: { type: "string" }, count: { type: "number" },
        area: { type: "object", description: "{center=[x,y,z], radius}" },
        jobs: { type: "array" }, names: { type: "array" },
      },
      required: ["count", "area"], __timeoutMs: 120000,
    }, { destructiveHint: true })),
    P(pluginTool("rbx_optimize", "Performance audit of a subtree (or whole Workspace when path omitted): cosmetic parts with CanCollide/CanTouch/CanQuery on (physics/query waste), CastShadow on far/small props, unanchored statics, overdraw risks, StreamingEnabled hints. apply=true also fixes the safe set (waypoint). Returns {issues:[{path,issue,fix}], stats, applied?}.", {
      properties: { path: { type: "string" }, apply: { type: "boolean" } },
      __timeoutMs: 120000,
    })),
    P(pluginTool("rbx_audio", "Audio preset factory: ambience.forest|dungeon|rain|cave|city|night, music.combat|explore|menu|boss, ui.hover|click, positional loops via position=[x,y,z] or path=part emitter. volume (0-1), sound_id overrides the preset's curated rbxassetid. Returns {paths}.", {
      properties: {
        preset: { type: "string" }, path: { type: "string" }, position: { type: "array" },
        volume: { type: "number" }, sound_id: { type: "string" },
      },
      required: ["preset"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_cutscene", "Author a camera-spline cutscene: waypoints=[{pos=[x,y,z], look=[x,y,z], dur=seconds, fov?}] eased into a LocalScript under StarterPlayerScripts.RbxCutscene.<name> (trigger it in playtest). letterbox=true adds cinematic bars, shake={amp,freq} handheld motion. Returns {path, steps}.", {
      properties: {
        name: { type: "string" }, waypoints: { type: "array" },
        letterbox: { type: "boolean" }, shake: { type: "object", description: "{amp, freq}" },
      },
      required: ["waypoints"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_kit_place", "Instance a built kit piece: clones the master at ServerStorage.RbxKit.<kit>.<piece> once per transforms entry [{pos=[x,y,z], rot=[x,y,z]deg, scale?}] under parent_path — clones share MeshIds so mass placement is cheap (the modular-kit payoff). Returns {placed, paths}.", {
      properties: {
        kit: { type: "string" }, piece: { type: "string" },
        transforms: { type: "array", description: "[{pos=[x,y,z], rot=[deg], scale?}]" },
        parent_path: { type: "string" },
      },
      required: ["kit", "piece", "transforms"], __timeoutMs: 120000,
    }, { destructiveHint: true })),
    P(pluginTool("rbx_kit_pieces", "List pieces registered in a kit (masters under ServerStorage.RbxKit.<kit>). Returns [{name, path, tris?}] — check before rbx_kit_place.", {
      properties: { kit: { type: "string" } },
      required: ["kit"],
    }, { readOnlyHint: true })),
    P(pluginTool("rbx_gui_animate", "Attach a tween preset driver to a GuiObject: slide_in|fade|bounce|pulse — a LocalScript inside the element plays it on show (props: {dur, easing, delay, from, to}). Stacks with rbx_gui_component.", {
      properties: {
        path: { type: "string" },
        preset: { type: "string", description: "slide_in|fade|bounce|pulse" },
        props: { type: "object" },
      },
      required: ["path", "preset"],
    }, { destructiveHint: true })),
    P(pluginTool("rbx_gui_component", "Attach an interactive behavior to a GuiObject: draggable (mouse-drag), hover_fx (tint/grow on MouseEnter), click_scale (press shrink+release pop). props tunes behavior params. Creates a LocalScript inside the element.", {
      properties: {
        path: { type: "string" },
        behavior: { type: "string", description: "draggable|hover_fx|click_scale" },
        props: { type: "object" },
      },
      required: ["path", "behavior"],
    }, { destructiveHint: true })),

    // ------------------------------------------------ server-side builders
    {
      name: "rbx_build",
      description: "Run a parametric builder recipe (builders/<recipe>.lua on this server) inside Studio — gothic_wall, gothic_arch, buttress, crenellated_wall, spire, stair_flight, curtain_wall, tower_stack, interior_shell, courtyard, colonnade, keep... config is recipe-specific JSON ({origin, size, floors...}); config.parent_path chooses the parent (default Workspace). Returns the recipe's luau result.",
      inputSchema: { type: "object", properties: { ...COMMON, recipe: { type: "string" }, config: { type: "object" } }, required: ["studio_id", "recipe"] },
      annotations: { title: "build", destructiveHint: true },
      handler: async (a) => {
        let src;
        try { src = local.builderSource(a.recipe); }
        catch (e) { return { ok: false, error: e.message, recipes: local.listBuilders() }; }
        const cfg = a.config || {};
        const code = `local BUILD_CONFIG = ${JSON.stringify(cfg)}\nlocal PARENT_PATH = ${JSON.stringify(cfg.parent_path || "Workspace")}\n` + src;
        return broker.enqueue(a.studio_id, "run_luau", { code }, 120000);
      },
    },
    {
      name: "rbx_kit_build",
      description: "Build a modular mesh kit into ServerStorage.RbxKit.<kit> as MeshPart masters. Reads kits/mesh/<kit>/spec.json {pieces:[{name,file}], gen?}; source='files' parses each OBJ (kits/mesh/<kit>/ or vendor/cache/kit_<kit>/) and streams it through editable_mesh; source='generator' returns Blender-gen instructions instead (run spec.gen via upstream rbx3d.run_bpy, export OBJs, then re-call with source=files). Instance pieces with rbx_kit_place. Returns {pieces:[{name,tris,path}]}.",
      inputSchema: { type: "object", properties: { ...COMMON, kit: { type: "string" }, source: { type: "string", description: "files|generator (default files)" } }, required: ["studio_id", "kit"] },
      annotations: { title: "kit build", destructiveHint: true },
      handler: async (a) => {
        const spec = local.kitSpec(a.kit);
        if (!spec) return { ok: false, error: `no spec.json under kits/mesh/${a.kit}/ — create pieces[] {name,file} (+ optional gen)`, hint: "piece OBJs resolve under kits/mesh/<kit>/ then vendor/cache/kit_<kit>/" };
        if ((a.source || "files") === "generator") {
          if (!spec.gen) return { ok: false, error: `kit '${a.kit}' spec has no gen — nothing to generate`, spec };
          return { note: "run gen via upstream rbx3d.run_bpy, then re-call with source=files", spec };
        }
        const pieces = [];
        for (const p of spec.pieces || []) {
          const file = local.kitPiecePath(a.kit, p.file);
          const pname = p.name || (p.file || "").replace(/\.obj$/i, "") || "piece";
          if (!file) { pieces.push({ name: pname, error: `file '${p.file}' not found under kits/mesh/${a.kit}/ or vendor/cache/kit_${a.kit}/` }); continue; }
          const mesh = parseObjFile(file);
          if (!mesh.verts.length) { pieces.push({ name: pname, error: `no vertices in ${file}` }); continue; }
          const res = await streamEditableMesh(a.studio_id, mesh, { name: pname, parent_path: "ServerStorage" });
          const src = res?.path;
          if (!src) { pieces.push({ name: pname, tris: mesh.faces.length, error: "editable_mesh returned no path" }); continue; }
          // move + rename the built part under ServerStorage.RbxKit.<kit>.<piece>
          const mv = await broker.enqueue(a.studio_id, "run_luau", { code:
            `local ss = game:GetService("ServerStorage")\n` +
            `local rk = ss:FindFirstChild("RbxKit") or Instance.new("Folder")\nrk.Name = "RbxKit"\nrk.Parent = ss\n` +
            `local kd = rk:FindFirstChild(${JSON.stringify(a.kit)}) or Instance.new("Folder")\nkd.Name = ${JSON.stringify(a.kit)}\nkd.Parent = rk\n` +
            `local cur = game\nfor seg in tostring(${JSON.stringify(src)}):gmatch("[^%.]+") do\n\tcur = cur and cur:FindFirstChild(seg)\nend\n` +
            `if not cur then error("built piece not found: ${JSON.stringify(src)}") end\n` +
            `cur.Name = ${JSON.stringify(pname)}\ncur.Parent = kd\n` +
            `return { path = kd:GetFullName() .. "." .. cur.Name }` }, 120000);
          const path = mv?.result?.path || `ServerStorage.RbxKit.${a.kit}.${pname}`;
          pieces.push({ name: pname, tris: mesh.faces.length, verts: mesh.verts.length, path, ...(mv?.ok === false ? { warning: mv.error || "move-to-RbxKit failed" } : {}) });
        }
        return { ok: true, kit: a.kit, pieces };
      },
    },

    // ------------------------------------------------------- server-local
    {
      name: "rbx_diff",
      description: "Diff two snapshots (labels from rbx_snapshot): added/removed/changed paths + prop/script-hash changes. THE verification loop: snapshot → mutate → snapshot → rbx_diff.",
      inputSchema: { type: "object", properties: { a: { type: "string" }, b: { type: "string" } }, required: ["a", "b"] },
      annotations: { readOnlyHint: true },
      handler: (a) => local.diffSnapshots(a.a, a.b),
    },
    {
      name: "rbx_lint",
      description: "Run selene on a synced source tree or file (needs `rbx_sync_pull` first). Returns warnings [{file, line, severity, message}]. Requires selene on PATH or vendored.",
      inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
      annotations: { readOnlyHint: true },
      handler: (a) => local.runLinter(a.path),
    },
    {
      name: "rbx_format",
      description: "Format a synced file/tree with StyLua. Returns changed files.",
      inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
      handler: (a) => local.runFormatter(a.path),
    },
    {
      name: "rbx_typecheck",
      description: "Run luau-lsp analyze (strict types) on a synced tree. Returns diagnostics [{file, line, message, severity}].",
      inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
      annotations: { readOnlyHint: true },
      handler: (a) => local.runTypecheck(a.path),
    },
    {
      name: "rbx_kits",
      description: "List available game kits + vendored modules + skills with their config keys. Call before rbx_apply_kit/rbx_install_module.",
      inputSchema: { type: "object", properties: {} },
      annotations: { readOnlyHint: true },
      handler: () => local.listKits(),
    },
    {
      name: "rbx_skill",
      description: "Fetch an rbx knowledge pack (SKILL.md): 'gui-patterns', 'armor-rigging', 'terrain', 'verification-loop', 'kits', 'upstream-routing'. Load on demand — they encode the correct call sequences.",
      inputSchema: { type: "object", properties: { skill_name: { type: "string" } }, required: ["skill_name"] },
      annotations: { readOnlyHint: true },
      handler: (a) => local.readSkill(a.skill_name),
    },
    {
      name: "rbx_upstream_status",
      description: "Report routing state: which upstreams are connected (studio, rbx3d, blender, ...), how many tools each exposes, and the config path to fix missing ones.",
      inputSchema: { type: "object", properties: {} },
      annotations: { readOnlyHint: true },
      handler: () => router.status(),
    },
    {
      name: "rbx_docs",
      description: "Fetch a create.roblox.com doc page as markdown (engine reference, tutorials). Pass path like 'art/accessories/accessory-fitting-tool' or full URL. Use before implementing an unfamiliar API.",
      inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
      annotations: { readOnlyHint: true },
      handler: (a) => local.docsGet(a.path),
    },
    {
      name: "rbx_api_class",
      description: "Look up a Roblox class in the official API dump (cached): members with types, tags (Deprecated/NotScriptable), superclass. Settle 'does this property exist' questions WITHOUT guessing.",
      inputSchema: { type: "object", properties: { class_name: { type: "string" } }, required: ["class_name"] },
      annotations: { readOnlyHint: true },
      handler: (a) => local.apiClass(a.class_name),
    },
    {
      name: "rbx_api_enum",
      description: "Look up an Enum's items (Material, Font, CollisionFidelity, HumanoidRigType...). Returns [{name, value}] — use for exact Enum spelling in props.",
      inputSchema: { type: "object", properties: { enum_name: { type: "string" } }, required: ["enum_name"] },
      annotations: { readOnlyHint: true },
      handler: (a) => local.apiEnum(a.enum_name),
    },
    {
      name: "rbx_mesh_watch",
      description: "Watch a local folder: when a .fbx/.glb/.obj lands there (e.g. Blender export → C:/.../export), auto-imports it into Studio as MeshPart + validates. The Blender bridge — export from Blender MCP, it appears in game. args: dir, parent_path, stop=true to cancel.",
      inputSchema: { type: "object", properties: { ...COMMON, dir: { type: "string" }, parent_path: { type: "string" }, stop: { type: "boolean" } }, required: ["studio_id", "dir"] },
      handler: async (a) => a.stop ? local.meshWatchStop(a.dir) : local.meshWatchStart(a.dir, a.parent_path || "Workspace", a.studio_id, broker),
    },
    {
      name: "rbx_call_upstream",
      description: "Generic upstream passthrough for tools not exposed individually: call('studio','execute_luau',{code:...,datamodel_type:'Client',studio_id:...}). Prefer the dedicated studio.* tools when they exist.",
      inputSchema: {
        type: "object",
        properties: { server: { type: "string" }, tool: { type: "string" }, args: { type: "object" } },
        required: ["server", "tool"],
      },
      handler: (a) => router.call(`${a.server}.${a.tool}`, a.args || {}),
    },
  ];

  return tools;
}
