#!/usr/bin/env node
// The event lab's catalog: every Lua event the engine registers, and every
// place that fires one -- Java (LuaEventManager.triggerEvent*) and vanilla Lua
// (triggerEvent) -- with each argument's expression and, for Java, its type
// inferred from the call site (`this`, casts, literals, local / parameter /
// field declarations). The lab offers argument builders from these.
//
//   node events-catalog.js [decompiled-source-root] [pz-install]
//
// Writes ../events-catalog.json. Regenerate after a PZ update.

const fs = require("fs");
const path = require("path");

const SRC = process.argv[2] || "C:/Tools/ZomboidDecompiler/ZomboidDecompiler/bin/output/source";
const PZ = process.argv[3] || "C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid";
const OUT = path.join(__dirname, "..", "events-catalog.json");

function walk(dir, ext, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, ext, out);
    else if (e.name.endsWith(ext)) out.push(p);
  }
  return out;
}

// Text from an opening paren to its match (strings and chars respected).
function callArgs(text, open) {
  let depth = 0, i = open, q = null;
  for (; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === "\\") { i++; continue; } if (c === q) q = null; continue; }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === "(") depth++;
    else if (c === ")") { depth--; if (!depth) break; }
  }
  return text.slice(open + 1, i);
}

function splitTop(s) {
  const out = [];
  let depth = 0, q = null, cur = "";
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { cur += c; if (c === "\\") { cur += s[++i] || ""; continue; } if (c === q) q = null; continue; }
    if (c === '"' || c === "'") { q = c; cur += c; continue; }
    if ("([{<".includes(c)) depth++;
    if (")]}>".includes(c)) depth--;
    if (c === "," && depth === 0) { out.push(cur.trim()); cur = ""; continue; }
    cur += c;
  }
  if (cur.trim()) out.push(cur.trim());
  return out.map((x) => x.replace(/\s+/g, " "));
}

const lineOf = (text, idx) => text.slice(0, idx).split("\n").length;
const PRIM = /^(int|float|double|long|short|byte|boolean|char|String|Integer|Float|Double|Long|Boolean)$/;

// The type of `name` as declared nearest above `idx` (locals, parameters,
// pattern bindings), else as a field of the file's class.
function declType(text, idx, name) {
  const before = text.slice(Math.max(0, idx - 12000), idx);
  const re = new RegExp(`(?:^|[\\s(,])((?:final\\s+)?[A-Z][\\w.]*(?:<[^>()]*>)?(?:\\[\\])?|int|float|double|long|short|byte|boolean|char)\\s+${name}\\b\\s*(?=[=;,):])`, "g");
  let m, last = null;
  while ((m = re.exec(before))) last = m[1].replace(/^final\s+/, "");
  if (last) return last;
  const f = new RegExp(`\\b(?:private|protected|public|static|final|\\s)+\\s*([A-Z][\\w.]*(?:<[^>()]*>)?|int|float|double|long|boolean)\\s+${name}\\s*[=;]`).exec(text);
  return f ? f[1] : null;
}

function enclosingClass(text, idx) {
  const before = text.slice(0, idx);
  const re = /\b(?:class|enum|record)\s+(\w+)/g;
  let m, last = null;
  while ((m = re.exec(before))) last = m[1];
  return last;
}

function inferType(expr, text, idx) {
  let e = expr.trim();
  if (e === "this") return enclosingClass(text, idx);
  if (e === "null") return "null";
  if (/^"/.test(e)) return "String";
  if (/^(true|false)$/.test(e)) return "boolean";
  if (/^-?\d+(\.\d+)?[fFdDlL]?$/.test(e)) return /[.fFdD]/.test(e) ? "float" : "int";
  const cast = /^\(\s*([A-Z][\w.]*|int|float|double|long|boolean)\s*\)/.exec(e);
  if (cast) return cast[1];
  if (/^new\s+([A-Z][\w.]*)/.test(e)) return /^new\s+([A-Z][\w.]*)/.exec(e)[1];
  const f = /^this\.(\w+)$/.exec(e);
  if (f) return declType(text, idx, f[1]);
  if (/^\w+$/.test(e)) return declType(text, idx, e);
  if (/^(Integer|Float|Double|Long|Boolean)\.valueOf\(/.test(e)) return e.split(".")[0];
  if (/^BoxedStaticValues\.toDouble\(/.test(e)) return "Double";
  const getter = /\.?(get\w+|is\w+)\(\)$/.exec(e);
  return getter ? "?" + getter[1] : null;
}

const catalog = {};
const ev = (name) => (catalog[name] = catalog[name] || { name, registered: false, java: [], lua: [] });

// 1) registrations
const lem = fs.readFileSync(path.join(SRC, "zombie/Lua/LuaEventManager.java"), "utf8");
for (const m of lem.matchAll(/AddEvent\("(\w+)"\)/g)) ev(m[1]).registered = true;

// 2) Java fire sites
for (const file of walk(path.join(SRC, "zombie"), ".java")) {
  const text = fs.readFileSync(file, "utf8");
  if (!text.includes("triggerEvent")) continue;
  const rel = path.relative(path.join(SRC), file).replace(/\\/g, "/");
  for (const m of text.matchAll(/triggerEvent(?:Garbage|Unique)?\s*\(/g)) {
    const open = m.index + m[0].length - 1;
    const parts = splitTop(callArgs(text, open));
    const nm = /^"(\w+)"$/.exec(parts[0] || "");
    if (!nm) continue;
    if (rel.endsWith("LuaEventManager.java")) continue;
    ev(nm[1]).java.push({
      file: rel, line: lineOf(text, m.index), in: enclosingClass(text, m.index),
      args: parts.slice(1).map((a) => ({ expr: a, type: inferType(a, text, m.index) })),
    });
  }
}

// 3) vanilla Lua fire sites
const luaRoot = path.join(PZ, "media", "lua");
if (fs.existsSync(luaRoot)) {
  for (const file of walk(luaRoot, ".lua")) {
    const text = fs.readFileSync(file, "utf8");
    if (!text.includes("triggerEvent")) continue;
    const rel = path.relative(luaRoot, file).replace(/\\/g, "/");
    for (const m of text.matchAll(/\btriggerEvent\s*\(/g)) {
      const parts = splitTop(callArgs(text, m.index + m[0].length - 1));
      const nm = /^"(\w+)"$/.exec(parts[0] || "");
      if (nm) ev(nm[1]).lua.push({ file: rel, line: lineOf(text, m.index), args: parts.slice(1).map((a) => ({ expr: a })) });
    }
  }
}

// 4) a signature per event: the most common Java arity, each position's
// most common concrete type (an inferred getter name is a fallback hint).
for (const e of Object.values(catalog)) {
  const sites = e.java.length ? e.java : e.lua;
  const byArity = new Map();
  for (const s of sites) byArity.set(s.args.length, (byArity.get(s.args.length) || 0) + 1);
  const arity = [...byArity].sort((a, b) => b[1] - a[1])[0];
  if (!arity) { e.params = []; continue; }
  e.params = [];
  for (let i = 0; i < arity[0]; i++) {
    const types = new Map(), exprs = new Map();
    for (const s of sites) {
      const a = s.args[i];
      if (!a) continue;
      exprs.set(a.expr, (exprs.get(a.expr) || 0) + 1);
      if (a.type && a.type !== "null") types.set(a.type, (types.get(a.type) || 0) + 1);
    }
    // A tie goes to the more general type (IsoGameCharacter over IsoAnimal).
    const GENERAL = ["IsoGameCharacter", "IsoMovingObject", "IsoObject", "InventoryItem", "Object"];
    const rank = (t) => { const i = GENERAL.indexOf(t); return i < 0 ? 99 : i; };
    const concrete = [...types].filter(([t]) => !t.startsWith("?")).sort((a, b) => b[1] - a[1] || rank(a[0]) - rank(b[0]));
    const hinted = [...types].sort((a, b) => b[1] - a[1]);
    const name = [...exprs].sort((a, b) => b[1] - a[1])[0][0].replace(/^this\./, "").replace(/^\(.*?\)\s*/, "");
    const type = (concrete[0] || hinted[0] || [null])[0];
    let pname = /^\w+$/.test(name) ? name : "arg" + (i + 1);
    if (pname === "this" && type) pname = type.replace(/^Iso/, "").replace(/^./, (c) => c.toLowerCase());
    e.params.push({ name: pname, type });
  }
}

const out = { generated: new Date().toISOString(), source: SRC, events: Object.values(catalog).sort((a, b) => a.name.localeCompare(b.name)) };
fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
const fired = out.events.filter((e) => e.java.length || e.lua.length).length;
console.log(`${out.events.length} events (${out.events.filter((e) => e.registered).length} registered, ${fired} with fire sites) -> ${OUT}`);
