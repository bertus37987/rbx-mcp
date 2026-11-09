#!/usr/bin/env node
// Self-test without Roblox Studio: a fake plugin speaks the real poll/result
// protocol (hello → /v1/poll lease → command → /v1/result) while a stdio MCP
// client drives tools/call against the same server process.

import { spawn } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BIN = join(__dirname, "..", "bin", "rbx-mcp.mjs");
const BROKER = "http://127.0.0.1:58420";
const SID = "sim-1";
let pass = 0, fail = 0;
const check = (name, cond, extra = "") => { (cond ? pass++ : fail++); console.log(`${cond ? "PASS" : "FAIL"} ${name}${extra ? " — " + extra : ""}`); };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function post(path, body) {
  const res = await fetch(BROKER + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(40000) });
  if (res.status === 204) return null;
  return res.json();
}

// ---- fake plugin (mirrors RbxMcp.lua poll/dispatch/result loop) --------
const FAKE_HANDLERS = {
  ping: () => ({ pong: true, place: "FakePlace", version: "0.1.0" }),
  get_tree: () => ({ nodes: [
    { path: "Workspace", className: "Workspace", props: {} },
    { path: "Workspace.Baseplate", className: "Part", props: { Anchored: true } },
    { path: "ServerScriptService", className: "ServerScriptService", props: {} },
    { path: "ServerScriptService.Main", className: "Script", props: {}, hash: "abc123" },
  ] }),
  create_instance: (a) => ({ path: `${a.parent_path || "Workspace"}.${a.name}`, className: a.class_name }),
  run_luau: (a) => a.code.includes("error(") ? { ok: false, error: "simulated error" } : { ok: true, result: a.code.includes("return") ? 42 : null },
  snapshot: (a) => ({ label: a.label, nodes: [{ path: "Workspace", className: "Workspace" }] }),
  batch: (a) => ({ results: a.ops.map((op, i) => ({ i, cmd: op.cmd, ok: true, result: { path: `Workspace.Op${i}` } })), applied: a.ops.length }),
};
async function fakePlugin() {
  await post("/v1/hello", { studioId: SID, place: "FakePlace", placeId: 0, version: "0.1.0", caps: Object.keys(FAKE_HANDLERS) });
  for (let i = 0; i < 80; i++) {
    let cmd;
    try { cmd = await post("/v1/poll", { studioId: SID }); } catch { continue; }
    if (!cmd) continue; // 204 — no work
    const { lease, cmd: name, args } = cmd;
    const fn = FAKE_HANDLERS[name];
    if (!fn) { await post("/v1/result", { lease, ok: false, result: `unknown cmd ${name}` }); continue; }
    try { await post("/v1/result", { lease, ok: true, result: fn(args || {}) }); }
    catch { /* server gone */ }
  }
}

// ---- stdio MCP client -------------------------------------------------
function mcpClient(child) {
  let id = 0; const pending = new Map(); let buf = "";
  child.stdout.on("data", d => {
    buf += d.toString();
    let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx).trim(); buf = buf.slice(idx + 1);
      if (!line) continue;
      let msg; try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id !== undefined && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
    }
  });
  return (method, params) => new Promise((resolve, reject) => {
    const rid = ++id;
    pending.set(rid, resolve);
    setTimeout(() => { if (pending.has(rid)) { pending.delete(rid); reject(new Error("timeout " + method)); } }, 120000);
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: rid, method, params }) + "\n");
  });
}
const call = async (rpc, name, args) => {
  const r = await rpc("tools/call", { name, arguments: args });
  if (r.error) throw new Error(`${name} → ${JSON.stringify(r.error)}`);
  const text = r.result?.content?.[0]?.text ?? "";
  let parsed; try { parsed = JSON.parse(text); } catch { parsed = text; }
  return { parsed, isError: r.result?.isError };
};

// ---- run ---------------------------------------------------------------
const server = spawn("node", [BIN, "serve"], { stdio: ["pipe", "pipe", "pipe"] });
server.stderr.on("data", d => process.stderr.write("[srv] " + d));
await sleep(1200);
const rpc = mcpClient(server);

try {
  const init = await rpc("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "selftest", version: "0" } });
  check("initialize", init.result?.serverInfo?.name === "rbx-mcp");
  const list = await rpc("tools/list", {});
  const names = (list.result?.tools || []).map(t => t.name);
  check("tools/list ≥ 50 tools", names.length >= 50, `${names.length} tools`);

  fakePlugin(); // background
  await sleep(600);

  const studios = await call(rpc, "rbx_studios", {});
  check("rbx_studios sees fake plugin", JSON.stringify(studios.parsed).includes(SID));

  const ping = await call(rpc, "rbx_ping", { studio_id: SID });
  check("rbx_ping → pong", ping.parsed.pong === true && ping.parsed.place === "FakePlace");

  const tree = await call(rpc, "rbx_get_tree", { studio_id: SID });
  check("rbx_get_tree returns nodes", Array.isArray(tree.parsed.nodes) && tree.parsed.nodes.length === 4);

  const lua = await call(rpc, "rbx_run_luau", { studio_id: SID, code: "return 42" });
  check("rbx_run_luau ok", lua.parsed.ok === true);

  const luaErr = await call(rpc, "rbx_run_luau", { studio_id: SID, code: 'error("boom")' });
  check("rbx_run_luau propagates error", luaErr.parsed.ok === false);

  const batch = await call(rpc, "rbx_batch", { studio_id: SID, ops: [{ cmd: "create_instance", args: { class_name: "Part", name: "A", parent_path: "Workspace" } }, { cmd: "create_instance", args: { class_name: "Part", name: "B", parent_path: "Workspace" } }] });
  check("rbx_batch applied 2 ops", batch.parsed.applied === 2);

  const kits = await call(rpc, "rbx_kits", {});
  check("rbx_kits lists obby+economy", JSON.stringify(kits.parsed).includes("obby") && JSON.stringify(kits.parsed).includes("economy"));

  const snap = await call(rpc, "rbx_snapshot", { studio_id: SID, label: "t1" });
  check("rbx_snapshot saved", snap.parsed.label === "t1" || snap.parsed.saved === true || (snap.parsed.nodes ?? []).length > 0);

  const up = await call(rpc, "rbx_upstream_status", {});
  check("rbx_upstream_status reports", typeof up.parsed === "object");
} catch (e) {
  fail++; console.log("FAIL exception — " + e.message);
} finally {
  server.kill();
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
