/*
 * PZ Test Kit dashboard: impact analysis
 * ======================================
 * Three things built on coverage reports (per-test ones where noted):
 *
 *   whoCovers(path, line)   tests (across ALL mods) that executed that line
 *   changes(mod, base)      changed lines (git diff vs base + untracked) joined
 *                           with coverage: covered / uncovered / not executable
 *   impactedBy(paths)       the exact tests to rerun when those files change
 *
 * Two rules keep the answers honest:
 *
 *   1. MERGE BACK TO THE LAST FULL RUN. Smart reruns run a subset, so the
 *      newest run alone understates coverage and would shrink the next impact
 *      set. Runs are walked newest -> oldest down to, and including, the newest
 *      FULL run (no only/file/filter). Per test, its newest data wins.
 *   2. LINE NUMBERS EXPIRE ON EDIT. Coverage from a run that started before a
 *      file's last modification may point at different code. Such data is
 *      reported "stale" and never as covered.
 */
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const TEST_FILE = /(^|\/)(tests?\/test_[^/]*|[^/]*tests)\.lua$/i;
const key = (p) => path.resolve(p).replace(/\\/g, "/").toLowerCase();

function parseRanges(s) {
  const out = [];
  for (const part of String(s || "").split(",")) {
    if (!part) continue;
    const [a, b] = part.split("-").map(Number);
    for (let n = a; n <= (b || a); n++) out.push(n);
  }
  return out;
}

module.exports = function createImpact({ runDir, listRuns, mods }) {
  // ── report cache ──────────────────────────────────────────────────────────
  const cache = new Map();   // "<modId>/<runId>" -> { index, testKeys, started }
  function load(modId, runId) {
    const k = modId + "/" + runId;
    if (cache.has(k)) { const v = cache.get(k); cache.delete(k); cache.set(k, v); return v; }
    let report;
    try { report = JSON.parse(fs.readFileSync(path.join(runDir(modId), runId + ".json"), "utf8")); }
    catch (_) { return null; }
    const v = { ...indexReport(report), started: Date.parse(report.startedAt) || 0 };
    cache.set(k, v);
    while (cache.size > 48) cache.delete(cache.keys().next().value);
    return v;
  }

  // index: file key -> { name, path, points:Set, hit:Set, lines: Map(line -> [testKey]) | null }
  function indexReport(report) {
    const index = new Map(), testKeys = new Set();
    for (const tf of report.files) for (const c of tf.cases) testKeys.add(tf.file + "::" + c.name);
    const cov = report.coverage;
    if (!cov) return { index, testKeys };
    const byIdx = cov.files.map((f) => {
      const fe = {
        name: f.name, path: f.path, fallback: f.fallback,
        points: new Set([...f.hit, ...f.miss]), hit: new Set(f.hit),
        lines: cov.perTest ? new Map() : null,
      };
      index.set(key(f.path), fe);
      return fe;
    });
    if (cov.perTest) {
      for (const tf of report.files) for (const c of tf.cases) {
        if (!c.cov) continue;
        const tk = tf.file + "::" + c.name;
        for (const [ix, r] of Object.entries(c.cov)) {
          const fe = byIdx[Number(ix)];
          if (!fe) continue;
          for (const ln of parseRanges(r)) {
            let arr = fe.lines.get(ln);
            if (!arr) fe.lines.set(ln, (arr = []));
            arr.push(tk);
          }
        }
      }
    }
    return { index, testKeys };
  }

  // Newest-first coverage runs for a mod. Cached on the run directory's
  // mtime: a finished run adds files, which bumps it.
  const runsCache = new Map();
  function coverageRuns(modId, perTestOnly) {
    let st = 0;
    try { st = fs.statSync(runDir(modId)).mtimeMs; } catch (_) { return []; }
    let c = runsCache.get(modId);
    if (!c || c.st !== st) {
      const all = listRuns(modId).filter((r) => r.hasReport && r.coverage).reverse()
        .map((r) => ({ ...r, full: !(r.opts && ((r.opts.only && r.opts.only.length) || r.opts.file || r.opts.filter)) }));
      runsCache.set(modId, (c = { st, all, perTest: all.filter((r) => r.perTest) }));
    }
    return perTestOnly ? c.perTest : c.all;
  }

  const mtime = (p) => { try { return fs.statSync(p).mtimeMs; } catch (_) { return 0; } };

  /**
   * Line hits for one file within one mod, merged across runs back to the
   * newest full run, counting only runs that started after the file's last
   * edit. Returns { hit, points, runId, complete } | { stale, runId } | null.
   * complete = a full run is among them (else only smart reruns measured it,
   * which is complete only if they ran every test touching the file).
   */
  function measure(modId, fileKey, filePath) {
    const m = mtime(filePath);
    let hit = null, points = null, runId = null, complete = false, stale = null;
    for (const r of coverageRuns(modId, false)) {
      const v = load(modId, r.runId);
      const fe = v && v.index.get(fileKey);
      if (fe) {
        if (v.started >= m) {
          hit = hit || new Set(); points = points || new Set();
          for (const l of fe.hit) hit.add(l);
          for (const l of fe.points) points.add(l);
          runId = runId || r.runId;
          if (r.full) complete = true;
        } else if (!stale) stale = r;
      }
      if (r.full) break;
    }
    if (hit) return { hit, points, runId, complete };
    return stale ? { stale: true, runId: stale.runId } : null;
  }

  /**
   * Per-test line map for one file within one mod: each test's NEWEST
   * per-test data wins, back to the newest full per-test run.
   * Returns { lines: Map(line -> [testKey]), stale, runId } | null.
   */
  function perTestView(modId, fileKey, filePath) {
    const m = mtime(filePath);
    const seen = new Set(), lines = new Map();
    let found = false, stale = false, runId = null;
    for (const r of coverageRuns(modId, true)) {
      const v = load(modId, r.runId);
      if (!v) continue;
      const fe = v.index.get(fileKey);
      if (fe) {
        let contributed = false;
        for (const [ln, tks] of fe.lines) for (const tk of tks) {
          if (seen.has(tk)) continue;
          let a = lines.get(ln);
          if (!a) lines.set(ln, (a = []));
          a.push(tk);
          contributed = true;
        }
        if (contributed || !found) {
          found = true;
          runId = runId || r.runId;
          if (contributed && v.started < m) stale = true;
        }
      }
      for (const tk of v.testKeys) seen.add(tk);
      if (r.full) break;
    }
    return found ? { lines, stale, runId } : null;
  }

  // ── who covers ────────────────────────────────────────────────────────────
  function whoCovers(filePath, line) {
    const fk = key(filePath), out = [];
    for (const m of mods()) {
      const view = perTestView(m.id, fk, filePath);
      if (!view) continue;
      out.push({ modId: m.id, mod: m.name, runId: view.runId, stale: view.stale, tests: view.lines.get(Number(line)) || [] });
    }
    return out;
  }

  /** Per-line test counts for one file within one mod. */
  function lineCounts(modId, filePath) {
    const view = perTestView(modId, key(filePath), filePath);
    if (!view) return null;
    const counts = {};
    for (const [ln, arr] of view.lines) counts[ln] = arr.length;
    return { runId: view.runId, stale: view.stale, counts };
  }

  // ── impact (what to rerun) ────────────────────────────────────────────────
  /**
   * changed: [{ path, lines?: number[] }]. With lines, only tests that ran
   * those lines (or, if none did, every test that touched the file); without,
   * every test that touched the file. Changed TEST files rerun whole.
   * Staleness is ignored: impact is a file-level question, and line drift can
   * only blur the selection, never hide a file.
   * Returns { runs: Map(modId -> Set("file::name" | "file")), unmapped: [path] }.
   */
  function impactedBy(changed) {
    const runs = new Map();
    const unmapped = [];
    const add = (modId, t) => { if (!runs.has(modId)) runs.set(modId, new Set()); runs.get(modId).add(t); };
    for (const ch of changed) {
      const fk = key(ch.path);
      let mapped = false;
      for (const m of mods()) {
        if (fk.startsWith(key(m.root) + "/") && TEST_FILE.test(fk)) {
          add(m.id, path.relative(m.root, ch.path).replace(/\\/g, "/"));
          mapped = true;
          continue;
        }
        const view = perTestView(m.id, fk, ch.path);
        if (!view) continue;
        mapped = true;
        const picked = new Set();
        if (ch.lines && ch.lines.length) for (const ln of ch.lines) for (const t of view.lines.get(ln) || []) picked.add(t);
        if (!picked.size) for (const arr of view.lines.values()) for (const t of arr) picked.add(t);
        for (const t of picked) add(m.id, t);
      }
      if (!mapped) unmapped.push(ch.path);
    }
    return { runs, unmapped };
  }

  // ── changed lines (git) ───────────────────────────────────────────────────
  function git(cwd, args) {
    return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", maxBuffer: 64 << 20 });
  }
  function diffLines(root, base) {
    const top = git(root, ["rev-parse", "--show-toplevel"]).trim();
    const out = new Map();   // abs path -> { lines:Set, untracked }
    const rel = path.relative(top, root).replace(/\\/g, "/") || ".";
    const diff = git(top, ["diff", "-U0", "--no-color", "--no-ext-diff", base, "--", rel]);
    let cur = null;
    for (const l of diff.split("\n")) {
      if (l.startsWith("+++ ")) {
        const p = l.slice(4).trim();
        cur = p === "/dev/null" ? null : path.join(top, p.replace(/^b\//, ""));
        if (cur && !out.has(cur)) out.set(cur, { lines: new Set(), untracked: false });
      } else if (cur && l.startsWith("@@")) {
        const m = l.match(/\+(\d+)(?:,(\d+))?/);
        if (!m) continue;
        const start = Number(m[1]), n = m[2] == null ? 1 : Number(m[2]);
        for (let i = 0; i < n; i++) out.get(cur).lines.add(start + i);
      }
    }
    for (const p of git(top, ["ls-files", "--others", "--exclude-standard", "--", rel]).split("\n")) {
      if (!p.trim()) continue;
      const abs = path.join(top, p.trim());
      let n = 0;
      try { n = fs.readFileSync(abs, "utf8").split("\n").length; } catch (_) { continue; }
      out.set(abs, { lines: new Set(Array.from({ length: n }, (_, i) => i + 1)), untracked: true });
    }
    return out;
  }

  function changes(mod, base) {
    let diff;
    try { diff = diffLines(mod.root, base || "HEAD"); }
    catch (e) { return { error: String(e.stderr || e.message || e).trim() }; }
    const files = [];
    const tot = { changed: 0, executable: 0, covered: 0, uncovered: 0, stale: 0, unmeasured: 0 };
    for (const [abs, d] of diff) {
      if (!/\.lua$/i.test(abs)) continue;
      const fk = key(abs);
      const lines = [...d.lines].sort((a, b) => a - b);
      const row = { path: abs.replace(/\\/g, "/"), name: path.relative(mod.root, abs).replace(/\\/g, "/"), untracked: d.untracked, isTest: TEST_FILE.test(fk), changed: lines };
      tot.changed += lines.length;
      if (row.isTest) { files.push(row); continue; }
      const meas = measure(mod.id, fk, abs);
      if (!meas) { row.status = "unmeasured"; tot.unmeasured++; files.push(row); continue; }
      row.runId = meas.runId;
      if (meas.stale) { row.status = "stale"; tot.stale++; files.push(row); continue; }
      row.status = "measured";
      row.complete = meas.complete;
      row.covered = lines.filter((l) => meas.hit.has(l));
      row.uncovered = lines.filter((l) => meas.points.has(l) && !meas.hit.has(l));
      row.executable = row.covered.length + row.uncovered.length;
      tot.executable += row.executable; tot.covered += row.covered.length; tot.uncovered += row.uncovered.length;
      files.push(row);
    }
    files.sort((a, b) => (b.uncovered?.length || 0) - (a.uncovered?.length || 0) || a.name.localeCompare(b.name));
    return { base: base || "HEAD", files, totals: tot };
  }

  return { whoCovers, lineCounts, impactedBy, changes, diffLines, key };
};
