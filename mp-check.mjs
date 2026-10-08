#!/usr/bin/env node
// SousVide MP checks: run a mod's multiplayer scenarios against a fresh MP
// session (a server JVM + client JVMs, packets across the Pass) and assert on
// what each side returns. Needs the dashboard (pztest dashboard).
//
//   node mp-check.mjs <scenario.mjs> [<scenario.mjs> ...]
//
// A scenario module exports:
//   export const mod = "VorpallySauced";
//   export const clients = 1;
//   export const steps = [
//     { name: "...", side: "server" | "c1" | ..., lua: "... return <string> ...",
//       expect: /regex/ (the returned string must match),
//       save: { key: /regex with one group/ } (optional: captured into vars) },
//   ];
// "{{key}}" in a step's lua is replaced by a value saved earlier, so a step
// on a client can name the item a server step created.
//
// Wire cost: a step with `wire: { packets: N, bytes: B }` counts every packet
// that step sent across the Pass (the engine's own serialised bytes), appends
// "| wire <n> packets <b> bytes (<kind> <n>/<b>, ...)" to its result, and
// fails if either budget is exceeded. `wire: {}` just reports.
//
// It never touches a session that is already running (someone may be working
// in it): it refuses, and says so. It always stops the session it started.

import { pathToFileURL } from "node:url";
import path from "node:path";

const BASE = process.env.SOUSVIDE_URL || "http://127.0.0.1:8760";

async function api(mod, action, body) {
    const r = await fetch(`${BASE}/api/mp/${mod}/${action}`, body === undefined ? {} : {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    const t = await r.text();
    let j;
    try { j = JSON.parse(t); } catch { throw new Error(`${action}: ${r.status} ${t.slice(0, 300)}`); }
    if (!r.ok) throw new Error(`${action}: ${r.status} ${j.error || t.slice(0, 300)}`);
    return j;
}

async function runScenario(file) {
    const sc = await import(pathToFileURL(path.resolve(file)).href);
    const mod = sc.mod;
    const name = path.basename(file);
    const st = await api(mod, "status");
    if (st.state && st.state !== "idle") {
        console.log(`${name}: SKIPPED -- an MP session for ${mod} is already running (${st.state}); stop it first (mp_status stop)`);
        return { name, skipped: true, passed: 0, failed: 0 };
    }
    const vars = {};
    let passed = 0, failed = 0;
    console.log(`\n=== ${name} (${mod}, ${sc.clients || 1} client(s)) ===`);
    const startBody = { clients: sc.clients || 1 };
    if (luaMods) startBody.luaMods = luaMods;
    if (full) startBody.full = true;
    const boot = await api(mod, "start", startBody);
    if (boot.state !== "ready") throw new Error(`session did not start: ${boot.error || boot.state}`);
    if (luaMods) {
        // what loaded beside the mod, and what of it broke (vanilla noise apart)
        for (const [side, b] of Object.entries(boot.boot || {})) {
            const errs = Array.isArray(b && b.modErrors) ? b.modErrors : [];
            console.log(`  [mods] ${side}: ${Array.isArray(b && b.activeMods) ? b.activeMods.length : "?"} mods, ${errs.length} mod error(s)` +
                (errs.length ? ": " + errs.map((e) => `${e.mod} (${e.at})`).join(", ") : ""));
        }
    }
    try {
        for (const s of sc.steps) {
            const lua = s.lua.replace(/\{\{(\w+)\}\}/g, (_, k) => (k in vars ? String(vars[k]) : `{{${k}}}`));
            let before = 0;
            if (s.wire) {
                const p0 = await api(mod, "pass");
                for (const e of p0.packets || []) if (e.seq > before) before = e.seq;
            }
            let value, err;
            try {
                const r = await api(mod, "eval", { side: s.side, lua });
                value = r && r.result ? r.result.value : undefined;
            } catch (e) { err = e.message; }
            let text = err ? `ERROR ${err}` : String(value);
            let wireOk = true;
            if (s.wire && !err) {
                const p1 = await fetch(`${BASE}/api/mp/${mod}/pass?since=${before}`).then((r) => r.json());
                const pk = (p1.packets || []).filter((e) => e.kind && e.kind !== "storm" && !e.dropped);
                const by = {};
                let bytes = 0;
                for (const e of pk) {
                    const k = e.kind + (e.module ? `:${e.module}/${e.command}` : "");
                    by[k] = by[k] || { n: 0, b: 0 };
                    by[k].n++; by[k].b += e.size || 0; bytes += e.size || 0;
                }
                const parts = Object.entries(by).map(([k, v]) => `${k} ${v.n}/${v.b}`).join(", ");
                text += ` | wire ${pk.length} packets ${bytes} bytes (${parts})`;
                if (s.wire.packets != null && pk.length > s.wire.packets) wireOk = false;
                if (s.wire.bytes != null && bytes > s.wire.bytes) wireOk = false;
                vars._wirePackets = pk.length; vars._wireBytes = bytes;
            }
            const ok = !err && wireOk && (!s.expect || s.expect.test(text));
            if (ok && s.save) {
                for (const [k, re] of Object.entries(s.save)) {
                    const m = text.match(re);
                    if (m) vars[k] = m[1];
                }
            }
            console.log(`  [${ok ? "PASS" : "FAIL"}] ${s.side.padEnd(6)} ${s.name}\n         -> ${process.env.MPCHECK_FULL ? text : text.slice(0, 400)}`);
            if (ok) passed++; else failed++;
        }
    } finally {
        if (keep) console.log(`  [keep] the session stays up for inspection (mp_pass, mp_eval); stop it with mp_status stop`);
        else await api(mod, "stop", {}).catch(() => {});
    }
    return { name, passed, failed };
}

// --lua-mods <file.json>: run every scenario with other mods' Lua loaded too
// (a JSON array of specs, or {"luaMods": [...]}; docs/lua-mods.md). The
// interop smoke test: the mod's own checks, with popular mods beside it.
const argv = process.argv.slice(2);
let luaMods = null;
const lmAt = argv.indexOf("--lua-mods");
if (lmAt >= 0) {
    const fsMod = await import("node:fs");
    const j = JSON.parse(fsMod.readFileSync(argv[lmAt + 1], "utf8"));
    luaMods = Array.isArray(j) ? j : j.luaMods;
    argv.splice(lmAt, 2);
}
// --full: every vanilla file of each side's folders loads first (full mode)
const fullAt = argv.indexOf("--full");
const full = fullAt >= 0;
if (full) argv.splice(fullAt, 1);
// --keep: leave the (last) session running afterwards, to inspect it
const keepAt = argv.indexOf("--keep");
const keep = keepAt >= 0;
if (keep) argv.splice(keepAt, 1);
const files = argv;
if (files.length === 0) {
    console.error("usage: node mp-check.mjs [--lua-mods <file.json>] [--full] [--keep] <scenario.mjs> [...]");
    process.exit(2);
}
let total = 0, bad = 0, skipped = 0;
for (const f of files) {
    try {
        const r = await runScenario(f);
        if (r.skipped) { skipped++; continue; }
        total += r.passed + r.failed;
        bad += r.failed;
    } catch (e) {
        console.log(`${f}: ERROR ${e.message}`);
        bad++;
    }
}
console.log(`\nMP CHECKS: ${total} steps, ${total - bad} passed, ${bad} failed${skipped ? `, ${skipped} scenario(s) skipped` : ""}`);
process.exit(bad > 0 ? 1 : 0);
