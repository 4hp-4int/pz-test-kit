/*
 * PZ Test Kit — Engine Workbench (server side)
 * =============================================
 * One resident `pztest --bridge` VM per mod, booted lazily, reused across
 * requests, killed after IDLE_MS. Every tool is a Lua function registered in
 * dashboard/workbench/*.lua (loaded into the VM after boot); the browser calls
 * them by name and gets JSON back. Same b64 line protocol as vps-story's
 * designer: one base64 chunk per line in, `@@OK@@<b64>` / `@@ERR@@<b64>` out.
 *
 * Mounted from server.js:  if (await workbench.handle(req, res, url, ctx)) return;
 * ctx = { mods, modById, KIT, bashPath }
 */
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const HERE = __dirname;
const LUA_DIR = path.join(HERE, "workbench");
const IDLE_MS = 10 * 60 * 1000;
const BOOT_TIMEOUT_MS = 180 * 1000;
const CALL_TIMEOUT_MS = 120 * 1000;

const bridges = new Map();   // modId -> Bridge
const KIT_ROOT = path.resolve(HERE, "..");

// Addon files for a mod's VM: dashboard/workbench/addons/*.lua, then
// <mod>/workbench/*.lua, then each pz-test.lua dependency's workbench/*.lua.
// Mod-owned addons live outside media/, so deploy.ps1 never ships them.
// The mod's pz-test.lua `dependencies` roots (sibling mods it loads).
function depRoots(mod) {
  try {
    const cfg = fs.readFileSync(path.join(mod.root, "pz-test.lua"), "utf8").replace(/--[^\n]*/g, "");
    const block = (cfg.match(/\bdependencies\s*=\s*\{([\s\S]*?)\}/) || [])[1] || "";
    return [...block.matchAll(/"([^"]+)"|'([^']+)'/g)].map((m) => path.resolve(mod.root, m[1] || m[2]));
  } catch (_) { return []; }
}

function addonFiles(mod) {
  const dirs = [path.join(LUA_DIR, "addons"), path.join(mod.root, "workbench")];
  for (const r of depRoots(mod)) dirs.push(path.join(r, "workbench"));
  const seen = new Set(), out = [];
  for (const d of dirs) {
    const k = path.resolve(d).toLowerCase();
    if (seen.has(k) || !fs.existsSync(d)) continue;
    seen.add(k);
    for (const f of fs.readdirSync(d).filter((x) => x.endsWith(".lua")).sort()) out.push(path.join(d, f));
  }
  return out;
}

// ── script source index ────────────────────────────────────────────────────
// The engine parses scripts into objects, but some of those objects' classes
// are not Lua-exposed in engine mode (OutputScript, OutputMapper...), and the
// raw text is what you want when studying a recipe anyway. So index the
// source blocks off disk: vanilla media/scripts, then the mod's (mod wins,
// same as the game's same-path replacement).
function pzInstall() {
  const cands = [process.env.PZ_INSTALL_DIR, "C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid",
                 "D:/SteamLibrary/steamapps/common/ProjectZomboid"].filter(Boolean);
  return cands.find((c) => fs.existsSync(path.join(c, "media", "scripts"))) || null;
}

function walk(dir, out) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith(".txt")) out.push(p);
  }
  return out;
}

// Brace-matched blocks of `<kind> <Name> { ... }` inside `module X { ... }`.
const KINDS = new Set(["craftRecipe", "item", "fixing", "evolvedrecipe", "entity"]);
function parseScriptFile(file, into, origin) {
  let text;
  try { text = fs.readFileSync(file, "utf8"); } catch (_) { return; }
  const clean = text.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  const re = /\b(module|craftRecipe|item|fixing|evolvedrecipe|entity)\s+([A-Za-z0-9_.\- ]+?)\s*\{/g;
  let module = "Base", moduleEnd = -1, m;
  while ((m = re.exec(clean))) {
    const kind = m[1], name = m[2].trim();
    const open = m.index + m[0].length - 1;
    let depth = 0, i = open;
    for (; i < clean.length; i++) {
      if (clean[i] === "{") depth++;
      else if (clean[i] === "}") { depth--; if (depth === 0) break; }
    }
    if (kind === "module") { module = name; moduleEnd = i; continue; }   // descend into it
    if (m.index > moduleEnd && moduleEnd >= 0) module = "Base";
    if (!KINDS.has(kind)) continue;
    const full = (name.includes(".") ? name : module + "." + name);
    const line = text.slice(0, m.index).split("\n").length;
    // Every definition, in load order: mods commonly REDEFINE a vanilla
    // recipe with a partial block (just OnCreate/OnTest), which the engine
    // merges onto the original — so a study view needs all of them.
    const key = kind + ":" + full.toLowerCase();
    (into[key] = into[key] || []).push({ kind, full, file: file.replace(/\\/g, "/"), line, origin, text: text.slice(m.index, i + 1) });
    re.lastIndex = i + 1;
  }
}

function recipeOutputs(src) {
  const outBlock = /\boutputs\s*\{([\s\S]*?)\n\s*\}/.exec(src);
  if (!outBlock) return [];
  const mappers = {};
  const mre = /\bitemMapper\s+(\w+)\s*\{([\s\S]*?)\}/g;
  let mm;
  while ((mm = mre.exec(src))) {
    mappers[mm[1]] = [...mm[2].matchAll(/([\w.]+)\s*=\s*[\w.:]+/g)].map((x) => x[1]).filter((x) => x !== "default");
  }
  const types = [];
  for (const l of outBlock[1].split("\n")) {
    const im = /^\s*item\s+\d+(?:\s+\[?[\w.]*\]?)?\s+(?:mapper:(\w+)|([\w.]+))/.exec(l);
    if (!im) continue;
    if (im[1]) types.push(...(mappers[im[1]] || []));
    else types.push(im[2].includes(".") ? im[2] : "Base." + im[2]);
  }
  return [...new Set(types)];
}

const scriptCache = new Map();   // mod root -> { byKey, outputs }
function scriptIndex(mod) {
  if (scriptCache.has(mod.root)) return scriptCache.get(mod.root);
  const byKey = {};
  const pz = pzInstall();
  if (pz) for (const f of walk(path.join(pz, "media", "scripts"), [])) parseScriptFile(f, byKey, "vanilla");
  for (const f of walk(path.join(mod.root, "media", "scripts"), [])) parseScriptFile(f, byKey, "mod");
  const outputs = {};
  for (const defs of Object.values(byKey)) {
    if (defs[0].kind !== "craftRecipe") continue;
    const all = new Set();
    for (const d of defs) for (const t of recipeOutputs(d.text)) all.add(t);
    outputs[defs[0].full] = [...all];
  }
  const idx = { byKey, outputs };
  scriptCache.set(mod.root, idx);
  return idx;
}
// Lua hooks a recipe declares (OnCreate = Some.fn ...), from its source.
const HOOK_RE = /\b(OnCreate|OnTest|OnStart|OnUpdate|OnFailed|OnCanPerform|OnGiveXP|OnAddToMenu)\s*=\s*([A-Za-z_][\w.]*)/g;
function recipeHooks(mod, full) {
  const src = sourceOf(mod, "craftRecipe", full);
  if (!src) return [];
  // Hooks are scalars: a later definition's OnCreate replaces an earlier one.
  const byKind = {};
  for (const d of src.defs) for (const m of d.text.matchAll(HOOK_RE)) byKind[m[1]] = { kind: m[1], fn: m[2], origin: d.origin };
  const hooks = Object.values(byKind);
  for (const h of hooks) h.requires = definingModules(mod, h.fn);
  return hooks;
}

// The game loads every mod Lua file; the bridge VM loads only what the
// config preloads and what gets required. Find the mod files that define a
// hook's table (`A.B = ...`) or the function itself, as require names.
const luaFileCache = new Map();
function modLuaFiles(mod) {
  if (luaFileCache.has(mod.root)) return luaFileCache.get(mod.root);
  const files = [];
  for (const ctxDir of ["shared", "client", "server"]) {
    const base = path.join(mod.root, "media", "lua", ctxDir);
    for (const f of walkLua(base, [])) {
      const rel = path.relative(base, f).replace(/\\/g, "/").replace(/\.lua$/, "");
      if (/(^|\/)Tests?\//.test(rel)) continue;
      let text = "";
      try { text = fs.readFileSync(f, "utf8"); } catch (_) {}
      files.push({ req: rel, text });
    }
  }
  luaFileCache.set(mod.root, files);
  return files;
}
function walkLua(dir, out) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walkLua(p, out);
    else if (e.name.endsWith(".lua")) out.push(p);
  }
  return out;
}
function definingModules(mod, fn) {
  const parts = String(fn).split(".");
  if (parts.length < 2) return [];
  const parent = parts.slice(0, -1).join(".");
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const defRe = new RegExp("(^|\\n)\\s*(" + esc(parent) + "\\s*=|function\\s+" + esc(fn) + "\\s*\\()");
  return modLuaFiles(mod).filter((f) => defRe.test(f.text)).map((f) => f.req).slice(0, 5);
}

function sourceOf(mod, kind, full) {
  if (!full) return null;
  const defs = scriptIndex(mod).byKey[kind + ":" + String(full).toLowerCase()];
  if (!defs) return null;
  return { defs: defs.map((e) => ({ file: e.file, line: e.line, origin: e.origin, text: e.text })),
           file: defs[0].file, line: defs[0].line, origin: defs[0].origin };
}

// ── JS value -> Lua literal (tool args) ────────────────────────────────────
function luaLit(v) {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return Number.isFinite(v) ? String(v) : "nil";
  if (typeof v === "string") {
    return '"' + v.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r")
      .replace(/[\x00-\x1f]/g, (c) => "\\" + c.charCodeAt(0)) + '"';
  }
  if (Array.isArray(v)) return "{" + v.map(luaLit).join(",") + "}";
  return "{" + Object.entries(v).map(([k, x]) => "[" + luaLit(k) + "]=" + luaLit(x)).join(",") + "}";
}

function killTree(proc) {
  if (!proc || proc.exitCode !== null) return;
  if (process.platform === "win32") spawn("taskkill", ["/pid", String(proc.pid), "/T", "/F"]);
  else proc.kill();
}

class Bridge {
  constructor(mod, ctx) {
    this.mod = mod;
    this.ctx = ctx;
    this.state = "idle";        // idle | booting | loading | ready | dead
    this.bootLog = [];
    this.error = null;
    this.queue = [];             // pending {src, resolve, reject}
    this.current = null;         // in-flight request
    this.out = [];               // print() lines captured during the in-flight call
    this.lastUsed = Date.now();
    this.info = null;            // WB.info() after load
    this.readyWaiters = [];
  }

  start() {
    if (this.state === "booting" || this.state === "loading" || this.state === "ready") return;
    this.state = "booting";
    this.error = null;
    this.bootLog = [];
    this.startedAt = Date.now();
    const pztest = path.join(this.ctx.KIT, "pztest");
    this.proc = spawn(this.ctx.bashPath(), [pztest, "--bridge"], { cwd: this.mod.root });
    let buf = "";
    this.proc.stdout.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).replace(/\r$/, "");
        buf = buf.slice(nl + 1);
        this.onLine(line);
      }
    });
    this.proc.stderr.on("data", (chunk) => {
      for (const l of chunk.toString("utf8").split(/\r?\n/)) if (l) this.log(l);
    });
    this.proc.on("close", (code) => {
      const was = this.state;
      this.state = "dead";
      this.error = this.error || (was === "ready" ? `bridge exited (${code})` : `bridge died during boot (exit ${code})`);
      const err = new Error(this.error);
      if (this.current) { this.current.reject(err); this.current = null; }
      for (const q of this.queue.splice(0)) q.reject(err);
      for (const w of this.readyWaiters.splice(0)) w.reject(err);
    });
    this.bootTimer = setTimeout(() => {
      if (this.state === "booting") { this.error = "boot timed out"; killTree(this.proc); }
    }, BOOT_TIMEOUT_MS);
  }

  log(l) {
    this.bootLog.push(l);
    if (this.bootLog.length > 400) this.bootLog.splice(0, this.bootLog.length - 400);
  }

  onLine(line) {
    if (this.state === "booting") {
      if (line === "@@BRIDGE_READY@@") {
        clearTimeout(this.bootTimer);
        this.bootMs = Date.now() - this.startedAt;
        this.state = "loading";
        this.loadTools().then(() => {
          this.state = "ready";
          for (const w of this.readyWaiters.splice(0)) w.resolve();
        }, (e) => {
          this.error = "workbench Lua failed to load: " + e.message;
          this.state = "dead";
          killTree(this.proc);
          for (const w of this.readyWaiters.splice(0)) w.reject(e);
        });
      } else this.log(line);
      return;
    }
    if (line.startsWith("@@OK@@") || line.startsWith("@@ERR@@")) {
      const ok = line.startsWith("@@OK@@");
      const payload = Buffer.from(line.slice(ok ? 6 : 7), "base64").toString("utf8");
      const cur = this.current;
      this.current = null;
      if (cur) {
        clearTimeout(cur.timer);
        const out = this.out; this.out = [];
        ok ? cur.resolve({ value: payload, out }) : cur.reject(Object.assign(new Error(payload), { out }));
      }
      this.pump();
      return;
    }
    // print() output from Lua (or engine logging) during a call
    if (this.current) { this.out.push(line); if (this.out.length > 2000) this.out.shift(); }
    else this.log(line);
  }

  // Raw eval during loading (bypasses the ready gate).
  rawEval(src) {
    return new Promise((resolve, reject) => {
      this.queue.push({ src, resolve, reject });
      this.pump();
    });
  }

  pump() {
    if (this.current || !this.queue.length || !this.proc || this.state === "dead") return;
    const req = this.queue.shift();
    this.current = req;
    this.out = [];
    req.timer = setTimeout(() => {
      // A runaway chunk wedges the VM (one thread); restart is the only cure.
      this.error = "call timed out after " + CALL_TIMEOUT_MS / 1000 + "s — bridge restarted";
      killTree(this.proc);
    }, CALL_TIMEOUT_MS);
    this.proc.stdin.write(Buffer.from(req.src, "utf8").toString("base64") + "\n");
  }

  async loadTools() {
    const files = fs.readdirSync(LUA_DIR).filter((f) => f.endsWith(".lua")).sort();
    // prelude first (defines WB), then tools in name order
    files.sort((a, b) => (a === "00_prelude.lua" ? -1 : b === "00_prelude.lua" ? 1 : a.localeCompare(b)));
    for (const f of files) {
      const src = fs.readFileSync(path.join(LUA_DIR, f), "utf8");
      try { await this.rawEval(src); }
      catch (e) { throw new Error(f + ": " + e.message); }
    }
    // Addons (40_addons.lua): kit-wide, then the mod's, then its dependencies'.
    // One file per eval so a broken addon reports itself and the rest load.
    for (const f of addonFiles(this.mod)) {
      const label = path.relative(path.dirname(KIT_ROOT), f).replace(/\\/g, "/");
      try {
        await this.rawEval(`WB.currentAddonFile = ${luaLit(label)}`);
        await this.rawEval(fs.readFileSync(f, "utf8"));
      } catch (e) {
        await this.rawEval(`WB.addonLoadError(${luaLit(label)}, ${luaLit(String(e.message || e))})`).catch(() => {});
      }
    }
    await this.rawEval("WB.currentAddonFile = nil");
    // Recipe outputs parsed from script source (OutputScript isn't exposed).
    await this.rawEval("WB.scriptOutputs = " + luaLit(scriptIndex(this.mod).outputs));
    const r = await this.rawEval("return WB.json(WB.info())");
    this.info = JSON.parse(r.value);
  }

  whenReady() {
    if (this.state === "ready") return Promise.resolve();
    if (this.state === "idle" || this.state === "dead") this.start();
    return new Promise((resolve, reject) => this.readyWaiters.push({ resolve, reject }));
  }

  async call(tool, args) {
    await this.whenReady();
    this.lastUsed = Date.now();
    const src = `return WB.call(${luaLit(tool)}, ${luaLit(args || {})})`;
    const r = await this.rawEval(src);
    let value;
    try { value = JSON.parse(r.value); } catch (_) { value = { error: "tool returned non-JSON", raw: r.value }; }
    return { value, out: r.out };
  }

  stop() {
    if (this.proc) {
      try { this.proc.stdin.write("__quit__\n"); } catch (_) {}
      const p = this.proc;
      setTimeout(() => killTree(p), 1500);
    }
    this.state = "dead";
    this.error = "stopped";
  }

  status() {
    return {
      modId: this.mod.id, state: this.state, error: this.error, bootMs: this.bootMs || null,
      elapsedMs: this.startedAt ? Date.now() - this.startedAt : null,
      bootLog: this.bootLog.slice(-60), info: this.info,
    };
  }
}

function bridgeFor(mod, ctx) {
  let b = bridges.get(mod.id);
  if (!b || b.state === "dead") { b = new Bridge(mod, ctx); bridges.set(mod.id, b); }
  return b;
}

setInterval(() => {
  for (const b of bridges.values()) {
    if (b.state === "ready" && !b.current && Date.now() - b.lastUsed > IDLE_MS) b.stop();
  }
}, 30 * 1000).unref();

const cleanup = () => { for (const b of bridges.values()) if (b.proc) killTree(b.proc); };
process.on("exit", cleanup);
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { cleanup(); process.exit(0); });

// ── HTTP ───────────────────────────────────────────────────────────────────
function json(res, code, body) {
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(body));
}
function readBody(req) {
  return new Promise((resolve) => {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => { try { resolve(b ? JSON.parse(b) : {}); } catch (_) { resolve({}); } });
  });
}
function engineConfigured(mod) {
  try { return /^\s*engine\s*=\s*true/m.test(fs.readFileSync(path.join(mod.root, "pz-test.lua"), "utf8")); }
  catch (_) { return false; }
}

// ── Java API index (signatures for the object explorer) ───────────────────
// pz-dev-tools/indexes/java-api/<Simple>.txt: "# Simple (fqcn)", "# extends X",
// then "  name(params) -> ret" lines. Kahlua can list a Java object's methods
// but not their signatures; this fills that in (arity => one-click getters).
const API_DIR = process.env.PZ_JAVA_API_DIR
  || path.resolve(__dirname, "..", "..", "..", "pz-dev-tools", "indexes", "java-api");
let apiIndex = null;
function loadApi() {
  if (apiIndex) return apiIndex;
  apiIndex = { bySimple: Object.create(null), byFq: Object.create(null) };
  if (!fs.existsSync(API_DIR)) return apiIndex;
  for (const f of fs.readdirSync(API_DIR)) {
    if (!f.endsWith(".txt")) continue;
    const text = fs.readFileSync(path.join(API_DIR, f), "utf8");
    const head = /^# (\S+) \(([^)]+)\)/m.exec(text);
    if (!head) continue;
    const ext = /^# extends (\S+)/m.exec(text);
    const cls = { simple: head[1], fqcn: head[2], extends: ext ? ext[1] : null, methods: Object.create(null) };
    let section = "";
    for (const line of text.split(/\r?\n/)) {
      if (line.startsWith("## ")) { section = line.slice(3); continue; }
      const m = /^ {2}(static\s+)?([A-Za-z_$][\w$]*)\((.*)\)\s*->\s*(.+)$/.exec(line);
      if (!m) continue;
      const params = m[3].trim();
      (cls.methods[m[2]] = cls.methods[m[2]] || []).push({
        sig: `${m[2]}(${params}) -> ${m[4].trim()}`, ret: m[4].trim(), static: !!m[1],
        arity: params ? params.split(",").length : 0, lua: /Lua-Exposed/.test(section),
      });
    }
    apiIndex.bySimple[cls.simple] = cls;
    apiIndex.byFq[cls.fqcn] = cls;
  }
  return apiIndex;
}
function apiChain(cls) {
  const api = loadApi(), chain = [];
  let c = cls;
  while (c && chain.length < 15) { chain.push(c); c = c.extends ? api.bySimple[c.extends.replace(/<.*$/, "")] : null; }
  return chain;
}
function allMethodNames(cls) {
  if (cls._all) return cls._all;
  const s = new Set();
  for (const c of apiChain(cls)) for (const k of Object.keys(c.methods)) s.add(k);
  return (cls._all = s);
}
function resolveApi(className, observed) {
  const api = loadApi();
  let cls = api.byFq[className] || api.bySimple[className] || api.bySimple[String(className).split(".").pop()];
  let inferred = false;
  if (!cls && observed && observed.length) {
    // Best Jaccard match between the object's live method names and each
    // class's inherited method set.
    const obs = new Set(observed);
    let best = null, bestScore = 0;
    for (const c of Object.values(api.byFq)) {
      const all = allMethodNames(c);
      let inter = 0;
      for (const n of obs) if (all.has(n)) inter++;
      const score = inter / (obs.size + all.size - inter);
      if (score > bestScore) { bestScore = score; best = c; }
    }
    if (best && bestScore > 0.5) { cls = best; inferred = Math.round(bestScore * 100) / 100; }
  }
  if (!cls) return null;
  const methods = Object.create(null);
  for (const c of apiChain(cls)) {
    for (const [name, sigs] of Object.entries(c.methods)) {
      if (methods[name]) continue;               // subclass wins
      methods[name] = sigs.map((s) => ({ ...s, declaredIn: c.simple }));
    }
  }
  return { simple: cls.simple, fqcn: cls.fqcn, inferred, chain: apiChain(cls).map((c) => c.simple), methods };
}

// Attach script source (and source-derived links) to tool results.
function augment(mod, tool, v) {
  if (!v || typeof v !== "object" || v.error) return;
  if (tool === "inspect" && v.kind === "java") {
    v.api = resolveApi(v.class, v.methods);
    if (v.api && (v.class === "java object" || !v.class.includes("."))) v.class = v.api.fqcn;
    return;
  }
  const idx = scriptIndex(mod);
  if (tool === "recipe") {
    v.source = sourceOf(mod, "craftRecipe", v.full);
    v.scriptOutputs = idx.outputs[v.full] || [];
    v.hooks = recipeHooks(mod, v.full);
  } else if (tool === "item") {
    v.source = sourceOf(mod, "item", v.fullType);
  } else if (tool === "fixing") {
    for (const f of v.fixing || []) f.source = sourceOf(mod, "fixing", "Base." + f.name) || sourceOf(mod, "fixing", f.name);
  } else if (tool === "evolved") {
    for (const e of v.evolved || []) e.source = sourceOf(mod, "evolvedrecipe", "Base." + e.name);
  }
}

// ── blueprints ─────────────────────────────────────────────────────────────
// A blueprint is a saved board: cards (item types + addon steps, recipes and
// their wiring), optional `expect` checks. Sources, in listing order:
//   <mod>/workbench/blueprints/*.json          templates shipped with the mod (commit them)
//   <dependency>/workbench/blueprints/*.json   templates from mods it loads
//   dashboard/workbench/blueprints/*.json      kit-wide
//   dashboard/.blueprints/<modId>/*.json       your local library (gitignored)
function blueprintDirs(mod) {
  const out = [{ key: "mod", label: path.basename(mod.root) + " templates", dir: path.join(mod.root, "workbench", "blueprints"), writable: true }];
  depRoots(mod).forEach((r, i) => out.push({ key: "dep" + i, label: path.basename(r) + " templates", dir: path.join(r, "workbench", "blueprints"), writable: false }));
  out.push({ key: "kit", label: "kit templates", dir: path.join(LUA_DIR, "blueprints"), writable: false });
  out.push({ key: "local", label: "my library", dir: path.join(HERE, ".blueprints", mod.id), writable: true });
  return out;
}
function listBlueprints(mod) {
  const list = [];
  for (const d of blueprintDirs(mod)) {
    if (!fs.existsSync(d.dir)) continue;
    for (const f of fs.readdirSync(d.dir).filter((x) => x.endsWith(".json")).sort()) {
      try {
        const bp = JSON.parse(fs.readFileSync(path.join(d.dir, f), "utf8"));
        list.push({ ...bp, id: d.key + ":" + f, source: d.key, sourceLabel: d.label, writable: d.writable });
      } catch (e) {
        list.push({ id: d.key + ":" + f, source: d.key, sourceLabel: d.label, name: f, error: "bad JSON: " + e.message, cards: [] });
      }
    }
  }
  return list;
}
const slug = (s) => String(s || "blueprint").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60) || "blueprint";

async function handle(req, res, url, ctx) {
  const p = url.pathname;
  if (p === "/workbench" || p === "/workbench.html") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    fs.createReadStream(path.join(HERE, "workbench.html")).pipe(res);
    return true;
  }
  if (!p.startsWith("/api/wb/")) return false;
  const parts = p.split("/").filter(Boolean);   // api wb <modId> <action>

  if (parts[2] === "mods" && parts.length === 3) {
    json(res, 200, ctx.mods().map((m) => {
      const b = bridges.get(m.id);
      return { id: m.id, name: m.name, root: m.root, engine: engineConfigured(m), bridge: b ? b.state : "idle" };
    }));
    return true;
  }
  const mod = ctx.modById(parts[2]);
  if (!mod) { json(res, 404, { error: "unknown mod" }); return true; }
  const action = parts[3];
  try {
    if (action === "status") { json(res, 200, (bridges.get(mod.id) || new Bridge(mod, ctx)).status()); return true; }
    if (action === "blueprints") {
      if (req.method === "GET") { json(res, 200, { blueprints: listBlueprints(mod), targets: blueprintDirs(mod).filter((d) => d.writable).map((d) => ({ key: d.key, label: d.label })) }); return true; }
      if (req.method === "POST") {
        const body = await readBody(req);
        const d = blueprintDirs(mod).find((x) => x.key === (body.target || "local") && x.writable);
        if (!d || !body.blueprint || !body.blueprint.name) { json(res, 400, { error: "need blueprint.name and a writable target" }); return true; }
        fs.mkdirSync(d.dir, { recursive: true });
        const file = slug(body.blueprint.name) + ".json";
        fs.writeFileSync(path.join(d.dir, file), JSON.stringify(body.blueprint, null, 2) + "\n");
        json(res, 200, { ok: true, id: d.key + ":" + file, path: path.join(d.dir, file) });
        return true;
      }
      if (req.method === "DELETE") {
        const [key, file] = String(url.searchParams.get("id") || "").split(":");
        const d = blueprintDirs(mod).find((x) => x.key === key && x.writable);
        if (!d || !/^[\w.-]+\.json$/.test(file || "")) { json(res, 400, { error: "not deletable" }); return true; }
        fs.rmSync(path.join(d.dir, file), { force: true });
        json(res, 200, { ok: true });
        return true;
      }
    }
    if (action === "start" && req.method === "POST") {
      const b = bridgeFor(mod, ctx);
      b.start();
      json(res, 200, b.status());
      return true;
    }
    if (action === "stop" && req.method === "POST") {
      const b = bridges.get(mod.id);
      if (b) b.stop();
      json(res, 200, { ok: true });
      return true;
    }
    if (action === "reload" && req.method === "POST") {
      // Re-run the tool Lua against the live VM (edit a tool, no reboot).
      const b = bridgeFor(mod, ctx);
      await b.whenReady();
      await b.loadTools();
      json(res, 200, b.status());
      return true;
    }
    if (action === "call" && req.method === "POST") {
      const body = await readBody(req);
      const b = bridgeFor(mod, ctx);
      const t0 = Date.now();
      try {
        if (body.tool === "craft" && body.args && body.args.recipe) {
          // Hooks come from the source text: the engine-side CraftRecipe
          // keeps them behind non-exposed LuaCall enums.
          const r0 = String(body.args.recipe);
          body.args.hooks = recipeHooks(mod, r0.includes(".") ? r0 : "Base." + r0);
        }
        const r = await b.call(body.tool, body.args);
        augment(mod, body.tool, r.value);
        json(res, 200, { ok: true, ms: Date.now() - t0, value: r.value, out: r.out });
      } catch (e) {
        json(res, 200, { ok: false, ms: Date.now() - t0, error: e.message, out: e.out || [] });
      }
      return true;
    }
  } catch (e) {
    json(res, 500, { error: String(e && e.stack || e) });
    return true;
  }
  json(res, 404, { error: "unknown workbench endpoint" });
  return true;
}

module.exports = { handle, resolveApi };
