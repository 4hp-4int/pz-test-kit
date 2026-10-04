/*
 * PZ Test Kit dashboard: fidelity
 * ===============================
 * "How real was the world this suite ran in?" Three views:
 *
 *   inventory()        kit-wide: which PZ classes run REAL in engine mode, the
 *                      PZEngine API, and a changelog of when each became real
 *                      (git history of the engine/mock/stub files, plus what
 *                      the working tree adds on top of HEAD).
 *   forMod(mod, rep)   the mod's own PZ API surface (identifiers in its Lua
 *                      that are PZ globals, Java globals or Lua-exposed
 *                      classes), each classified by the layer that provided it
 *                      in the run (engine / vanilla / mock / kit / mod) or as
 *                      UNMODELED (absent offline), joined with call counts
 *                      from --fidelity.
 *
 * The PZ API universe comes from local oracles, never a hand list:
 *   LuaManager.java @LuaMethod names (Java global functions), the java-api
 *   index (Lua-exposed classes) and the vanilla-lua globals index.
 */
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const DECOMP = "C:/Tools/ZomboidDecompiler/ZomboidDecompiler/bin/output/source";
const DEVTOOLS = "C:/Users/Khalen/Code/pz-dev-tools/indexes";

module.exports = function createFidelity({ KIT }) {
  // ── PZ API universe ───────────────────────────────────────────────────────
  let universe = null;
  function loadUniverse() {
    if (universe) return universe;
    const u = new Map();   // name -> "java-global" | "class" | "vanilla-lua"
    try {
      const src = fs.readFileSync(path.join(DECOMP, "zombie/Lua/LuaManager.java"), "utf8");
      for (const m of src.matchAll(/@LuaMethod\(\s*name\s*=\s*"([A-Za-z_]\w*)"/g)) u.set(m[1], "java-global");
    } catch (_) { /* no decompile on this machine */ }
    try {
      for (const f of fs.readdirSync(path.join(DEVTOOLS, "java-api"))) {
        if (!f.endsWith(".txt")) continue;
        const head = fs.readFileSync(path.join(DEVTOOLS, "java-api", f), "utf8").slice(0, 400);
        if (/@UsedFromLua: Yes/.test(head)) { const n = f.slice(0, -4); if (!u.has(n)) u.set(n, "class"); }
      }
    } catch (_) {}
    try {
      for (const l of fs.readFileSync(path.join(DEVTOOLS, "vanilla-lua/globals.txt"), "utf8").split("\n")) {
        const m = l.match(/^([A-Za-z_]\w*)\s+\S/);
        if (m && !u.has(m[1])) u.set(m[1], "vanilla-lua");
      }
    } catch (_) {}
    universe = u;
    return u;
  }

  // ── mod source scan ───────────────────────────────────────────────────────
  // Strip comments and strings, then take identifiers that aren't field
  // accesses (no leading . or :) and aren't declared local in that file.
  function scanLua(text) {
    text = text.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, " ").replace(/--[^\n]*/g, " ")
      .replace(/\[(=*)\[[\s\S]*?\]\1\]/g, '""').replace(/"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/g, '""');
    const locals = new Set();
    for (const m of text.matchAll(/\blocal\s+function\s+([A-Za-z_]\w*)|\blocal\s+([A-Za-z_][\w\s,]*?)(?==|\n|$)/g)) {
      if (m[1]) locals.add(m[1]);
      else for (const n of m[2].split(",")) locals.add(n.trim());
    }
    for (const m of text.matchAll(/\bfunction\s*[A-Za-z_.:\w]*\(([^)]*)\)/g)) for (const n of m[1].split(",")) locals.add(n.trim());
    for (const m of text.matchAll(/\bfor\s+([\w\s,]+?)\s+(?:=|in)\b/g)) for (const n of m[1].split(",")) locals.add(n.trim());
    const hits = new Map();
    for (const m of text.matchAll(/(^|[^.:\w])([A-Za-z_]\w*)/g)) {
      const n = m[2];
      if (locals.has(n)) continue;
      hits.set(n, (hits.get(n) || 0) + 1);
    }
    return hits;
  }
  function walk(dir, out = []) {
    let ents = [];
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return out; }
    for (const e of ents) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { if (!/^(\.git|node_modules|Tests?|tests)$/.test(e.name)) walk(p, out); }
      else if (e.name.endsWith(".lua") && !/Tests?\.lua$|^test_/.test(e.name)) out.push(p);
    }
    return out;
  }

  function forMod(mod, report) {
    const u = loadUniverse();
    const uses = new Map();   // name -> { refs, files:Set }
    for (const f of walk(path.join(mod.root, "media", "lua"))) {
      let text;
      try { text = fs.readFileSync(f, "utf8"); } catch (_) { continue; }
      for (const [n, c] of scanLua(text)) {
        if (!u.has(n)) continue;
        let x = uses.get(n);
        if (!x) uses.set(n, (x = { refs: 0, files: new Set() }));
        x.refs += c;
        x.files.add(path.relative(mod.root, f).replace(/\\/g, "/"));
      }
    }
    const fid = report && report.fidelity;
    const rows = [...uses].map(([name, x]) => {
      const layer = fid && fid.layers[name];
      const calls = fid && fid.calls[name];
      return {
        name, api: u.get(name), refs: x.refs, files: [...x.files].sort(),
        layer: layer ? layer[0] : (fid ? "absent" : null), kind: layer ? layer[1] : null, overrode: layer ? layer[2] : null,
        calls: calls ? calls[0] : 0, callFiles: calls ? calls[1] : 0,
      };
    });
    const order = { absent: 0, mock: 1, kit: 2, mod: 3, vanilla: 4, engine: 5 };
    rows.sort((a, b) => (order[a.layer] ?? 9) - (order[b.layer] ?? 9) || b.refs - a.refs);
    const mocksCalled = fid ? Object.entries(fid.calls)
      .map(([name, [calls, files]]) => ({ name, calls, files, layer: (fid.layers[name] || [])[0] || "?" }))
      .sort((a, b) => b.calls - a.calls) : [];
    const counts = {};
    for (const r of rows) counts[r.layer || "unknown"] = (counts[r.layer || "unknown"] || 0) + 1;
    return {
      hasFidelity: !!fid, universe: { size: u.size }, surface: rows, counts, calls: mocksCalled,
      layers: fid ? Object.entries(fid.layers).reduce((a, [, v]) => { a[v[0]] = (a[v[0]] || 0) + 1; return a; }, {}) : null,
      overrides: fid ? Object.entries(fid.layers).filter(([, v]) => v[2]).map(([n, v]) => ({ name: n, layer: v[0], over: v[2] })) : [],
      synthAtBoot: fid ? fid.synthAtBoot : null, synthRuntime: fid ? fid.synthRuntime : [],
    };
  }

  // ── kit-wide inventory + changelog ────────────────────────────────────────
  function git(args) { return execFileSync("git", ["-C", KIT, ...args], { encoding: "utf8", maxBuffer: 32 << 20 }); }
  function exposedFrom(src) {
    const block = (src.match(/DEFAULT_EXPOSED\s*=\s*\{([\s\S]*?)\};/) || [])[1] || "";
    return [...block.matchAll(/"([\w.$]+)"/g)].map((m) => m[1]);
  }
  const apiFrom = (src) => [...new Set([...src.matchAll(/pzEngine\.rawset\("([A-Za-z_]\w*)"/g)].map((m) => m[1]))].sort();

  function inventory() {
    const rel = "kahlua/EngineBridge.java";
    let work = "", head = "";
    try { work = fs.readFileSync(path.join(KIT, rel), "utf8"); } catch (_) {}
    try { head = git(["show", "HEAD:" + rel]); } catch (_) {}
    const exposedNow = exposedFrom(work), exposedHead = new Set(exposedFrom(head));
    const apiNow = apiFrom(work), apiHead = new Set(apiFrom(head));
    let log = [];
    try {
      log = git(["log", "--format=%h%x09%ad%x09%s", "--date=short", "-n", "60", "--",
        "kahlua/EngineBridge.java", "kahlua/stubs", "kahlua/mock_environment.lua", "kahlua/Fixtures.lua",
        "kahlua/TimedActionSim.lua", "kahlua/StubbingClassLoader.java", "kahlua/UIMock.lua"])
        .split("\n").filter(Boolean).map((l) => { const [h, d, ...s] = l.split("\t"); return { hash: h, date: d, subject: s.join("\t") }; });
    } catch (_) {}
    // When did each real class / API first appear? (pickaxe per name is too
    // slow for every name; one log -p over the file, scanned oldest-first.)
    const firstSeen = {};
    try {
      const patch = git(["log", "--reverse", "--format=@@C %h %ad", "--date=short", "-p", "--", rel]);
      let cur = null;
      for (const l of patch.split("\n")) {
        if (l.startsWith("@@C ")) { const [, h, d] = l.split(" "); cur = { hash: h, date: d }; continue; }
        if (!cur || !l.startsWith("+")) continue;
        for (const m of l.matchAll(/"(zombie\.[\w.$]+|java\.util\.\w+)"/g)) if (!firstSeen[m[1]]) firstSeen[m[1]] = cur;
        for (const m of l.matchAll(/pzEngine\.rawset\("([A-Za-z_]\w*)"/g)) if (!firstSeen["PZEngine." + m[1]]) firstSeen["PZEngine." + m[1]] = cur;
      }
    } catch (_) {}
    const stubs = [];
    (function w(d) {
      let ents = [];
      try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch (_) { return; }
      for (const e of ents) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) w(p);
        else if (e.name.endsWith(".java")) stubs.push(path.relative(path.join(KIT, "kahlua", "stubs"), p).replace(/\\/g, "/").replace(/\.java$/, "").replace(/\//g, "."));
      }
    })(path.join(KIT, "kahlua", "stubs"));
    return {
      exposed: exposedNow.map((c) => ({ name: c, since: firstSeen[c] || null, pending: !exposedHead.has(c) })),
      api: apiNow.map((n) => ({ name: n, since: firstSeen["PZEngine." + n] || null, pending: !apiHead.has(n) })),
      stubs: stubs.sort(), log,
      dirty: (() => { try { return git(["status", "--porcelain", "--", "kahlua"]).split("\n").filter(Boolean).map((l) => l.slice(3)); } catch (_) { return []; } })(),
    };
  }

  return { forMod, inventory };
};
