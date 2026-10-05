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
let VANILLA_FILES = [];   // every vanilla file, "client/Vehicles/ISUI/ISVehicleMenu"
function vanillaIndex(pzLua) {
  if (VANILLA) return VANILLA;
  const idx = new Map();
  VANILLA_FILES = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".lua")) {
        const rel = path.relative(pzLua, p).split(path.sep).join("/").replace(/\.lua$/, "");
        VANILLA_FILES.push(rel);
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

// The UI layer a client side boots with (kit uiview/): UIMock's clean-room
// ISUIElement/ISPanel/... stand in for the Java UI, so the vanilla UI tree a
// mod hooks can load on top. Vanilla files defining what it provides are
// skipped, by class and by require name.
const UIVIEW_LUA = path.join(__dirname, "..", "uiview", "media", "lua", "client", "UIView");
const UIVIEW_FILES = ["Recorder", "FontMetrics", "TextureSizes", "UIMock"];
const UI_PROVIDED = ["ISBaseObject", "ISButton", "ISInventoryItem", "ISLabel", "ISPanel", "ISScrollBar", "ISTextEntryBox", "ISUIElement"];
function uiLayer(pzLua) {
  const sources = UIVIEW_FILES.map((n) => ({ name: "UIView/" + n, src: fs.readFileSync(path.join(UIVIEW_LUA, n + ".lua"), "utf8") }));
  const idx = pzLua ? vanillaIndex(pzLua) : new Map();
  const skip = UI_PROVIDED.map((c) => idx.get(c)).filter(Boolean).map((e) => e.file.split("/").slice(1).join("/"));
  return { sources, skip };
}

// ── the auditor ────────────────────────────────────────────────────────────
// Every item ID on every side: the same ID twice on one side is a DUPE; for
// each client, its player's items against the server's copy of that player:
// on the client only (a GHOST the server doesn't have), on the server only
// (MISSING on the client), or both but different (DIVERGED: where it is,
// type, condition, uses, ModData).
// Engine behaviour, not a mod bug: InventoryItem.load calls
// setCustomName(flag) on EVERY load (InventoryItem.java:2070), and the setter
// writes ModData.customName whatever the flag (:3528-3531). So every copy
// that crossed the wire (or was loaded from a save) carries customName and a
// freshly created server copy does not: hasModData() is true on the client,
// false on the server, for the same new item. Compared without it; noted.
const ENGINE_MD = /(^|;)customName=[^;]*/g;
function audit(census) {
  const findings = [];
  const A = (x) => Array.isArray(x) ? x : [];
  for (const [side, c] of Object.entries(census)) {
    const byId = new Map();
    for (const it of A(c.items)) { if (!byId.has(it.id)) byId.set(it.id, []); byId.get(it.id).push(it); }
    for (const [id, list] of byId) if (list.length > 1) findings.push({ kind: "dupe", side, id, type: list[0].type, at: list.map((x) => x.at) });
  }
  const engineNotes = new Set();
  const server = census.server ? A(census.server.items) : [];
  for (const [side, c] of Object.entries(census)) {
    if (side === "server") continue;
    const mine = A(c.items);
    const pids = new Set(mine.map((x) => x.pid));
    if (!pids.size && c.pid != null) pids.add(c.pid);
    const theirs = server.filter((x) => pids.has(x.pid));
    const sById = new Map(theirs.map((x) => [x.id, x]));
    const cById = new Map(mine.map((x) => [x.id, x]));
    for (const [id, x] of cById) {
      const sv = sById.get(id);
      if (!sv) { findings.push({ kind: "ghost", side, id, type: x.type, at: x.at, note: "on " + side + " only: the server has no such item for this player" }); continue; }
      const diff = [];
      for (const k of ["at", "type", "condition", "uses", "md"]) {
        let a = String(sv[k]), b = String(x[k]);
        if (k === "md") {
          const a2 = a.replace(ENGINE_MD, ""), b2 = b.replace(ENGINE_MD, "");
          if (a !== b && a2 === b2) engineNotes.add(id);
          a = a2; b = b2;
        }
        if (a !== b) diff.push({ field: k, server: sv[k], client: x[k] });
      }
      if (diff.length) findings.push({ kind: "diverged", side, id, type: x.type, diff });
    }
    for (const [id, x] of sById) if (!cById.has(id)) findings.push({ kind: "missing", side, id, type: x.type, at: x.at, note: "on the server, never reached " + side });
  }
  if (engineNotes.size) findings.push({ kind: "engine-note", count: engineNotes.size,
    note: "ModData.customName differs on " + engineNotes.size + " item(s): the engine writes it on every load (InventoryItem.java:2070), so a received copy has it and a fresh server copy does not. Not a mod bug; compared without it." });
  return findings;
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
    constructor(mod, ctx, clients, opts) {
      this.mod = mod;
      this.ctx = ctx;
      // full: load EVERY vanilla file of a side's folders in the game's
      // order (LoadDirBase), instead of only the classes the mod names
      // (opt-in: it surfaces a long tail of unexposed Java the targeted mode
      // never touches -- docs/sousvide-mp.md)
      this.full = !!(opts && opts.full === true);
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
      this.audits = [];   // { seq, after, findings }
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
          let ui = { sources: [], skip: [] };
          if (name !== "server") { try { ui = uiLayer(pzLua && fs.existsSync(pzLua) ? pzLua : null); } catch (_) {} }
          if (name !== "server" && ui.skip.length) vanilla = vanilla.filter((f) => !ui.skip.includes(f.split("/").slice(1).join("/")));
          // every vanilla file in this side's folders: in game they ALL run,
          // so a name a mod or vanilla file relies on exists even when its
          // require() misses (the game's require only tries <folder>/<name>)
          const vanillaFiles = VANILLA_FILES.filter((f) => folders.includes(f.split("/")[0]));
          // class -> file for every vanilla class this side runs: a global
          // read of one that isn't loaded yet loads it (80_mp.lua)
          const classes = {};
          if (VANILLA) for (const [cls, e] of VANILLA) {
            if (!folders.includes(e.file.split("/")[0])) continue;
            if (name !== "server" && (UI_PROVIDED.includes(cls) || ui.skip.includes(e.file.split("/").slice(1).join("/")))) continue;
            classes[cls] = e.file;
          }
          const t0 = Date.now();
          const r = await b.call("mpBoot", { clients: this.n, vanilla: this.full ? [] : vanilla, ui: ui.sources, uiSkip: ui.skip, vanillaFiles, classes, full: this.full });
          this.boot[name] = r.value;
          if (r.value && typeof r.value === "object") r.value.mpBootMs = Date.now() - t0;
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
        pkt.to = (p.dir === "up" || p.kind === "clientCommand") ? "server"
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
    // A step on one side: run it, then route what it sent (unless held),
    // then audit every side's items.
    async step(sideName, run) {
      await this.start();
      const res = await run(this.side(sideName));
      await this.collect(sideName, "step");
      const flushed = this.hold ? { delivered: 0, queued: this.queue.length } : await this.flush();
      const a = await this.audit("step on " + sideName);
      return { result: res, pass: flushed, audit: a.findings };
    }
    async audit(after) {
      const census = {};
      for (const [name, b] of this.sides()) {
        try { census[name] = (await b.call("mpCensus", {})).value; }
        catch (e) { census[name] = { error: e.message, items: [] }; }
      }
      const findings = audit(census);
      const entry = { seq: this.seq, after, findings, queued: this.queue.length };
      this.audits.push(entry);
      if (this.audits.length > 500) this.audits.shift();
      this.lastCensus = census;
      return entry;
    }
    status() {
      return {
        mod: this.mod.id, state: this.state, error: this.error || null, clients: this.n, hold: this.hold, full: this.full,
        queued: this.queue.length, packets: this.seq, boot: this.boot,
        sides: this.sides().map(([name, b]) => ({ side: name, state: b.state, error: b.error, bootMs: b.bootMs || null })),
      };
    }
  }

  function sessionFor(mod, ctx, clients, opts) {
    let s = sessions.get(mod.id);
    if (!s || s.state === "dead" || (clients && clients !== s.n && s.state !== "ready")) {
      if (s) s.stop();
      s = new Session(mod, ctx, clients, opts);
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
        const s = sessionFor(mod, ctx, body.clients, { full: body.full });
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
        r.audit = (await s.audit(body.drop ? "drop" : body.dup ? "duplicate" : "deliver")).findings;
        json(res, 200, r);
        return true;
      }
      if (action === "census") {
        const a = await s.audit("census");
        json(res, 200, { census: s.lastCensus, findings: a.findings });
        return true;
      }
      if (action === "pass") {
        const since = +(url.searchParams.get("since") || 0);
        const last = s.audits[s.audits.length - 1];
        json(res, 200, { packets: s.log.filter((e) => e.seq > since), queued: s.queue, hold: s.hold,
                         audit: last ? last.findings : [], auditAfter: last ? last.after : null });
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
