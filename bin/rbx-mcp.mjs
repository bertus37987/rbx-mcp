#!/usr/bin/env node
// rbx-mcp — CLI + entry point.
//   rbx-mcp serve      stdio MCP server + broker (what agents spawn)
//   rbx-mcp broker     run broker alone (dashboard at http://127.0.0.1:58420)
//   rbx-mcp install    copy plugin + write client MCP configs
//   rbx-mcp doctor     environment checks
//   rbx-mcp plugin     print plugin path

import { createBroker, remoteBroker, DEFAULT_PORT } from "../src/broker.mjs";
import { createRouter, loadConfig } from "../src/router.mjs";
import { buildTools } from "../src/tools.mjs";
import { createLocalTools } from "../src/localtools.mjs";
import { createMcpServer } from "../src/mcp.mjs";
import { install, doctor, installPlugin } from "../src/install.mjs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(__dirname, "..");
const cmd = process.argv[2] || "serve";

const shutdown = (fn) => { let done = false; const h = () => { if (done) return; done = true; fn(); process.exit(0); }; process.on("SIGINT", h); process.on("SIGTERM", h); };

if (cmd === "serve") {
  const config = loadConfig();
  const port = config.port || DEFAULT_PORT;
  // Prefer the autostarted system broker — attach via HTTP if it's up.
  // Falls back to an embedded broker when rbx-mcp runs standalone.
  let broker = remoteBroker(port);
  if (await broker.isAlive()) {
    process.stderr.write(`[rbx-mcp] attached to system broker on 127.0.0.1:${port}\n`);
  } else {
    broker = createBroker({ port });
    await broker.start();
    shutdown(() => { try { broker.stop(); } catch {} });
    process.stderr.write(`[rbx-mcp] embedded broker on 127.0.0.1:${port} — dashboard http://127.0.0.1:${port}/\n`);
  }
  const router = await createRouter(config);
  const local = createLocalTools();
  const tools = [...buildTools({ broker, router, local }), ...router.listTools()];
  createMcpServer({ name: "rbx-mcp", version: "0.1.0", tools });
} else if (cmd === "broker") {
  const config = loadConfig();
  const broker = createBroker({ port: config.port || DEFAULT_PORT });
  const p = await broker.start();
  shutdown(() => { try { broker.stop(); } catch {} });
  console.log(`[rbx-mcp] broker listening on http://127.0.0.1:${p}/ — dashboard ready`);
} else if (cmd === "install") {
  const r = install({});
  console.log(JSON.stringify(r, null, 2));
} else if (cmd === "install-plugin") {
  console.log(JSON.stringify(installPlugin(), null, 2));
} else if (cmd === "doctor") {
  console.log(JSON.stringify(await doctor(null), null, 2));
} else if (cmd === "plugin") {
  console.log(join(PKG_ROOT, "plugin", "RbxMcp.lua"));
} else {
  console.error("usage: rbx-mcp <serve|broker|install|install-plugin|doctor|plugin>");
  process.exit(1);
}
