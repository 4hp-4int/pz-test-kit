#!/usr/bin/env node
/*
 * PZ Test Kit — dashboard server
 * ==============================
 * Finds every mod with a pz-test.lua, runs `pztest --report-json` on demand,
 * keeps each run's report under dashboard/.runs/, and serves index.html.
 * No deps: plain http + child_process, same shape as uiview/serve-bridge.js.
 *
 *   node dashboard/server.js [port]          (default 8760)
 *
 * Extra mod roots can be listed in dashboard/roots.json as an array of paths
 * (each is either a mod root or a directory whose children are scanned).
 */
const http = require("http");
const fs = require("fs");
const path = require("path");
const { spawn, execFileSync } = require("child_process");
const workbench = require("./workbench");   // Engine Workbench: /workbench + /api/wb/*

const HERE = __dirname;
const KIT = path.resolve(HERE, "..");
const BASE = path.resolve(KIT, "..");          // the monorepo the kit lives in
const RUNS = path.join(HERE, ".runs");
const PORT = parseInt(process.argv[2] || process.env.PZTEST_DASH_PORT || "8760", 10);
const MAX_PARALLEL = 2;                        // JVM runs are CPU-heavy
const STEAM_MANIFEST = "C:/Program Files (x86)/Steam/steamapps/appmanifest_108600.acf";

const norm = (p) => path.resolve(p).replace(/\\/g, "/");

// ── mod discovery ───────────────────────────────────────────────────────────
function scanRoots() {
  const roots = [BASE, KIT, path.join(KIT, "examples")];
  try {
    const extra = JSON.parse(fs.readFileSync(path.join(HERE, "roots.json"), "utf8"));
    if (Array.isArray(extra)) roots.push(...extra.map((r) => path.resolve(BASE, r)));
  } catch (_) { /* optional */ }
  return roots;
}

let modCache = null;
function discoverMods() {
  const seen = new Map();
  const add = (dir) => {
    if (!fs.existsSync(path.join(dir, "pz-test.lua"))) return;
    const root = norm(dir);
    if (seen.has(root)) return;
    const rel = path.relative(BASE, dir).replace(/\\/g, "/") || path.basename(dir);
    const id = rel.replace(/[^A-Za-z0-9_.-]+/g, "__");
    seen.set(root, { id, name: rel, root });
  };
  for (const r of scanRoots()) {
    if (!fs.existsSync(r)) continue;
    add(r);
    for (const ent of fs.readdirSync(r, { withFileTypes: true })) {
      if (!ent.isDirectory() || ent.name.startsWith(".") || ent.name === "node_modules") continue;
      add(path.join(r, ent.name));
    }
  }
  modCache = [...seen.values()].sort((a, b) => a.name.localeCompare(b.name));
  return modCache;
}
const mods = () => modCache || discoverMods();
const modById = (id) => mods().find((m) => m.id === id);

// ── run storage ─────────────────────────────────────────────────────────────
// .runs/<modId>/<runId>.json   full report (written by the runner)
// .runs/<modId>/<runId>.log    console transcript
// .runs/<modId>/<runId>.meta.json  small summary for history/sidebar
const runDir = (modId) => path.join(RUNS, modId);

function summarize(report) {
  const out = { totals: report.totals, ms: report.ms, gameVersion: report.gameVersion };
  if (report.coverage) {
    let pts = 0, hit = 0;
    for (const f of report.coverage.files) {
      if (f.fallback) continue;
      pts += f.points; hit += f.hit.length;
    }
    out.coverage = { scope: report.coverage.scope, points: pts, hit, pct: pts ? (100 * hit) / pts : null };
    out.perTest = !!report.coverage.perTest;
  }
  out.fidelity = !!report.fidelity;
  out.failing = [];
  for (const f of report.files) {
    if (f.error) out.failing.push(f.file + " :: <file>");
    for (const c of f.cases) if (c.status === "fail" || c.status === "error") out.failing.push(f.file + " :: " + c.name);
  }
  return out;
}

function listRuns(modId) {
  const dir = runDir(modId);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((f) => f.endsWith(".meta.json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")); } catch (_) { return null; } })
    .filter(Boolean)
    .sort((a, b) => a.runId.localeCompare(b.runId));
}

// ── impact analysis + watch mode (see impact.js) ────────────────────────────
const impact = require("./impact")({ runDir: (id) => runDir(id), listRuns: (id) => listRuns(id), mods });
const fidelity = require("./fidelity")({ KIT });

/** Queue one run per mod for an impact set; returns the run metas. */
function runImpact(imp, opts) {
  const metas = [];
  for (const [modId, sel] of imp.runs) {
    const m = modById(modId);
    if (m && sel.size) metas.push(startRun(m, { ...opts, only: [...sel], reason: opts.reason }));
  }
  return metas;
}

// Global event feed (SSE) — watch activity, run starts/ends.
const feed = new Set();
const feedLog = [];
function broadcast(ev) {
  ev.at = new Date().toISOString();
  feedLog.push(ev);
  if (feedLog.length > 200) feedLog.shift();
  const msg = `data: ${JSON.stringify(ev)}\n\n`;
  for (const c of feed) c.write(msg);
}

const watch = { on: false, measure: true, watchers: [], pending: new Set(), timer: null };
function setWatch(on, measure) {
  if (measure != null) watch.measure = !!measure;
  if (on === watch.on) return;
  watch.on = on;
  for (const w of watch.watchers) w.close();
  watch.watchers = [];
  if (!on) { broadcast({ type: "watch", on: false }); return; }
  watch.since = Date.now();
  seenMtime.clear();
  for (const m of mods()) {
    try {
      watch.watchers.push(fs.watch(m.root, { recursive: true }, (_ev, name) => {
        if (!name || !/\.lua$/i.test(name) || /(^|[\\/])(\.git|node_modules|\.runs)([\\/]|$)/.test(name)) return;
        watch.pending.add(path.join(m.root, name));
        clearTimeout(watch.timer);
        watch.timer = setTimeout(flushWatch, 500);
      }));
    } catch (e) { broadcast({ type: "error", message: `watch ${m.name}: ${e.message}` }); }
  }
  broadcast({ type: "watch", on: true, mods: watch.watchers.length });
}
// On Windows, fs.watch(recursive) reports LAST-ACCESS changes too, so every
// file a test run READS fires an event, and the reruns that triggers read more
// files: a feedback loop. Only a moved mtime is an edit. Files first seen
// mid-watch count as edited only if written after watch started.
const seenMtime = new Map();
function edited(p) {
  let m;
  try { m = fs.statSync(p).mtimeMs; } catch (_) { return false; }
  const prev = seenMtime.get(p);
  seenMtime.set(p, m);
  return prev == null ? m > watch.since : m !== prev;
}
function flushWatch() {
  const changed = [...watch.pending].filter(edited).map((p) => ({ path: p }));
  watch.pending.clear();
  if (!changed.length) return;
  const imp = impact.impactedBy(changed);
  const opts = watch.measure ? { coverage: true, perTest: true, reason: "watch" } : { reason: "watch" };
  const metas = runImpact(imp, opts);
  broadcast({
    type: "change", files: changed.map((c) => c.path.replace(/\\/g, "/")), unmapped: imp.unmapped.map((p) => p.replace(/\\/g, "/")),
    runs: metas.map((m) => ({ runId: m.runId, modId: m.modId, mod: m.mod, tests: m.opts.only.length })),
  });
}
process.on("exit", () => { for (const w of watch.watchers) w.close(); });

// ── run execution ───────────────────────────────────────────────────────────
function bashPath() {
  if (process.platform === "win32") {
    for (const c of ["C:\\Program Files\\Git\\bin\\bash.exe", "C:\\Program Files (x86)\\Git\\bin\\bash.exe"])
      if (fs.existsSync(c)) return c;
  }
  return "bash";
}

const runs = new Map();   // runId -> live run {meta, lines, clients, proc}
const queue = [];
let active = 0;

function buildArgs(opts, reportPath, onlyPath) {
  const a = [];
  if (onlyPath) a.push("--only", onlyPath.replace(/\\/g, "/"));
  else if (opts.file) a.push(opts.file);
  if (opts.filter && !onlyPath) a.push("--filter", opts.filter);
  if (opts.coverage) a.push(opts.coverageScope ? "--coverage=" + opts.coverageScope : "--coverage");
  if (opts.coverage && opts.perTest) a.push("--coverage-per-test");
  if (opts.fidelity) a.push("--fidelity");
  if (opts.eventCoverage) a.push("--event-coverage");
  if (opts.engine === "on") a.push("--engine");
  if (opts.engine === "off") a.push("--no-engine");
  if (opts.engineMods) a.push("--engine-mods");
  if (opts.noPrescan) a.push("--no-prescan");
  a.push("--report-json", reportPath.replace(/\\/g, "/"));
  return a;
}

function startRun(mod, opts) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const runId = stamp;
  fs.mkdirSync(runDir(mod.id), { recursive: true });
  const base = path.join(runDir(mod.id), runId);
  // opts.only: exact ["testFile::testName" | "testFile"] selection (smart reruns).
  let onlyPath = null;
  if (Array.isArray(opts.only) && opts.only.length) {
    onlyPath = base + ".only.txt";
    fs.writeFileSync(onlyPath, opts.only.join("\n") + "\n");
  }
  const meta = {
    runId, modId: mod.id, mod: mod.name, opts, args: buildArgs(opts, base + ".json", onlyPath),
    queuedAt: new Date().toISOString(), state: "queued",
  };
  const run = { meta, base, lines: [], clients: new Set() };
  runs.set(runId, run);
  queue.push(run);
  pump();
  return meta;
}

function pump() {
  while (active < MAX_PARALLEL && queue.length) {
    const run = queue.shift();
    active++;
    execute(run);
  }
}

function emit(run, event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const c of run.clients) c.write(msg);
}

function execute(run) {
  const mod = modById(run.meta.modId);
  run.meta.state = "running";
  run.meta.startedAt = new Date().toISOString();
  emit(run, "state", run.meta);
  const t0 = Date.now();
  const log = fs.createWriteStream(run.base + ".log");
  const proc = spawn(bashPath(), [path.join(KIT, "pztest"), ...run.meta.args], { cwd: mod.root });
  run.proc = proc;
  let buf = "";
  const onData = (chunk) => {
    log.write(chunk);
    buf += chunk.toString();
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).replace(/\r$/, "");
      buf = buf.slice(nl + 1);
      run.lines.push(line);
      emit(run, "line", line);
    }
  };
  proc.stdout.on("data", onData);
  proc.stderr.on("data", onData);
  proc.on("close", (code) => {
    if (buf) { run.lines.push(buf); emit(run, "line", buf); }
    log.end();
    const meta = run.meta;
    meta.exitCode = code;
    meta.wallMs = Date.now() - t0;
    meta.state = "done";
    try {
      Object.assign(meta, summarize(JSON.parse(fs.readFileSync(run.base + ".json", "utf8"))));
      meta.hasReport = true;
    } catch (e) {
      meta.hasReport = false;
      meta.error = "no report written (runner exited before the summary) — see the log";
    }
    fs.writeFileSync(run.base + ".meta.json", JSON.stringify(meta, null, 1));
    emit(run, "done", meta);
    broadcast({ type: "done", runId: meta.runId, modId: meta.modId, mod: meta.mod, totals: meta.totals || null,
                exitCode: meta.exitCode, failing: (meta.failing || []).slice(0, 10), reason: meta.opts.reason || null });
    for (const c of run.clients) c.end();
    run.clients.clear();
    // Keep the live record briefly so a late subscriber still gets "done".
    setTimeout(() => runs.delete(meta.runId), 60_000);
    active--;
    pump();
  });
}

// ── environment ─────────────────────────────────────────────────────────────
function envInfo() {
  const info = { kit: norm(KIT), base: norm(BASE) };
  try {
    const acf = fs.readFileSync(STEAM_MANIFEST, "utf8");
    info.steamBuildId = (acf.match(/"buildid"\s+"(\d+)"/) || [])[1] || null;
  } catch (_) { info.steamBuildId = null; }
  try {
    info.kitRev = execFileSync("git", ["-C", KIT, "log", "-1", "--format=%h %s"], { encoding: "utf8" }).trim();
    info.kitDirty = execFileSync("git", ["-C", KIT, "status", "--porcelain"], { encoding: "utf8" }).trim().length > 0;
  } catch (_) { /* not a git checkout */ }
  try {
    const cert = fs.readFileSync(path.join(KIT, "CERTIFICATION.md"), "utf8");
    const sect = cert.split(/^## Current certification/m)[1] || "";
    info.certifications = sect.split("\n")
      .filter((l) => /^\|/.test(l) && !/^\|\s*-/.test(l) && !/^\|\s*Mod\s*\|/.test(l))
      .map((l) => {
        const c = l.split("|").slice(1, -1).map((s) => s.trim());
        return { mod: c[0], scope: c[1], coverage: c[2], tests: c[3], line: c[4], version: c[5],
                 buildId: (c[6] || "").replace(/`/g, ""), date: c[7] };
      });
  } catch (_) { info.certifications = []; }
  return info;
}

// ── source access (coverage overlay) ────────────────────────────────────────
// Only files under a discovered mod root, the monorepo, or the kit.
function allowedSource(p) {
  const n = norm(p).toLowerCase();
  const roots = [norm(BASE), norm(KIT), ...mods().map((m) => m.root)].map((r) => r.toLowerCase() + "/");
  return roots.some((r) => n.startsWith(r));
}

// ── HTTP ────────────────────────────────────────────────────────────────────
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
const safeId = (s) => /^[A-Za-z0-9_.-]+$/.test(s || "");

const listCache = new Map();
function listTests(mod) {
  if (listCache.has(mod.id)) return Promise.resolve(listCache.get(mod.id));
  return new Promise((resolve) => {
    const p = spawn(bashPath(), [path.join(KIT, "pztest"), "--list"], { cwd: mod.root });
    let out = "";
    p.stdout.on("data", (c) => (out += c));
    p.stderr.on("data", () => {});
    p.on("close", () => {
      const files = out.split(/\r?\n/).filter((l) => /\.lua$/.test(l.trim())).map((l) => l.trim());
      listCache.set(mod.id, files);
      resolve(files);
    });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const parts = url.pathname.split("/").filter(Boolean);
  try {
    if (await workbench.handle(req, res, url, { mods, modById, KIT, bashPath })) return;
    if (url.pathname === "/" || url.pathname === "/index.html") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      return fs.createReadStream(path.join(HERE, "index.html")).pipe(res);
    }
    if (parts[0] !== "api") { res.writeHead(404); return res.end("not found"); }

    // GET /api/mods[?rescan=1]
    if (parts[1] === "mods" && parts.length === 2) {
      if (url.searchParams.get("rescan")) { discoverMods(); listCache.clear(); }
      return json(res, 200, mods().map((m) => {
        const hist = listRuns(m.id);
        const running = [...runs.values()].filter((r) => r.meta.modId === m.id && r.meta.state !== "done").map((r) => r.meta);
        const isFull = (r) => !(r.opts && ((r.opts.only && r.opts.only.length) || r.opts.file || r.opts.filter));
        const fulls = hist.filter(isFull);
        return { ...m, last: hist[hist.length - 1] || null, lastFull: fulls[fulls.length - 1] || null, runCount: hist.length,
                 trend: fulls.slice(-20).map((h) => ({ pass: h.totals?.passed, fail: (h.totals?.failed || 0) + (h.totals?.errors || 0), cov: h.coverage?.pct ?? null })),
                 running };
      }));
    }
    if (url.pathname === "/api/env") return json(res, 200, envInfo());

    if (parts[1] === "mods" && parts[2]) {
      const mod = modById(parts[2]);
      if (!mod) return json(res, 404, { error: "unknown mod" });
      const what = parts[3];
      if (what === "config") {
        const raw = fs.readFileSync(path.join(mod.root, "pz-test.lua"), "utf8");
        return json(res, 200, { root: mod.root, raw });
      }
      if (what === "files") return json(res, 200, await listTests(mod));
      if (what === "runs" && !parts[4]) return json(res, 200, listRuns(mod.id));
      if (what === "runs" && parts[4]) {
        if (!safeId(parts[4])) return json(res, 400, { error: "bad run id" });
        const base = path.join(runDir(mod.id), parts[4]);
        if (parts[5] === "log") {
          res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
          return fs.existsSync(base + ".log") ? fs.createReadStream(base + ".log").pipe(res) : res.end("");
        }
        if (req.method === "DELETE") {
          for (const ext of [".json", ".log", ".meta.json", ".only.txt"]) fs.rmSync(base + ext, { force: true });
          return json(res, 200, { ok: true });
        }
        if (!fs.existsSync(base + ".json")) return json(res, 404, { error: "no report for this run" });
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        return fs.createReadStream(base + ".json").pipe(res);
      }
      if (what === "run" && req.method === "POST") {
        const opts = await readBody(req);
        return json(res, 200, startRun(mod, opts));
      }
    }

    // Impact / changed lines / watch ─────────────────────────────────────
    if (parts[1] === "mods" && parts[2] && parts[3] === "changes") {
      const mod = modById(parts[2]);
      if (!mod) return json(res, 404, { error: "unknown mod" });
      return json(res, 200, impact.changes(mod, url.searchParams.get("base") || "HEAD"));
    }
    // POST /api/mods/:id/run-impacted {base, opts}: rerun every test (in any
    // mod) that touches a file changed vs base, measuring coverage per test.
    if (parts[1] === "mods" && parts[2] && parts[3] === "run-impacted" && req.method === "POST") {
      const mod = modById(parts[2]);
      if (!mod) return json(res, 404, { error: "unknown mod" });
      const body = await readBody(req);
      let diff;
      try { diff = impact.diffLines(mod.root, body.base || "HEAD"); }
      catch (e) { return json(res, 400, { error: String(e.stderr || e.message).trim() }); }
      const changed = [...diff.keys()].filter((p) => /\.lua$/i.test(p)).map((p) => ({ path: p }));
      const imp = impact.impactedBy(changed);
      const metas = runImpact(imp, { coverage: true, perTest: true, ...(body.opts || {}), reason: "changes vs " + (body.base || "HEAD") });
      return json(res, 200, { runs: metas, unmapped: imp.unmapped, changed: changed.length });
    }
    // Fidelity: GET /api/mods/:id/fidelity[?run=<runId>]  (default: newest run with --fidelity)
    if (parts[1] === "mods" && parts[2] && parts[3] === "fidelity") {
      const mod = modById(parts[2]);
      if (!mod) return json(res, 404, { error: "unknown mod" });
      let runId = url.searchParams.get("run");
      if (!runId) { const r = listRuns(mod.id).filter((x) => x.hasReport && x.fidelity).pop(); runId = r && r.runId; }
      let report = null;
      if (runId && safeId(runId)) { try { report = JSON.parse(fs.readFileSync(path.join(runDir(mod.id), runId + ".json"), "utf8")); } catch (_) {} }
      return json(res, 200, { runId: report ? runId : null, ...fidelity.forMod(mod, report) });
    }
    if (url.pathname === "/api/engine") return json(res, 200, fidelity.inventory());
    if (url.pathname === "/api/whocovers") {
      return json(res, 200, impact.whoCovers(url.searchParams.get("path"), url.searchParams.get("line")));
    }
    if (url.pathname === "/api/linecounts") {
      return json(res, 200, impact.lineCounts(url.searchParams.get("mod"), url.searchParams.get("path")));
    }
    if (url.pathname === "/api/watch") {
      if (req.method === "POST") { const b = await readBody(req); setWatch(!!b.on, b.measure); }
      return json(res, 200, { on: watch.on, measure: watch.measure });
    }
    if (url.pathname === "/api/events") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
      for (const ev of feedLog.slice(-30)) res.write(`data: ${JSON.stringify({ ...ev, replay: true })}\n\n`);
      feed.add(res);
      req.on("close", () => feed.delete(res));
      return;
    }

    // POST /api/run-all  {opts}
    if (url.pathname === "/api/run-all" && req.method === "POST") {
      const opts = await readBody(req);
      return json(res, 200, mods().map((m) => startRun(m, opts)));
    }

    // GET /api/stream/:runId  (SSE)
    if (parts[1] === "stream" && parts[2]) {
      const run = runs.get(parts[2]);
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
      if (!run) { res.write(`event: gone\ndata: {}\n\n`); return res.end(); }
      res.write(`event: state\ndata: ${JSON.stringify(run.meta)}\n\n`);
      for (const l of run.lines) res.write(`event: line\ndata: ${JSON.stringify(l)}\n\n`);
      if (run.meta.state === "done") { res.write(`event: done\ndata: ${JSON.stringify(run.meta)}\n\n`); return res.end(); }
      run.clients.add(res);
      req.on("close", () => run.clients.delete(res));
      return;
    }

    // POST /api/cancel/:runId
    if (parts[1] === "cancel" && parts[2] && req.method === "POST") {
      const run = runs.get(parts[2]);
      if (!run) return json(res, 404, { error: "no such run" });
      const qi = queue.indexOf(run);
      if (qi >= 0) { queue.splice(qi, 1); run.meta.state = "done"; run.meta.cancelled = true; emit(run, "done", run.meta); runs.delete(parts[2]); }
      else if (run.proc) {
        run.meta.cancelled = true;
        // bash -> java: killing bash alone orphans the JVM on Windows.
        if (process.platform === "win32") spawn("taskkill", ["/pid", String(run.proc.pid), "/T", "/F"]);
        else run.proc.kill();
      }
      return json(res, 200, { ok: true });
    }

    // GET /api/source?path=...
    if (url.pathname === "/api/source") {
      const p = url.searchParams.get("path");
      if (!p || !allowedSource(p) || !fs.existsSync(p)) return json(res, 404, { error: "not available" });
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      return fs.createReadStream(p).pipe(res);
    }

    json(res, 404, { error: "unknown endpoint" });
  } catch (e) {
    json(res, 500, { error: String(e && e.stack || e) });
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[pztest-dashboard] ${mods().length} mod(s) with pz-test.lua under ${norm(BASE)}`);
  console.log(`[pztest-dashboard] http://127.0.0.1:${PORT}/`);
});
