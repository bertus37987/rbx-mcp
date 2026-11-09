#!/usr/bin/env node
// Server-local tools: snapshot diffing, external Luau toolchain (selene /
// StyLua / luau-lsp), kit + skill catalogs. None of these need Studio.

import { execFile } from "node:child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { join, dirname, extname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(__dirname, "..");
const SNAP_DIR = join(PKG_ROOT, ".snapshots");
const KITS_DIR = join(PKG_ROOT, "kits");
const KITS_MESH_DIR = join(KITS_DIR, "mesh");
const BUILDERS_DIR = join(PKG_ROOT, "builders");
const SKILLS_DIR = join(PKG_ROOT, "skills");
const VENDOR_MANIFEST = join(PKG_ROOT, "vendor", "manifest.json");
const CACHE = join(PKG_ROOT, "vendor", "cache");

mkdirSync(SNAP_DIR, { recursive: true });
mkdirSync(CACHE, { recursive: true });

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: opts.timeoutMs || 60000, maxBuffer: 8 * 1024 * 1024, ...(opts.execOpts || {}) }, (err, stdout, stderr) => {
      resolve({ ok: !err, code: err?.code ?? 0, stdout: String(stdout), stderr: String(stderr), missing: !!err && /ENOENT/.test(String(err)) });
    });
  });
}

export function createLocalTools() {
  // ---------------------------------------------------------- snapshots
  function saveSnapshot(label, data) {
    const file = join(SNAP_DIR, `${label.replace(/[^\w.-]/g, "_")}.json`);
    writeFileSync(file, JSON.stringify(data, null, 0));
    return file;
  }
  function loadSnapshot(label) {
    const file = join(SNAP_DIR, `${label}.json`);
    if (!existsSync(file)) throw new Error(`no snapshot '${label}' — run rbx_snapshot with label first`);
    return JSON.parse(readFileSync(file, "utf8"));
  }
  function flattenSnap(snap) {
    const map = new Map();
    for (const n of snap.nodes || []) map.set(n.path, n);
    return map;
  }
  function diffSnapshots(a, b) {
    const A = flattenSnap(loadSnapshot(a));
    const B = flattenSnap(loadSnapshot(b));
    const added = [], removed = [], changed = [];
    for (const [p, n] of B) {
      if (!A.has(p)) added.push({ path: p, className: n.className });
      else {
        const o = A.get(p);
        const diffs = {};
        if (o.className !== n.className) diffs.className = [o.className, n.className];
        if (o.hash && n.hash && o.hash !== n.hash) diffs.source = "changed";
        for (const k of new Set([...Object.keys(o.props || {}), ...Object.keys(n.props || {})])) {
          const ov = JSON.stringify(o.props?.[k]), nv = JSON.stringify(n.props?.[k]);
          if (ov !== nv) diffs[k] = [o.props?.[k], n.props?.[k]];
        }
        if (Object.keys(diffs).length) changed.push({ path: p, diffs });
      }
    }
    for (const p of A.keys()) if (!B.has(p)) removed.push({ path: p, className: A.get(p).className });
    return { added, removed, changed, counts: { added: added.length, removed: removed.length, changed: changed.length } };
  }

  // ----------------------------------------------------- Luau toolchain
  async function runLinter(path) {
    const r = await run("selene", ["--display-style", "json2", path]);
    if (r.missing) return { error: "selene not found on PATH. Install: `cargo install selene` or `pesde add selene`, or vendor it into packages/rbx-mcp/vendor/bin." };
    const diags = [];
    for (const line of r.stdout.split(/\r?\n/)) {
      if (!line.trim()) continue;
      try { const d = JSON.parse(line); diags.push({ file: d.filename, line: d.primary_label?.span?.start_line, severity: d.severity, message: d.message }); } catch {}
    }
    return { tool: "selene", diagnostics: diags, count: diags.length };
  }
  async function runFormatter(path, { check = false } = {}) {
    const probe = await run("stylua", ["--version"]);
    if (probe.missing) return { error: "stylua not found on PATH. Install: `cargo install stylua` or `pesde add stylua`." };
    if (check) {
      const r = await run("stylua", ["--check", path]);
      return { ok: r.ok, changed: !r.ok, output: r.stdout || r.stderr };
    }
    const fmt = await run("stylua", [path]);
    return { ok: fmt.ok, output: fmt.stdout || fmt.stderr };
  }
  async function runTypecheck(path) {
    const r = await run("luau-lsp", ["analyze", "--formatter", "plain", path]);
    if (r.missing) return { error: "luau-lsp not found on PATH. Install: `cargo install luau-lsp` or `pesde add luau-lsp`." };
    const diags = [];
    for (const m of r.stdout.matchAll(/^(.*?)\((\d+),(\d+)\):\s*(Warning|Error|Info):\s*(.*)$/gm)) {
      diags.push({ file: m[1], line: +m[2], col: +m[3], severity: m[4], message: m[5] });
    }
    return { tool: "luau-lsp", diagnostics: diags, count: diags.length };
  }

  // ------------------------------------------------------------ catalogs
  function listKits() {
    const kits = existsSync(KITS_DIR) ? readdirSync(KITS_DIR).filter(f => f.endsWith(".lua")).map(f => f.replace(/\.lua$/, "")) : [];
    let vendor = {};
    if (existsSync(VENDOR_MANIFEST)) vendor = JSON.parse(readFileSync(VENDOR_MANIFEST, "utf8")).modules || {};
    const skills = existsSync(SKILLS_DIR) ? readdirSync(SKILLS_DIR).filter(f => f.endsWith(".md")).map(f => f.replace(/\.md$/, "")) : [];
    return {
      kits: kits.map(k => {
        const meta = join(KITS_DIR, `${k}.json`);
        return { name: k, config: existsSync(meta) ? JSON.parse(readFileSync(meta, "utf8")).configKeys || {} : {} };
      }),
      modules: Object.keys(vendor),
      skills,
    };
  }
  function readSkill(name) {
    const file = join(SKILLS_DIR, `${name}.md`);
    if (!existsSync(file)) return { error: `unknown skill '${name}'. Available: ${listKits().skills.join(", ")}` };
    return readFileSync(file, "utf8");
  }
  function kitSource(name) {
    const lua = join(KITS_DIR, `${name}.lua`);
    if (!existsSync(lua)) throw new Error(`unknown kit '${name}'. Available: ${listKits().kits.map(k => k.name).join(", ")}`);
    return readFileSync(lua, "utf8");
  }
  function moduleSource(name) {
    const mf = existsSync(VENDOR_MANIFEST) ? JSON.parse(readFileSync(VENDOR_MANIFEST, "utf8")) : { modules: {} };
    const mod = mf.modules?.[name];
    if (!mod) throw new Error(`unknown module '${name}'. Available: ${Object.keys(mf.modules || {}).join(", ")}`);
    const cached = join(CACHE, `${name}.lua`);
    return { mod, cached, exists: existsSync(cached) };
  }

  // ------------------------------------------- builders + mesh kits
  // builders/<recipe>.lua = parametric world builders run via run_luau with
  // BUILD_CONFIG + PARENT_PATH prepended (rbx_build).
  function listBuilders() {
    return existsSync(BUILDERS_DIR) ? readdirSync(BUILDERS_DIR).filter(f => f.endsWith(".lua")).map(f => f.replace(/\.lua$/, "")) : [];
  }
  function builderSource(name) {
    const lua = join(BUILDERS_DIR, `${name}.lua`);
    if (!existsSync(lua)) throw new Error(`unknown recipe '${name}'. Available: ${listBuilders().join(", ") || "(none — builders/ missing or empty)"}`);
    return readFileSync(lua, "utf8");
  }
  // kits/mesh/<kit>/spec.json = {pieces:[{name,file}], gen?} — OBJ pieces for
  // rbx_kit_build; files may also live in vendor/cache/kit_<kit>/ (generated).
  function kitSpec(kit) {
    const file = join(KITS_MESH_DIR, kit, "spec.json");
    return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : null;
  }
  function kitPiecePath(kit, file) {
    for (const p of [join(KITS_MESH_DIR, kit, file), join(KITS_MESH_DIR, kit, "out", file), join(CACHE, `kit_${kit}`, file)])
      if (existsSync(p)) return p;
    return null;
  }

  // Fetch a whole module directory from a GitHub repo tarball (codeload) —
  // needed for multi-file modules whose init requires sibling files.
  async function fetchRepoDir(name, mod) {
    const cacheFile = join(CACHE, `${name}.tree.json`);
    try {
      if (existsSync(cacheFile) && Date.now() - statSync(cacheFile).mtimeMs < 86400000)
        return JSON.parse(readFileSync(cacheFile, "utf8"));
    } catch { /* refetch */ }
    const ref = mod.ref || "main";
    const url = `https://codeload.github.com/${mod.repo}/tar.gz/refs/heads/${ref}`;
    const res = await fetch(url, { signal: AbortSignal.timeout(30000) });
    if (!res.ok) throw new Error(`repo fetch ${mod.repo}@${ref} → HTTP ${res.status}`);
    const { gunzipSync } = await import("node:zlib");
    const tar = gunzipSync(Buffer.from(await res.arrayBuffer()));
    const files = {};
    let off = 0;
    const SKIP = /(\.test\.|\.spec\.|\/tests?\/|\.server\.|\.client\.)/i;
    while (off + 512 <= tar.length) {
      const fname = tar.toString("utf8", off, off + 100).replace(/\0.*$/, "");
      const fsize = parseInt(tar.toString("utf8", off + 124, off + 136).replace(/\0.*$/, "").trim() || "0", 8);
      const type = tar[off + 156];
      if (!fname) break;
      const rel = fname.replace(/^[^/]+\//, ""); // strip repo-root dir
      if (type === 48 || type === 0) { // regular file ('0' or NUL)
        if (rel.startsWith(mod.dir + "/") && /\.lua[u]?$/.test(rel) && !SKIP.test(rel)) {
          files[rel.slice(mod.dir.length + 1)] = tar.toString("utf8", off + 512, off + 512 + fsize);
        }
      }
      off += 512 + Math.ceil(fsize / 512) * 512;
    }
    if (!Object.keys(files).length) throw new Error(`no lua files under '${mod.dir}' in ${mod.repo}@${ref}`);
    mkdirSync(CACHE, { recursive: true });
    writeFileSync(cacheFile, JSON.stringify(files));
    return files;
  }

  // ------------------------------------------------------------ docs
  async function docsGet(path) {
    const url = path.startsWith("http") ? path : "https://create.roblox.com/docs/en-us/" + path.replace(/\.md$/, "") + ".md";
    const res = await fetch(url, { signal: AbortSignal.timeout(15000) });
    if (!res.ok) throw new Error(`docs fetch ${url} → HTTP ${res.status}`);
    const text = await res.text();
    return { url, bytes: text.length, content: text.slice(0, 24000), truncated: text.length > 24000 };
  }

  // --------------------------------------------------- API dump cache
  const API_DUMP_URL = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/master/API-Dump.json";
  let _apiDump = null;
  async function apiDump() {
    if (_apiDump) return _apiDump;
    const cacheFile = join(CACHE, "api-dump.json");
    try {
      const { statSync } = await import("node:fs");
      if (Date.now() - statSync(cacheFile).mtimeMs < 7 * 86400000) {
        _apiDump = JSON.parse(readFileSync(cacheFile, "utf8"));
        return _apiDump;
      }
    } catch { /* no/stale cache */ }
    const res = await fetch(API_DUMP_URL, { signal: AbortSignal.timeout(30000) });
    if (!res.ok) throw new Error(`api dump fetch → HTTP ${res.status}`);
    _apiDump = await res.json();
    try { writeFileSync(cacheFile, JSON.stringify(_apiDump)); } catch {}
    return _apiDump;
  }
  async function apiClass(name) {
    const dump = await apiDump();
    const cls = (dump.Classes || []).find(c => c.Name === name);
    if (!cls) {
      const near = (dump.Classes || []).filter(c => c.Name.toLowerCase().includes(name.toLowerCase())).map(c => c.Name).slice(0, 15);
      return { found: false, suggestions: near };
    }
    const members = (cls.Members || []).map(m => ({
      kind: m.MemberType, name: m.Name,
      type: m.ValueType?.Name || (m.Parameters ? "(function)" : m.ReturnType?.Name),
      tags: (m.Tags || []).join(","),
    }));
    return { found: true, class: cls.Name, superclass: cls.Superclass, tags: (cls.Tags || []).join(","), members };
  }
  async function apiEnum(name) {
    const dump = await apiDump();
    const en = (dump.Enums || []).find(e => e.Name === name);
    if (!en) {
      const near = (dump.Enums || []).filter(e => e.Name.toLowerCase().includes(name.toLowerCase())).map(e => e.Name).slice(0, 15);
      return { found: false, suggestions: near };
    }
    return { found: true, enum: en.Name, items: (en.Items || []).map(i => ({ name: i.Name, value: i.Value })) };
  }

  // ----------------------------------------------------- mesh watch
  const _watchers = new Map();
  async function anyStudioId(broker) {
    return (await broker.state()).instances[0]?.studioId || null;
  }
  async function meshWatchStart(dir, parentPath, studioId, broker) {
    if (_watchers.has(dir)) return { watching: dir, already: true };
    const { watch } = await import("node:fs");
    const w = watch(dir, async (_evt, filename) => {
      if (!filename || !/\.(fbx|glb|gltf|obj)$/i.test(filename)) return;
      const sid = studioId || await anyStudioId(broker);
      if (!sid) return;
      await new Promise(r => setTimeout(r, 800)); // let writer finish
      try {
        await broker.enqueue(sid, "import_mesh", { file: join(dir, filename), parent_path: parentPath }, 120000);
      } catch { /* import failed — leave file for manual rbx_import_mesh */ }
    });
    _watchers.set(dir, w);
    return { watching: dir, parent_path: parentPath, note: "drop .fbx/.glb/.obj — auto-import while Studio connected (Blender: export to this folder)" };
  }
  function meshWatchStop(dir) {
    const w = _watchers.get(dir);
    if (!w) return { stopped: null, note: `no watcher on ${dir}` };
    w.close(); _watchers.delete(dir);
    return { stopped: dir };
  }

  return {
    saveSnapshot, loadSnapshot, diffSnapshots,
    runLinter, runFormatter, runTypecheck,
    listKits, readSkill, kitSource, moduleSource,
    listBuilders, builderSource, kitSpec, kitPiecePath,
    docsGet, apiClass, apiEnum, meshWatchStart, meshWatchStop, fetchRepoDir,
    dirs: { snapshots: SNAP_DIR, kits: KITS_DIR, kitsMesh: KITS_MESH_DIR, builders: BUILDERS_DIR, skills: SKILLS_DIR },
    run,
  };
}
