// SousVide MP: one server bridge and N client bridges per mod, and the Pass
// between them (docs/sousvide-mp.md).
//
// Each side is an ordinary SousVide bridge booted with --role. The sides
// never talk to each other: every packet a side sends (workbench/80_mp.lua
// turns the network globals into packets, payloads as real TableNetworkUtils
// bytes) is drained here after each step, logged, and delivered to the
// receiving side(s) in order. "hold" stops delivery so a test can step it,
// drop a packet or deliver it twice -- races are where dupes come from.
//
//   POST /api/mp/<mod>/start   {clients}      boot the sides (server + c1..cN)
//   GET  /api/mp/<mod>/status
//   POST /api/mp/<mod>/stop
//   POST /api/mp/<mod>/eval    {side, lua}    side: "server" | "c1" | "c2"...
//   POST /api/mp/<mod>/call    {side, tool, args}
//   POST /api/mp/<mod>/hold    {on}
//   POST /api/mp/<mod>/pump    {n?, drop?, dup?}   deliver queued packets
//   GET  /api/mp/<mod>/pass?since=N            the packet log

"use strict";
const fs = require("fs");
const path = require("path");

// ── vanilla classes a mod leans on ─────────────────────────────────────────
// In game every vanilla Lua file runs before any mod. Headless, loading all
// of it is slow and mostly UI that cannot run, so a side loads the vanilla
// files that DEFINE the classes its mod code names (parents first), in the
// folders that side runs. Index: class -> { file, parent }, from a scan of
// the install's media/lua (top-level `X = Parent:derive(...)` / `X = {}`).
let VANILLA = null;
function vanillaIndex(pzLua) {
  if (VANILLA) return VANILLA;
  const idx = new Map();
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".lua")) {
        const rel = path.relative(pzLua, p).split(path.sep).join("/").replace(/\.lua$/, "");
        const text = fs.readFileSync(p, "utf8");
        for (const m of text.matchAll(/^([A-Z][A-Za-z0-9_]*)\s*=\s*(?:([A-Za-z0-9_.]+):derive\s*\(|\{\s*\}|\1\s+or\s+\{)/gm)) {
          if (!idx.has(m[1])) idx.set(m[1], { file: rel, parent: m[2] || null });
        }
      }
    }
  };
  for (const f of ["shared", "client", "server"]) if (fs.existsSync(path.join(pzLua, f))) walk(path.join(pzLua, f));
  VANILLA = idx;
  return idx;
}

// Vanilla files a side needs for this mod: classes its code names, defined in
// a folder the side runs, with their derive parents ahead of them.
function vanillaFor(modFiles, folders, pzLua) {
  const idx = vanillaIndex(pzLua);
  const tokens = new Set();
  for (const f of modFiles) {
    const rel = f.split(path.sep).join("/");
    const m = /\/media\/lua\/(\w+)\//.exec(rel);
    if (!m || !folders.includes(m[1]) || rel.includes("/Tests/")) continue;
    for (const t of fs.readFileSync(f, "utf8").match(/\b[A-Z][A-Za-z0-9_]{3,}\b/g) || []) tokens.add(t);
  }
  const out = [], seen = new Set();
  const add = (cls, depth) => {
    const e = idx.get(cls);
    if (!e || seen.has(cls) || depth > 12) return;
    if (!folders.includes(e.file.split("/")[0])) return;
    seen.add(cls);
    if (e.parent) add(e.parent.split(".")[0], depth + 1);
    if (!out.includes(e.file)) out.push(e.file);
  };
  for (const t of tokens) add(t, 0);
  // shared before client before server, parents already ahead within each
  const rank = (f) => folders.indexOf(f.split("/")[0]);
  return out.map((f, i) => [f, i]).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map(([f]) => f);
}

function modLuaFiles(root) {
  const out = [];
  const walk = (d) => {
    if (!fs.existsSync(d)) return;
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p); else if (e.name.endsWith(".lua")) out.push(p);
    }
  };
  walk(path.join(root, "media", "lua"));
  return out;
}

module.exports = function makeMp({ Bridge, luaLit, json, readBody }) {
  const sessions = new Map();   // modId -> Session
  // Lua's JSON can't tell [] from {} for an empty table.
  const arr = (x) => Array.isArray(x) ? x : [];
  const STORM = 300;            // packets delivered by one flush before we call it a storm

  class Session {
    constructor(mod, ctx, clients) {
      this.mod = mod;
      this.ctx = ctx;
      this.n = Math.max(1, Math.min(4, clients || 1));
      this.server = new Bridge(mod, ctx, { role: "server" });
      this.clients = [];
      for (let i = 1; i <= this.n; i++) this.clients.push(new Bridge(mod, ctx, { role: "client", index: i }));
      this.queue = [];
      this.log = [];
      this.seq = 0;
      this.hold = false;
      this.boot = {};
      this.state = "idle";
    }
    sides() { return [["server", this.server], ...this.clients.map((b, i) => ["c" + (i + 1), b])]; }
    side(name) {
      if (name === "server") return this.server;
      const m = /^c(\d+)$/.exec(name || "");
      const b = m && this.clients[+m[1] - 1];
      if (!b) throw new Error("no side " + name + " (server, c1.." + "c" + this.n + ")");
      return b;
    }
    async start() {
      if (this.state === "ready" || this.state === "booting") return this.ready;
      this.state = "booting";
      this.ready = (async () => {
        // All sides boot in parallel; each is a JVM.
        await Promise.all(this.sides().map(([, b]) => b.whenReady()));
        // The PZ install the VMs adopted (PzLocator), for the vanilla index.
        const pzDir = (await this.server.rawEval("return _pz_install_dir or ''")).value;
        const pzLua = pzDir ? path.join(pzDir, "media", "lua") : null;
        const files = modLuaFiles(this.mod.root);
        for (const [name, b] of this.sides()) {
          const folders = name === "server" ? ["shared", "server"] : ["shared", "client", "server"];
          let vanilla = [];
          try { if (pzLua && fs.existsSync(pzLua)) vanilla = vanillaFor(files, folders, pzLua); } catch (_) {}
          const r = await b.call("mpBoot", { clients: this.n, vanilla });
          this.boot[name] = r.value;
        }
        this.state = "ready";
        // Start events can send (a client announcing itself): route them.
        for (const [name] of this.sides()) await this.collect(name, "boot");
        if (!this.hold) await this.flush();
      })().catch((e) => { this.state = "dead"; this.error = e.message; throw e; });
      return this.ready;
    }
    stop() { for (const [, b] of this.sides()) b.stop(); this.state = "dead"; }

    // Drain a side's outbox into the queue.
    async collect(from, cause) {
      const r = await this.side(from).call("mpDrain", {});
      for (const p of arr(r.value && r.value.packets)) {
        const pkt = { seq: ++this.seq, from, cause, ...p };
        pkt.to = p.kind === "clientCommand" ? "server"
          : p.target ? "c" + p.target
          : "all";
        this.queue.push(pkt);
      }
    }
    // Deliver one packet; returns the log entry.
    async deliver(pkt) {
      const targets = pkt.to === "all" ? this.clients.map((_, i) => "c" + (i + 1)) : [pkt.to];
      const entry = { ...pkt, delivered: [] };
      for (const t of targets) {
        let side;
        try { side = this.side(t); }
        catch (e) { entry.delivered.push({ to: t, undeliverable: e.message }); continue; }
        let r;
        try { r = (await side.call("mpDeliver", { packet: pkt })).value; }
        catch (e) { r = { error: e.message }; }
        entry.delivered.push({ to: t, ...r });
        await this.collect(t, "seq " + pkt.seq);
      }
      this.log.push(entry);
      if (this.log.length > 2000) this.log.splice(0, this.log.length - 2000);
      return entry;
    }
    async flush(max) {
      let n = 0;
      const limit = max == null ? STORM : max;
      while (this.queue.length && n < limit) { await this.deliver(this.queue.shift()); n++; }
      const storm = max == null && this.queue.length > 0;
      if (storm) this.log.push({ seq: ++this.seq, kind: "storm", note: `${STORM} packets delivered and the queue is still not empty: a command loop? (${this.queue.length} held)` });
      return { delivered: n, queued: this.queue.length, storm };
    }
    // A step on one side: run it, then route what it sent (unless held).
    async step(sideName, run) {
      await this.start();
      const res = await run(this.side(sideName));
      await this.collect(sideName, "step");
      const flushed = this.hold ? { delivered: 0, queued: this.queue.length } : await this.flush();
      return { result: res, pass: flushed };
    }
    status() {
      return {
        mod: this.mod.id, state: this.state, error: this.error || null, clients: this.n, hold: this.hold,
        queued: this.queue.length, packets: this.seq, boot: this.boot,
        sides: this.sides().map(([name, b]) => ({ side: name, state: b.state, error: b.error, bootMs: b.bootMs || null })),
      };
    }
  }

  function sessionFor(mod, ctx, clients) {
    let s = sessions.get(mod.id);
    if (!s || s.state === "dead" || (clients && clients !== s.n && s.state !== "ready")) {
      if (s) s.stop();
      s = new Session(mod, ctx, clients);
      sessions.set(mod.id, s);
    }
    return s;
  }

  async function handle(req, res, url, ctx) {
    const parts = url.pathname.split("/").filter(Boolean);   // api mp <modId> <action>
    const mod = ctx.modById(parts[2]);
    if (!mod) { json(res, 404, { error: "unknown mod" }); return true; }
    const action = parts[3];
    try {
      if (action === "start" && req.method === "POST") {
        const body = await readBody(req);
        const s = sessionFor(mod, ctx, body.clients);
        await s.start();
        json(res, 200, s.status());
        return true;
      }
      const s = sessions.get(mod.id);
      if (action === "status") { json(res, 200, s ? s.status() : { mod: mod.id, state: "idle" }); return true; }
      if (!s) { json(res, 409, { error: "no MP session for " + mod.id + ": POST /api/mp/" + mod.id + "/start first" }); return true; }
      if (action === "stop" && req.method === "POST") { s.stop(); sessions.delete(mod.id); json(res, 200, { ok: true }); return true; }
      if (action === "eval" && req.method === "POST") {
        const body = await readBody(req);
        const r = await s.step(body.side || "server", async (b) => {
          await b.whenReady();
          const out = await b.rawEval(body.lua);
          return { value: out.value, out: out.out };
        });
        json(res, 200, r);
        return true;
      }
      if (action === "call" && req.method === "POST") {
        const body = await readBody(req);
        const r = await s.step(body.side || "server", (b) => b.call(body.tool, body.args || {}));
        json(res, 200, r);
        return true;
      }
      if (action === "hold" && req.method === "POST") {
        const body = await readBody(req);
        s.hold = !!body.on;
        json(res, 200, s.status());
        return true;
      }
      if (action === "pump" && req.method === "POST") {
        // {n} deliver the next n (default all); {drop: true} discard the
        // next packet; {dup: true} deliver the next packet twice.
        const body = await readBody(req);
        let r;
        if (body.drop) {
          const p = s.queue.shift();
          if (p) s.log.push({ ...p, dropped: true });
          r = { dropped: p ? p.seq : null, queued: s.queue.length };
        } else if (body.dup) {
          const p = s.queue.shift();
          if (p) { await s.deliver(p); await s.deliver({ ...p, duplicate: true }); }
          r = { duplicated: p ? p.seq : null, queued: s.queue.length };
        } else {
          r = await s.flush(body.n);
        }
        json(res, 200, r);
        return true;
      }
      if (action === "pass") {
        const since = +(url.searchParams.get("since") || 0);
        json(res, 200, { packets: s.log.filter((e) => e.seq > since), queued: s.queue, hold: s.hold });
        return true;
      }
      json(res, 404, { error: "unknown mp action " + action });
    } catch (e) {
      json(res, 500, { error: e.message });
    }
    return true;
  }

  return { handle, sessions };
};
