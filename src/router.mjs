#!/usr/bin/env node
// Upstream MCP router: connects to other MCP servers (official Roblox Studio MCP
// endpoint, blender, rbx3d, forgegui, ...) and re-exports their tools under
// `server.tool` names — or transparent routes (studio.capture → screen_capture).
//
// Config (rbx-mcp.config.json next to the package or in cwd):
// {
//   "port": 58420,
//   "upstreams": {
//     "studio":  { "kind": "http",  "url": "http://127.0.0.1:31521/mcp" },
//     "rbx3d":   { "kind": "stdio", "command": "uvx", "args": ["rbx3d-mcp"] },
//     "blender": { "kind": "stdio", "command": "..." }
//   }
// }
// Unreachable upstreams degrade to a single stub tool that explains how to connect.

import { existsSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { connectStdioUpstream, connectHttpUpstream } from "./mcp.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(__dirname, "..");

export function loadConfig(cwd = process.cwd()) {
  const candidates = [
    join(cwd, "rbx-mcp.config.json"),
    join(PKG_ROOT, "rbx-mcp.config.json"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) {
      try { return { configPath: p, ...JSON.parse(readFileSync(p, "utf8")) }; }
      catch (e) { return { configPath: p, error: String(e), upstreams: {} }; }
    }
  }
  return { upstreams: {} };
}

export async function createRouter(config) {
  const upstreams = new Map(); // name -> { conn, tools: Map<qualified, tool>, status, error }

  async function attach(name, spec) {
    const entry = { conn: null, tools: new Map(), status: "connecting", spec };
    upstreams.set(name, entry);
    try {
      const conn = spec.kind === "http" || spec.url
        ? connectHttpUpstream({ url: spec.url, headers: spec.headers || {}, name })
        : connectStdioUpstream({ command: spec.command, args: spec.args || [], env: spec.env || {}, name });
      await conn.ready;
      const tools = await conn.tools();
      for (const t of tools) entry.tools.set(`${name}.${t.name}`, { upstream: t.name, schema: t.inputSchema, description: t.description });
      entry.conn = conn;
      entry.status = "connected";
    } catch (e) {
      entry.status = "failed";
      entry.error = String(e?.message || e);
    }
    return entry;
  }

  const specs = Object.entries(config.upstreams || {});
  await Promise.all(specs.map(([n, s]) => attach(n, s)));

  return {
    upstreams,
    status() {
      const o = {};
      for (const [n, e] of upstreams) o[n] = { status: e.status, tools: e.tools.size, error: e.error };
      return o;
    },
    listTools() {
      const out = [];
      for (const [name, e] of upstreams) {
        if (e.status !== "connected") {
          out.push({
            name: `${name}.__status`,
            description: `Upstream '${name}' is NOT connected (${e.error || "unknown"}). ` +
              (name === "studio"
                ? "Enable it in Roblox Studio: Assistant → Settings → MCP Servers → 'Enable Studio as MCP server', then set upstreams.studio.url in rbx-mcp.config.json."
                : `Configure upstreams.${name} in rbx-mcp.config.json (kind: stdio+command or http+url).`),
            inputSchema: { type: "object", properties: {} },
            handler: async () => `upstream '${name}' not connected: ${e.error || ""}`,
          });
          continue;
        }
        for (const [qname, t] of e.tools) {
          out.push({
            name: qname,
            description: `[routed → ${name}] ${t.description || qname}`.slice(0, 1024),
            inputSchema: t.schema || { type: "object" },
            handler: async (args) => e.conn.call(t.upstream, args),
          });
        }
      }
      return out;
    },
    async call(qualified, args) {
      const [name, tool] = qualified.split(".", 2);
      const e = upstreams.get(name);
      if (!e || e.status !== "connected") throw new Error(`upstream '${name}' not connected`);
      return e.conn.call(tool, args);
    },
    async close() { for (const e of upstreams.values()) e.conn?.close?.(); },
  };
}
