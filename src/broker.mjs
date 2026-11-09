#!/usr/bin/env node
// Localhost broker between the rbx-mcp server and the Roblox Studio plugin.
//
// Design (distilled from Roblox/studio-rust-mcp-server + studio-bridge):
// - Studio plugin long-polls POST /v1/poll {studioId} (holds ~25s).
// - Commands are leased EXACTLY ONCE. A delivered command is never re-delivered;
//   if Studio dies mid-command you get a clear error, not a duplicate mutation.
// - Large results can arrive chunked; the broker reassembles before resolving.
// - Bound to 127.0.0.1 only. No auth — loopback is the trust boundary.

import http from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_PORT = 58420;

export function createBroker({ port = DEFAULT_PORT, staticDir = join(__dirname, "..", "ui") } = {}) {
  const instances = new Map();   // studioId -> { place, version, lastSeen, caps }
  const queues = new Map();      // studioId -> Array<cmd>
  const leases = new Map();      // lease -> { studioId, resolve, reject, timer, chunks, expected }
  const recent = [];             // ring buffer of call log entries
  let seq = 0;

  const log = (entry) => {
    entry.t = new Date().toISOString();
    recent.push(entry);
    if (recent.length > 300) recent.shift();
  };

  function enqueue(studioId, cmd, args, timeoutMs = 90000) {
    const inst = instances.get(studioId);
    if (!inst) return Promise.reject(new Error(`studio '${studioId}' not connected. Use rbx_studios to list connected instances.`));
    const id = ++seq;
    const lease = `${id}.${Math.random().toString(36).slice(2)}`;
    const p = new Promise((resolve, reject) => {
      leases.set(lease, {
        studioId, id, cmd,
        resolve, reject,
        chunks: new Map(), expected: null,
        timer: setTimeout(() => {
          leases.delete(lease);
          reject(new Error(`command '${cmd}' timed out after ${timeoutMs}ms in Studio (never re-delivered — check Studio is not frozen)`));
        }, timeoutMs),
      });
    });
    (queues.get(studioId) ?? queues.set(studioId, []).get(studioId)).push({ id, lease, cmd, args });
    log({ dir: "queue", studioId, cmd });
    return p;
  }

  function complete(leaseKey, ok, payload) {
    const l = leases.get(leaseKey);
    if (!l) return { accepted: false, reason: "unknown or expired lease" };
    leases.delete(leaseKey);
    clearTimeout(l.timer);
    log({ dir: "result", studioId: l.studioId, cmd: l.cmd, ok });
    ok ? l.resolve(payload) : l.reject(new Error(typeof payload === "string" ? payload : JSON.stringify(payload)));
    return { accepted: true };
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      req.on("data", c => chunks.push(c));
      req.on("end", () => { try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}); } catch (e) { reject(e); } });
      req.on("error", reject);
    });
  }

  const server = http.createServer(async (req, res) => {
    const send = (code, obj, headers = {}) => {
      res.writeHead(code, { "content-type": "application/json", "cache-control": "no-store", ...headers });
      res.end(typeof obj === "string" ? obj : JSON.stringify(obj));
    };
    const url = new URL(req.url, "http://localhost");
    try {
      if (req.method === "POST" && url.pathname === "/v1/hello") {
        const b = await readBody(req);
        instances.set(b.studioId, {
          place: b.place, placeId: b.placeId, version: b.version,
          caps: b.caps || [], connectedAt: new Date().toISOString(), lastSeen: Date.now(),
        });
        log({ dir: "hello", studioId: b.studioId });
        return send(200, { ok: true });
      }
      if (req.method === "POST" && url.pathname === "/v1/poll") {
        const b = await readBody(req);
        const inst = instances.get(b.studioId);
        if (!inst) return send(404, { error: "unknown studioId — call /v1/hello first" });
        inst.lastSeen = Date.now();
        const q = queues.get(b.studioId) || [];
        if (q.length) return send(200, q.shift());
        // long-poll: hold up to 25s waiting for work
        const deadline = Date.now() + 25000;
        const iv = setInterval(() => {
          const qq = queues.get(b.studioId) || [];
          if (qq.length) { clearInterval(iv); send(200, qq.shift()); }
          else if (Date.now() > deadline || res.writableEnded) { clearInterval(iv); if (!res.writableEnded) send(204, {}); }
        }, 50);
        req.on("close", () => clearInterval(iv));
        return;
      }
      if (req.method === "POST" && url.pathname === "/v1/result") {
        const b = await readBody(req);
        if (b.chunk !== undefined && b.total !== undefined) {
          const l = leases.get(b.lease);
          if (!l) return send(200, { accepted: false, reason: "expired lease" });
          l.chunks.set(b.chunk, b.data ?? "");
          l.expected = b.total;
          if (l.chunks.size === l.expected) {
            const full = [...Array(l.expected).keys()].map(i => l.chunks.get(i)).join("");
            return send(200, complete(b.lease, b.ok !== false, tryJson(full)));
          }
          return send(200, { accepted: true, partial: l.chunks.size + "/" + l.expected });
        }
        return send(200, complete(b.lease, b.ok !== false, b.result));
      }
      if (req.method === "GET" && url.pathname === "/api/state") {
        return send(200, {
          now: Date.now(),
          instances: [...instances.entries()].map(([id, i]) => ({ studioId: id, ...i })),
          pending: [...leases.values()].map(l => ({ id: l.id, studioId: l.studioId, cmd: l.cmd })),
          queues: [...queues.entries()].map(([id, q]) => ({ studioId: id, depth: q.length })),
          recent: recent.slice(-80),
        });
      }
      if (req.method === "POST" && url.pathname === "/api/command") {
        const b = await readBody(req);
        const r = await enqueue(b.studioId, b.cmd, b.args || {}, b.timeoutMs || 90000)
          .then(result => ({ ok: true, result }))
          .catch(e => ({ ok: false, error: String(e.message || e) }));
        return send(202, r);
      }
      if (req.method === "POST" && url.pathname === "/api/install-plugin") {
        const { installPlugin } = await import("./install.mjs");
        return send(200, installPlugin());
      }
      if (req.method === "POST" && url.pathname === "/api/install") {
        const { install } = await import("./install.mjs");
        return send(200, install({}));
      }
      if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
        const f = join(staticDir, "index.html");
        if (existsSync(f)) {
          res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
          return res.end(readFileSync(f));
        }
        return send(404, { error: "ui not found" });
      }
      send(404, { error: `no route ${req.method} ${url.pathname}` });
    } catch (e) {
      send(500, { error: String(e?.message || e) });
    }
  });

  return {
    enqueue,
    listInstances: () => [...instances.keys()],
    state: () => ({
      instances: [...instances.entries()].map(([id, i]) => ({ studioId: id, ...i })),
      pending: [...leases.values()].map(l => ({ id: l.id, studioId: l.studioId, cmd: l.cmd })),
      recent: recent.slice(-50),
    }),
    start: () => new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve(port))),
    stop: () => server.close(),
    server,
  };
}

function tryJson(s) { try { return JSON.parse(s); } catch { return s; } }

// ---------------------------------------------------------------------------
// remoteBroker: same interface as createBroker, but talks to an ALREADY-RUNNING
// broker over HTTP. Lets `serve` attach to the autostarted system broker
// instead of failing to bind the port — the broker is a system service, the
// MCP server is just a client-facing adapter.
// ---------------------------------------------------------------------------
export function remoteBroker(port = DEFAULT_PORT) {
  const base = `http://127.0.0.1:${port}`;
  return {
    _remote: true,
    enqueue: async (studioId, cmd, args, timeoutMs = 90000) => {
      const res = await fetch(base + "/api/command", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ studioId, cmd, args, timeoutMs }),
        signal: AbortSignal.timeout(timeoutMs + 10000),
      });
      const body = await res.json();
      if (!body.ok) throw new Error(body.error || "command failed");
      return body.result;
    },
    listInstances: async () => (await (await fetch(base + "/api/state")).json()).instances.map(i => i.studioId),
    state: async () => (await (await fetch(base + "/api/state")).json()),
    start: async () => port,   // already running
    stop: () => {},            // not ours to stop
    isAlive: async () => {
      try { const r = await fetch(base + "/api/state", { signal: AbortSignal.timeout(800) }); return r.ok; }
      catch { return false; }
    },
  };
}
