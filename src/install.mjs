#!/usr/bin/env node
// Installer: drop the Studio plugin + register rbx-mcp with every detected
// MCP client. "Installierbar für alle AI agents" = one command wires it up.

import { existsSync, readFileSync, writeFileSync, copyFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir, platform } from "node:os";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(__dirname, "..");
const HOME = homedir();
const SERVE = ["node", join(PKG_ROOT, "bin", "rbx-mcp.mjs"), "serve"];

function pluginsDir() {
  if (platform() === "win32") return join(process.env.LOCALAPPDATA || join(HOME, "AppData/Local"), "Roblox", "Plugins");
  if (platform() === "darwin") return join(HOME, "Documents", "Roblox", "Plugins");
  return join(HOME, ".local", "share", "Roblox", "Plugins"); // linux (grapejuice etc.)
}

export function installPlugin() {
  const src = join(PKG_ROOT, "plugin", "RbxMcp.lua");
  const dir = pluginsDir();
  mkdirSync(dir, { recursive: true });
  const dst = join(dir, "RbxMcp.lua");
  copyFileSync(src, dst);
  return { copied: dst };
}

// Always-on broker: register a hidden startup launcher so 127.0.0.1:58420 is
// up whenever the user is logged in — no agent or toolbar click needed.
// `serve` attaches to this system broker via HTTP instead of embedding one.
export function installAutostart() {
  const startup = join(process.env.APPDATA || join(HOME, "AppData/Roaming"), "Microsoft", "Windows", "Start Menu", "Programs", "Startup");
  const launcher = join(startup, "rbx-mcp-broker.vbs");
  const nodePath = process.execPath;
  const script = join(PKG_ROOT, "bin", "rbx-mcp.mjs");
  const vbs = [
    `' rbx-mcp broker autostart (installed by rbx-mcp install)`,
    `CreateObject("Wscript.Shell").Run """${nodePath}"" ""${script}"" broker", 0, False`,
    ``,
  ].join("\r\n");
  mkdirSync(startup, { recursive: true });
  writeFileSync(launcher, vbs);
  return { wrote: launcher, how: "Windows Startup folder, hidden wscript" };
}

function mcpEntry() {
  // keep it spawnable without npx -y downloads: absolute node + absolute script
  return { command: SERVE[0], args: [SERVE[1], "serve"] };
}

function mergeJsonConfig(path, key, entry) {
  mkdirSync(dirname(path), { recursive: true });
  let cfg = {};
  if (existsSync(path)) { try { cfg = JSON.parse(readFileSync(path, "utf8")); } catch { cfg = {}; } }
  cfg[key] = cfg[key] || {};
  cfg[key]["rbx-mcp"] = entry;
  writeFileSync(path, JSON.stringify(cfg, null, 2));
  return path;
}

export function install({ clients } = {}) {
  const entry = mcpEntry();
  const results = { plugin: null, clients: {}, notes: [] };

  try { results.plugin = installPlugin(); }
  catch (e) { results.notes.push(`plugin copy failed: ${e.message}`); }

  if (platform() === "win32") {
    try { results.clients["broker-autostart"] = installAutostart(); }
    catch (e) { results.clients["broker-autostart"] = { error: String(e.message || e) }; }
  }

  const targets = {
    "claude-code": join(HOME, ".claude.json"),
    "cursor": join(HOME, ".cursor", "mcp.json"),
    "windsurf": join(HOME, ".codeium", "windsurf", "mcp_config.json"),
    "vscode": join(process.cwd(), ".vscode", "mcp.json"),
  };
  const wanted = clients || Object.keys(targets);
  for (const name of wanted) {
    const path = targets[name];
    if (!path) { results.clients[name] = { skipped: "unknown client" }; continue; }
    try {
      mergeJsonConfig(path, "mcpServers", entry);
      results.clients[name] = { wrote: path };
    } catch (e) {
      results.clients[name] = { error: String(e.message || e) };
    }
  }

  // Codex is TOML — append a server table if missing.
  const codexPath = join(HOME, ".codex", "config.toml");
  if (!clients || clients.includes("codex")) {
    try {
      mkdirSync(dirname(codexPath), { recursive: true });
      const cur = existsSync(codexPath) ? readFileSync(codexPath, "utf8") : "";
      if (!cur.includes("[mcp_servers.rbx-mcp]")) {
        writeFileSync(codexPath, cur + `\n[mcp_servers.rbx-mcp]\ncommand = "${SERVE[0].replace(/\\/g, "\\\\")}"\nargs = [${SERVE.slice(1).map(a => `"${a.replace(/\\/g, "\\\\")}"`).join(", ")}]\n`);
      }
      results.clients["codex"] = { wrote: codexPath };
    } catch (e) { results.clients["codex"] = { error: String(e.message || e) }; }
  }

  // agent-harness gateway upstream entry
  const gw = join(PKG_ROOT, "..", "mcp-gateway", "mcp.servers.json");
  try {
    const cfg = JSON.parse(readFileSync(gw, "utf8"));
    cfg.upstreams = cfg.upstreams || {};
    cfg.upstreams["rbx"] = { kind: "stdio", command: SERVE[0], args: [SERVE[1], "serve"], note: "Roblox Studio bridge + verification + computable assets" };
    writeFileSync(gw, JSON.stringify(cfg, null, 2));
    results.clients["agent-harness-gateway"] = { wrote: gw };
  } catch (e) { results.clients["agent-harness-gateway"] = { error: String(e.message || e) }; }

  results.notes.push(
    "Restart your agent client(s) to pick up the server.",
    "Broker autostarts at login (Windows Startup folder) — 127.0.0.1:58420 stays up without any agent running.",
    "Plugin auto-connects with retry + watchdog — no toolbar click needed after Studio restart.",
    "In Roblox Studio: Game Settings → Security → 'Allow HTTP Requests' = ON (once).",
    "Optional upstream routing (official Studio MCP screenshots/play): enable 'Studio as MCP server' in Assistant settings and set upstreams.studio.url in rbx-mcp.config.json.",
  );
  return results;
}

export async function doctor(brokerState) {
  const checks = [];
  const add = (name, ok, detail) => checks.push({ name, ok, detail });
  add("plugin file", existsSync(join(pluginsDir(), "RbxMcp.lua")), pluginsDir());
  add("node >= 18", Number(process.versions.node.split(".")[0]) >= 18, process.versions.node);
  for (const bin of ["selene", "stylua", "luau-lsp"]) {
    const { run } = await import("./localtools.mjs").then(m => m.createLocalTools());
    const r = await run(bin, ["--version"]);
    add(`binary ${bin}`, r.ok, r.ok ? r.stdout.trim().slice(0, 80) : "not on PATH (optional)");
  }
  if (brokerState) add("studio connected", brokerState.instances.length > 0, `${brokerState.instances.length} instance(s)`);
  return checks;
}
