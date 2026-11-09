#!/usr/bin/env node
// Zero-dep MCP stdio server + MCP client helpers.
// Protocol: newline-delimited JSON-RPC 2.0 on stdin/stdout (MCP stdio transport).
// Only stdout carries protocol frames; diagnostics go to stderr.

const PROTOCOL_VERSION = "2024-11-05";

export function createMcpServer({ name, version, tools = [], resources = [], prompts = [], callTool }) {
  const toolMap = new Map(tools.map(t => [t.name, t]));
  const resMap = new Map(resources.map(r => [r.uri, r]));
  const promptMap = new Map(prompts.map(p => [p.name, p]));

  function send(msg) {
    process.stdout.write(JSON.stringify(msg) + "\n");
  }
  function reply(id, result) {
    send({ jsonrpc: "2.0", id, result });
  }
  function replyError(id, code, message, data) {
    const err = { code, message };
    if (data !== undefined) err.data = data;
    send({ jsonrpc: "2.0", id, error: err });
  }

  async function handle(msg) {
    const { id, method, params } = msg;
    if (!method) return;
    if (id === undefined) return; // notifications: ignore
    try {
      switch (method) {
        case "initialize":
          reply(id, {
            protocolVersion: PROTOCOL_VERSION,
            capabilities: {
              tools: { listChanged: false },
              resources: resources.length ? { subscribe: false, listChanged: false } : undefined,
              prompts: prompts.length ? { listChanged: false } : undefined,
            },
            serverInfo: { name, version },
            instructions:
              "rbx-mcp drives Roblox Studio through a local plugin. Always pass studio_id from rbx_studios. " +
              "Write tools auto-checkpoint (undo via Studio Edit>Undo). Verify changes with rbx_snapshot/rbx_diff " +
              "and screenshots via studio.* upstream tools when connected.",
          });
          return;
        case "ping":
          reply(id, {});
          return;
        case "tools/list":
          reply(id, { tools: tools.map(({ name: n, description, inputSchema, annotations }) => ({ name: n, description, inputSchema, annotations })) });
          return;
        case "tools/call": {
          const t = toolMap.get(params?.name);
          if (!t) return replyError(id, -32602, `unknown tool: ${params?.name}`);
          const res = t.handler
            ? await t.handler(params.arguments || {})
            : await callTool(params.name, params.arguments || {});
          reply(id, normalizeToolResult(res));
          return;
        }
        case "resources/list":
          reply(id, { resources: resources.map(({ handler, ...meta }) => meta) });
          return;
        case "resources/read": {
          const r = resMap.get(params?.uri);
          if (!r || !r.handler) return replyError(id, -32602, `unknown resource: ${params?.uri}`);
          const text = await r.handler();
          reply(id, { contents: [{ uri: r.uri, mimeType: r.mimeType || "text/markdown", text }] });
          return;
        }
        case "prompts/list":
          reply(id, { prompts: prompts.map(({ handler, ...meta }) => meta) });
          return;
        case "prompts/get": {
          const p = promptMap.get(params?.name);
          if (!p) return replyError(id, -32602, `unknown prompt: ${params?.name}`);
          reply(id, await p.handler(params?.arguments || {}));
          return;
        }
        case "shutdown":
          reply(id, {});
          return;
        case "exit":
          process.exit(0);
          return;
        default:
          replyError(id, -32601, `method not found: ${method}`);
      }
    } catch (e) {
      replyError(id, -32603, String(e?.message || e), e?.data);
    }
  }

  let buf = "";
  process.stdin.on("data", chunk => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; } // tolerate noise
      handle(msg);
    }
  });
  process.stdin.on("end", () => process.exit(0));
  process.stdin.resume();
}

function normalizeToolResult(res) {
  if (res && typeof res === "object" && Array.isArray(res.content)) return res;
  if (typeof res === "string") return { content: [{ type: "text", text: res }] };
  return { content: [{ type: "text", text: JSON.stringify(res, null, 2) }], structuredContent: res };
}

// ---------------------------------------------------------------------------
// MCP stdio CLIENT (for upstream stdio servers). Zero-dep NDJSON client.
// ---------------------------------------------------------------------------
import { spawn } from "node:child_process";

export function connectStdioUpstream({ command, args = [], env = {}, name = "upstream" }) {
  const child = spawn(command, args, { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "inherit"] });
  const pending = new Map();
  let nextId = 1;
  let buf = "";

  const ready = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.stdout.on("data", chunk => {
      buf += chunk;
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id !== undefined && pending.has(msg.id)) {
          const { resolve: res, reject: rej, timer } = pending.get(msg.id);
          pending.delete(msg.id);
          clearTimeout(timer);
          msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
        }
      }
    });
    rpc("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "rbx-mcp-router", version: "0.1.0" },
    }).then(r => {
      sendNotify("notifications/initialized", {});
      resolve(r);
    }).catch(reject);
  });

  function send(frame) {
    if (!child.stdin.writable) throw new Error(`upstream ${name} stdin closed`);
    child.stdin.write(JSON.stringify(frame) + "\n");
  }
  function sendNotify(method, params) {
    send({ jsonrpc: "2.0", method, params });
  }
  function rpc(method, params, timeoutMs = 30000) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`upstream ${name} timeout on ${method}`));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      send({ jsonrpc: "2.0", id, method, params });
    });
  }

  return {
    name,
    ready,
    rpc,
    tools: async () => (await rpc("tools/list")).tools || [],
    call: (tool, args) => rpc("tools/call", { name: tool, arguments: args }, 120000),
    close: () => child.kill(),
  };
}

// ---------------------------------------------------------------------------
// MCP streamable-HTTP CLIENT (for upstream HTTP servers, e.g. Studio's built-in
// MCP endpoint, forgegui.net/mcp). Implements POST JSON-RPC + SSE response parse.
// ---------------------------------------------------------------------------
export function connectHttpUpstream({ url, headers = {}, name = "http-upstream" }) {
  let sessionId = null;
  let nextId = 1;

  async function rpc(method, params, timeoutMs = 60000) {
    const id = method.startsWith("notifications/") ? undefined : nextId++;
    const frame = { jsonrpc: "2.0", method, params };
    if (id !== undefined) frame.id = id;
    const h = {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      ...headers,
    };
    if (sessionId) h["mcp-session-id"] = sessionId;
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeoutMs);
    try {
      const res = await fetch(url, { method: "POST", headers: h, body: JSON.stringify(frame), signal: ac.signal });
      const sid = res.headers.get("mcp-session-id");
      if (sid) sessionId = sid;
      if (id === undefined) return {};
      const ct = res.headers.get("content-type") || "";
      if (ct.includes("text/event-stream")) {
        const text = await res.text();
        let last = null;
        for (const line of text.split(/\r?\n/)) {
          if (!line.startsWith("data:")) continue;
          try {
            const m = JSON.parse(line.slice(5).trim());
            if (m.id === id) last = m;
          } catch {}
        }
        if (!last) throw new Error(`no SSE response frame for id ${id}`);
        if (last.error) throw new Error(last.error.message);
        return last.result;
      }
      const msg = await res.json();
      if (msg.error) throw new Error(msg.error.message);
      return msg.result;
    } finally {
      clearTimeout(timer);
    }
  }

  const ready = rpc("initialize", {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: {},
    clientInfo: { name: "rbx-mcp-router", version: "0.1.0" },
  }).then(r => rpc("notifications/initialized", {}).then(() => r));

  return {
    name,
    ready,
    rpc,
    tools: async () => (await rpc("tools/list")).tools || [],
    call: (tool, args) => rpc("tools/call", { name: tool, arguments: args }, 120000),
    close: () => {},
  };
}
