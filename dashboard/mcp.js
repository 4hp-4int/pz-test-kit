#!/usr/bin/env node
/*
 * SousVide MCP server: the sealed engine as tools an agent can call.
 *
 * SousVide is the DS Mods name for the pz-test-kit engine VM -- Project
 * Zomboid B42's real projectzomboid.jar running a mod's Lua headless, sealed
 * off from the renderer and held at an exact, replayable state. The
 * Workbench board (/workbench) is its browser face.
 *
 * stdio JSON-RPC 2.0 (MCP), no dependencies. Every tool goes through the
 * dashboard's HTTP API (dashboard/workbench.js), so an agent and the browser
 * drive the SAME live engine VMs: what the agent loads, crafts or reloads
 * shows up on the board, and the reverse. The dashboard is started if it is
 * not already running.
 *
 *   node pz-test-kit/dashboard/mcp.js
 *   env: PZTEST_DASH_URL (default http://127.0.0.1:8760)
 */
"use strict";
const http = require("http");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { spawn } = require("child_process");

const BASE = process.env.PZTEST_DASH_URL || "http://127.0.0.1:8760";
const KIT = path.resolve(__dirname, "..");
const MONO = path.resolve(KIT, "..");

// ── HTTP to the dashboard ───────────────────────────────────────────────────
function request(method, p, body, timeoutMs = 600000) {
  return new Promise((resolve, reject) => {
    const u = new URL(p, BASE);
    const data = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = http.request(u, { method, headers: data ? { "Content-Type": "application/json", "Content-Length": data.length } : {}, timeout: timeoutMs }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        try { resolve(JSON.parse(text)); } catch (_) { resolve({ raw: text }); }
      });
    });
    req.on("timeout", () => req.destroy(new Error("timed out")));
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}

let started = null;
async function ensureDashboard() {
  try { await request("GET", "/api/wb/mods", undefined, 3000); return; } catch (_) {}
  if (!started) {
    const port = new URL(BASE).port || "8760";
    started = spawn(process.execPath, [path.join(__dirname, "server.js"), port], { cwd: KIT, detached: true, stdio: "ignore", windowsHide: true });
    started.unref();
  }
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 500));
    try { await request("GET", "/api/wb/mods", undefined, 2000); return; } catch (_) {}
  }
  throw new Error("dashboard did not come up at " + BASE);
}

async function call(mod, tool, args) {
  await ensureDashboard();
  const r = await request("POST", `/api/wb/${encodeURIComponent(mod)}/call`, { tool, args: args || {} });
  if (r.ok === false || r.error) throw new Error(r.error || JSON.stringify(r));
  const v = r.value;
  if (v && typeof v === "object" && v.error) throw new Error(String(v.error));
  return { value: v, out: r.out };
}

// ── SousVide MP (dashboard/mp.js): server + client sides and the Pass ────
async function mp(mod, action, body, method) {
  await ensureDashboard();
  const r = await request(method || "POST", `/api/mp/${encodeURIComponent(mod)}/${action}`, body);
  if (r && r.error) throw new Error(r.error);
  return r;
}
const SIDE = { type: "string", description: "\"server\" or a client: \"c1\", \"c2\"..." };

// ── tests: pztest with a JSON report ───────────────────────────────────────
function bashPath() {
  for (const c of [process.env.PZTEST_BASH, "C:/Program Files/Git/bin/bash.exe", "C:/Program Files/Git/usr/bin/bash.exe", "bash"]) {
    if (c && (c === "bash" || fs.existsSync(c))) return c;
  }
  return "bash";
}
function runTests(modRoot, only) {
  return new Promise((resolve) => {
    const report = path.join(os.tmpdir(), `pzwb-mcp-${process.pid}-${Date.now()}.json`);
    const args = [path.join(KIT, "pztest"), "--report-json", report];
    if (only) args.push("--only", only);
    const proc = spawn(bashPath(), args, { cwd: modRoot, windowsHide: true });
    let log = "";
    proc.stdout.on("data", (c) => { log += c; });
    proc.stderr.on("data", (c) => { log += c; });
    proc.on("close", (code) => {
      let rep = null;
      try { rep = JSON.parse(fs.readFileSync(report, "utf8")); fs.unlinkSync(report); } catch (_) {}
      if (!rep) return resolve({ code, error: "no report written", tail: log.slice(-3000) });
      const failing = [];
      for (const f of rep.files || []) {
        if (f.error) failing.push({ file: f.file, error: f.error });
        for (const c of f.cases || []) if (c.status !== "pass" && c.status !== "skip") failing.push({ file: f.file, test: c.name, status: c.status, output: String(c.output || "").slice(-1500) });
      }
      resolve({ totals: rep.totals, engine: rep.engine, gameVersion: rep.gameVersion, failing });
    });
  });
}

// SousVide Live (live.js): the RUNNING dedi through pz-shell, called directly
// (no dashboard needed)
const live = require("./live");
function liveResult(r) { return r && r.ok === false && r.err ? { ok: false, out: r.out, error: r.err } : { ok: true, out: r.out }; }

// ── tools ───────────────────────────────────────────────────────────────────
const MOD = { type: "string", description: "Mod id as the dashboard lists it (the `mods` tool), e.g. VorpallySauced, SauceTweaks" };
const TOOLS = [
  {
    name: "flow_selection",
    description: "SousVide Flow: what the programmer selected in the flow chart (http://127.0.0.1:8760/flow) and what they asked for (e.g. \"summarize\"). Returns the map (mod + name), each selected block with its code slice, doc comment and current summary, the edges among them, and the BOUNDARY: edges crossing in (what the region depends on) and out (what relies on it). Use it as the context for the request.",
    inputSchema: { type: "object", properties: {} },
    run: async () => { await ensureDashboard(); return request("GET", "/api/flow/selection"); },
  },
  {
    name: "flow_summarize",
    description: "SousVide Flow: write summaries onto blocks of a flow chart (one plain sentence each: what data comes in, what the block does with it, what goes out). Stored beside the map in flow/<name>.summaries.json, keyed to a hash of each block's code, so a summary goes stale when its code changes. The viewer shows them live.",
    inputSchema: { type: "object", properties: {
      mod: { type: "string", description: "the map's folder, as flow_selection returns it (e.g. vps-leaderboard)" },
      name: { type: "string", description: "the map's name (e.g. system)" },
      summaries: { type: "object", description: "{ blockId: sentence }", additionalProperties: { type: "string" } },
      by: { type: "string", description: "who wrote them (default: agent)" },
    }, required: ["mod", "name", "summaries"] },
    run: async (a) => { await ensureDashboard(); return request("POST", "/api/flow/summaries", { mod: a.mod, name: a.name, summaries: a.summaries, by: a.by || "agent" }); },
  },
  {
    name: "flow_plan",
    description: "SousVide Flow: before a change, show the operator which blocks you intend to touch. They light up on the flow chart; the operator approves, trims (trimmed blocks become locked) or rejects, and the answer reaches you on your next tool call. Use block ids from the map (flow_selection returns them).",
    inputSchema: { type: "object", properties: {
      mod: { type: "string" }, name: { type: "string" },
      ids: { type: "array", items: { type: "string" }, description: "block ids you plan to edit" },
      note: { type: "string", description: "one or two sentences: what you will change and why" },
    }, required: ["mod", "name", "ids", "note"] },
    run: async (a) => { await ensureDashboard(); return request("POST", "/api/flow/plan", { mod: a.mod, name: a.name, ids: a.ids, note: a.note }); },
  },
  {
    name: "flow_step",
    description: "SousVide Flow work journal: say what you are doing and why, so the operator can follow. op open: start a step (title = what, in a few words; why = the reason; task defaults to the active task); every read, edit, command and test run until the next step is filed under it. op close: end it with result (what you found or what changed) and status done | failed | changed (changed = the plan changed because of what you learned). op note: add a line to the open step. Open a new step whenever your intent changes; the operator reads the journal, not the raw events.",
    inputSchema: { type: "object", properties: {
      op: { type: "string", enum: ["open", "close", "note"] }, title: { type: "string" }, why: { type: "string" },
      result: { type: "string" }, status: { type: "string", enum: ["done", "failed", "changed"] }, text: { type: "string" },
      task: { type: "number" }, blocks: { type: "array", items: { type: "string" }, description: "block ids this step is about (optional; touched ones are recorded anyway)" },
    }, required: ["op"] },
    run: async (a) => { await ensureDashboard(); return request("POST", "/api/flow/steps", a); },
  },
  {
    name: "task_list",
    description: "SousVide Flow tasks: the work graph the operator watches beside the flow chart. Lists tasks (state, links, planned blocks, blocks touched while active, checks, evidence) and which one is active. Filter to one map with mod + name.",
    inputSchema: { type: "object", properties: { mod: { type: "string" }, name: { type: "string" } } },
    run: async (a) => { await ensureDashboard(); return request("GET", "/api/flow/tasks" + (a.mod ? `?mod=${encodeURIComponent(a.mod)}&name=${encodeURIComponent(a.name || "")}` : "")); },
  },
  {
    name: "task_new",
    description: "SousVide Flow: create a task. Give it the map (mod + name) and the block ids you plan to touch (planned) so drift shows; acceptance checks as short sentences; found_while = the task id you were on when you found this. activate: true makes it the active task, and every block you then read or edit is recorded on it.",
    inputSchema: { type: "object", properties: {
      title: { type: "string" }, why: { type: "string" }, mod: { type: "string" }, name: { type: "string" },
      planned: { type: "array", items: { type: "string" } }, checks: { type: "array", items: { type: "string" } },
      parent: { type: "number" }, found_while: { type: "number" }, state: { type: "string", enum: ["proposed", "planned", "active", "review", "blocked", "done", "dropped"] },
      activate: { type: "boolean" },
    }, required: ["title"] },
    run: async (a) => { await ensureDashboard(); return request("POST", "/api/flow/task", { op: "new", by: "agent", ...a }); },
  },
  {
    name: "task_update",
    description: "SousVide Flow: change a task. state (proposed|planned|active|review|blocked|done|dropped; done appends it to the map's flow/TASKS.md), activate, title, why, planned / addPlanned (block ids), addChecks, check (index) + done, evidence { kind: commit|test|probe|note, text }, parent.",
    inputSchema: { type: "object", properties: {
      id: { type: "number" }, state: { type: "string" }, activate: { type: "boolean" }, title: { type: "string" }, why: { type: "string" },
      planned: { type: "array", items: { type: "string" } }, addPlanned: { type: "array", items: { type: "string" } },
      addChecks: { type: "array", items: { type: "string" } }, check: { type: "number" }, done: { type: "boolean" },
      evidence: { type: "object", properties: { kind: { type: "string" }, text: { type: "string" } } }, parent: { type: "number" },
    }, required: ["id"] },
    run: async (a) => { await ensureDashboard(); return request("POST", "/api/flow/task", { op: "update", by: "agent", ...a }); },
  },
  {
    name: "task_link",
    description: "SousVide Flow: link two tasks. type: blocks (id must finish before to), found_while (id was found while doing to), replaces (id supersedes to), relates. unlink: true removes it.",
    inputSchema: { type: "object", properties: {
      id: { type: "number" }, type: { type: "string", enum: ["blocks", "found_while", "replaces", "relates"] }, to: { type: "number" }, unlink: { type: "boolean" },
    }, required: ["id", "type", "to"] },
    run: async (a) => { await ensureDashboard(); return request("POST", "/api/flow/task", { op: a.unlink ? "unlink" : "link", by: "agent", id: a.id, type: a.type, to: a.to }); },
  },
  {
    name: "flow_sketch",
    description: "SousVide Flow: put nodes on a map that the code does not have (yet): a planned function, a test to write, a CI job, an outside service, a note. They show as ghost tiles beside a real block (near = a block id), with edges to real blocks or other sketches (edge from/to = a block id or a sketch key; kind e.g. plan, calls, tests, runs). task ties a sketch to a task (and it can be planned on it as 'sketch:<key>'); temp: true removes it when that task is done or dropped; expect = the block id or name the code will have, and once the map has it the sketch counts as real. op: put (default) | remove (keys) | clear (all on the map, or one task's).",
    inputSchema: { type: "object", properties: {
      mod: { type: "string" }, name: { type: "string" }, op: { type: "string", enum: ["put", "remove", "clear"] },
      nodes: { type: "array", items: { type: "object", properties: {
        key: { type: "string" }, label: { type: "string" }, kind: { type: "string", enum: ["fn", "test", "check", "job", "service", "data", "note"] },
        near: { type: "string" }, task: { type: "number" }, expect: { type: "string" }, temp: { type: "boolean" }, note: { type: "string" } }, required: ["key", "label"] } },
      edges: { type: "array", items: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, kind: { type: "string" }, label: { type: "string" } }, required: ["from", "to"] } },
      keys: { type: "array", items: { type: "string" } }, task: { type: "number" },
    }, required: ["mod", "name"] },
    run: async (a) => { await ensureDashboard(); return request("POST", "/api/flow/sketch", { op: a.op || "put", ...a }); },
  },
  {
    name: "flow_notes",
    description: "SousVide Flow: notes the operator pinned on blocks of the flow chart. Without arguments, lists the open ones. With id, answers one: reply (shown under the note) and/or done: true. Notes also arrive on their own as context after your tool calls.",
    inputSchema: { type: "object", properties: {
      id: { type: "number" }, reply: { type: "string" }, done: { type: "boolean" },
    } },
    run: async (a) => {
      await ensureDashboard();
      if (a.id == null) return request("GET", "/api/flow/notes");
      return request("POST", "/api/flow/notes", { id: a.id, reply: a.reply, done: a.done });
    },
  },
  {
    name: "live_status",
    description: "SousVide Live: is the local dedicated server (Docker 'pzserver') up, and is pz-shell armed and its VM responsive? Use before the other live_* tools.",
    inputSchema: { type: "object", properties: {} },
    run: async () => { const g = await live.shell(["status"]); return { dedi: live.dediStatus().text, shell: g.out || g.err }; },
  },
  {
    name: "live_eval",
    description: "SousVide Live: run Lua in the RUNNING dedicated server's VM through pz-shell (not a sealed VM). `return` a value to see it; print() output comes back too. Dev-only: real server state, real players.",
    inputSchema: { type: "object", properties: { lua: { type: "string" } }, required: ["lua"] },
    run: async (a) => liveResult(await live.shell(["eval", "-"], a.lua)),
  },
  {
    name: "live_probe",
    description: "SousVide Live: run a canned probe from pz-test-kit/shell/examples on the running dedi (omit `name` to list them with their titles).",
    inputSchema: { type: "object", properties: { name: { type: "string", description: "e.g. probe-stir-stages.lua" } } },
    run: async (a) => {
      const list = live.probes();
      if (!a.name) return list;
      if (!list.some((p) => p.name === a.name)) throw new Error("no such probe: " + a.name);
      return liveResult(await live.shell(["eval", "-f", path.join(__dirname, "..", "shell", "examples", a.name)]));
    },
  },
  {
    name: "live_puppet",
    description: "SousVide Live: a server-side player action on the running dedi: equip <FullType>, unequip, inventory, drop, reload, damage <n>, credit-kills <n>, whoami. Acts on the first connected player unless `as` names one.",
    inputSchema: { type: "object", properties: { action: { type: "string" }, as: { type: "string" }, args: { type: "array", items: { type: "string" } } }, required: ["action"] },
    run: async (a) => {
      const args = ["puppet", a.action];
      if (a.as) args.push("--as", a.as);
      for (const x of a.args || []) args.push(String(x));
      return liveResult(await live.shell(args));
    },
  },
  {
    name: "mods",
    description: "List the mods SousVide knows (pz-mods monorepo), whether each runs on the real engine, and its VM state.",
    inputSchema: { type: "object", properties: {} },
    run: async () => { await ensureDashboard(); return request("GET", "/api/wb/mods"); },
  },
  {
    name: "eval",
    description: "Run Lua in a mod's live engine VM (real projectzomboid.jar classes, the mod's Lua loaded). `return` values come back as data; print output too. Globals: PZEngine (instanceItem, cell, loadWorld, gameTime...), WB (WB.tools.<name>(args) calls any workbench tool directly; WB.ref/deref for live objects). Use PZEngine.cell() for real squares (getCell() is a mock), with PZEngine.setServer(true) around world lookups.",
    inputSchema: { type: "object", properties: { mod: MOD, lua: { type: "string" } }, required: ["mod", "lua"] },
    run: async (a) => call(a.mod, "eval", { src: a.lua }),
  },
  {
    name: "call",
    description: "Call any workbench tool in a mod's VM. Tools: items{q}, item{fullType}, recipes{q}, recipe{name}, craftPlan{recipe}, craft{recipe, items:[{type,count,steps?,input?}|{ref}], bench?, enforce?}, addonPanels{type|ref}, addonRun{ref, addon, action, params}, addons{}, scriptTypes{}, scriptList{type,q}, scriptInfo{type,name}, worldLoad{}, worldArea{x,y,r}, worldSquare{x,y,z}, worldTiles{x0,y0,x1,y1}, worldVerbs{ref}, worldVerb{ref,verb,params}, clockStatus{}, clockAdvance{minutes,refs}, itemTooltip{ref,detail}, worldTooltip{ref}, devReload{lua,scripts}, setRandom{mode,seed}, resolvePath{expr|ref,steps}, inspect{ref}, invoke{ref,method,args}, spriteProps{sprite}, stampSprite{sprite,set,flags,unset,tileType}, stampUndo{sprite}, stampList{}, stampExport{name,folder,guard,tweak} (boot-time Lua for the stamps), recipeDraft{draft,mod} (craftRecipe text + item checks), recipeParse{text}, worldBindEntity{ref,name}, vhsTapes{q} (recorded media registry), vhsPlay{id|ref, tv?, dx?, dy?, dz?, volume?, forget?, asleep?} (play a tape through OnDeviceText; per-line halos, stat/xp/recipe/modData changes), eventList{q}, eventInfo{name} (signature, fire sites, listeners by file:line), eventFire{name, args:[{kind: player|zombie|item(ref|type)|square(x,y,z)|object(ref)|number|string|bool|lua(value)|nil}], context: sp|client|server, loadServer} (per-listener changes, halos, commands, nested events).",
    inputSchema: { type: "object", properties: { mod: MOD, tool: { type: "string" }, args: { type: "object" } }, required: ["mod", "tool"] },
    run: async (a) => call(a.mod, a.tool, a.args),
  },
  {
    name: "world_square",
    description: "The real B42 map square at world coordinates (loads the world and the surrounding chunks on first use, ~5s): room, every object's class, sprite, entity, components, containers, fluid, tile properties, and live refs for wb_call worldVerbs/worldVerb/worldTooltip.",
    inputSchema: { type: "object", properties: { mod: MOD, x: { type: "number" }, y: { type: "number" }, z: { type: "number" } }, required: ["mod", "x", "y"] },
    run: async (a) => call(a.mod, "worldSquare", { x: a.x, y: a.y, z: a.z || 0 }),
  },
  {
    name: "craft",
    description: "Run a real craftRecipe through the engine (HandcraftLogic + vanilla performRecipe + the mod's Lua hooks), gated on canPerformCurrentRecipe like the game. items: [{type, count?, steps?:[{addon,action,params}], input?: slotIndex}] or [{ref}] for live items. Workstation recipes run at a real CraftBench entity automatically; bench:false crafts in hand. Returns consumed/kept/outputs with addon panels, hooks called, commands sent.",
    inputSchema: { type: "object", properties: { mod: MOD, recipe: { type: "string" }, items: { type: "array" }, bench: {}, monitor: { type: "boolean" } }, required: ["mod", "recipe", "items"] },
    run: async (a) => call(a.mod, "craft", { recipe: a.recipe, items: a.items, qualify: true, mode: "action", enforce: true, bench: a.bench, monitor: !!a.monitor }),
  },
  {
    name: "reload",
    description: "Live dev loop: reload edited mod code into the running VM without restarting. lua: require names (e.g. 'SauceTweaks/Packing'; fresh source is read from disk, old event listeners are replaced). scripts: ScriptType names to re-parse (CraftRecipe, Entity, Fixing...; Item does not hot-reload safely -- restart the VM for item edits).",
    inputSchema: { type: "object", properties: { mod: MOD, lua: { type: "array", items: { type: "string" } }, scripts: { type: "array", items: { type: "string" } } }, required: ["mod"] },
    run: async (a) => call(a.mod, "devReload", { lua: a.lua || [], scripts: a.scripts || [] }),
  },
  {
    name: "clock",
    description: "Advance the engine's world clock: fires EveryOneMinute/TenMinutes/Hours/Days on their real boundaries and ages the given live items (refs) via the engine's own code (food rot etc.).",
    inputSchema: { type: "object", properties: { mod: MOD, minutes: { type: "number" }, refs: { type: "array", items: { type: "number" } } }, required: ["mod", "minutes"] },
    run: async (a) => call(a.mod, "clockAdvance", { minutes: a.minutes, refs: a.refs || [] }),
  },
  {
    name: "mp_start",
    description: "SousVide MP: boot a multiplayer session for a mod -- a server side (separate JVM, GameServer.server, loads shared+server like a dedi, fires OnServerStarted) and N client sides (load shared+client+server, fire OnGameStart/OnCreatePlayer), each with its player identity (cook1..cookN). Packets between them cross the Pass (the dashboard) as real TableNetworkUtils bytes. Returns each side's boot report (vanilla deps loaded, mod files run, start-event errors).",
    inputSchema: { type: "object", properties: {
      mod: MOD, clients: { type: "number", description: "1-4 (default 1)" },
      full: { type: "boolean", description: "load EVERY vanilla file of each side's folders in game order, not just the classes the mod names (default: false; true when lua_mods is given)" },
      lua_mods: { type: "array", items: { type: "string" }, description: "other mods whose Lua (and scripts) run on every side too: 'workshop:<id>/<folder>' or a path. Load order as listed, then the mod's dependencies, then the mod, each mod moved after the mods its mod.info require= names. The interop smoke test (docs/lua-mods.md). Each side's boot report: mods (files loaded/failed per mod), modErrors (mod files that failed and mod listeners that threw at a start event; vanilla's headless noise left out), activeMods." },
    }, required: ["mod"] },
    run: async (a) => mp(a.mod, "start", { clients: a.clients || 1, full: a.full, luaMods: a.lua_mods }),
  },
  {
    name: "mp_eval",
    description: "SousVide MP: run Lua on one side (getPlayer() is that side's player; nil on the server, as on a dedi), then deliver whatever it sent across the Pass (unless held). Returns the result plus the delivery summary; read mp_pass for the packets.",
    inputSchema: { type: "object", properties: { mod: MOD, side: SIDE, lua: { type: "string" } }, required: ["mod", "side", "lua"] },
    run: async (a) => mp(a.mod, "eval", { side: a.side, lua: a.lua }),
  },
  {
    name: "mp_call",
    description: "SousVide MP: call any SousVide tool (see `call`) on one side, then deliver what it sent.",
    inputSchema: { type: "object", properties: { mod: MOD, side: SIDE, tool: { type: "string" }, args: { type: "object" } }, required: ["mod", "side", "tool"] },
    run: async (a) => mp(a.mod, "call", { side: a.side, tool: a.tool, args: a.args || {} }),
  },
  {
    name: "mp_pump",
    description: "SousVide MP: control delivery. hold:true/false stops/starts automatic delivery; then n:N delivers the next N queued packets (omit: all), drop:true discards the next one, dup:true delivers the next one twice -- races and double-sends are where dupes come from.",
    inputSchema: { type: "object", properties: { mod: MOD, hold: { type: "boolean" }, n: { type: "number" }, drop: { type: "boolean" }, dup: { type: "boolean" } }, required: ["mod"] },
    run: async (a) => {
      if (a.hold !== undefined) await mp(a.mod, "hold", { on: a.hold });
      if (a.n === undefined && !a.drop && !a.dup) return mp(a.mod, "status", undefined, "GET");
      return mp(a.mod, "pump", { n: a.n, drop: a.drop, dup: a.dup });
    },
  },
  {
    name: "mp_pass",
    description: "SousVide MP: the packet log -- every packet's seq, sender, receiver, kind, module/command, size, what caused it, and per receiver: listeners run, errors, the decoded args (or for item packets: what was added/removed, 'Error: Dupe item ID' guard trips), packets it sent in turn. Plus the queue when held, and the latest AUDIT: every item ID on every side compared -- dupe (same ID twice on one side), ghost (client has it, server doesn't), missing (server has it, client never got it), diverged (location/type/condition/uses/ModData differ). Item packets: sendAddItemToContainer, sendRemoveItemFromContainer, sendReplaceItemInContainer, syncItemFields, syncItemModData, with the engine's own item bytes. since: only packets after this seq.",
    inputSchema: { type: "object", properties: { mod: MOD, since: { type: "number" } }, required: ["mod"] },
    run: async (a) => mp(a.mod, "pass?since=" + (a.since || 0), undefined, "GET"),
  },
  {
    name: "mp_world",
    description: "SousVide MP: load the same real-map box on every side and watch it (the auditor then also compares ground items and object containers there); with client: also place that client's player at x,y (the client and the server both move their copy). World changes cross the Pass: obj:transmitCompleteItemToClients / sq:AddWorldInventoryItem (worldAdd, the object's own bytes) and sq:transmitRemoveItemFromSquare (worldRemove, BY OBJECT INDEX as the real packet -- a wrong-object removal is reported).",
    inputSchema: { type: "object", properties: { mod: MOD, x: { type: "number" }, y: { type: "number" }, z: { type: "number" }, r: { type: "number" }, client: { type: "number" } }, required: ["mod", "x", "y"] },
    run: async (a) => {
      const w = await mp(a.mod, "world", { x: a.x, y: a.y, z: a.z || 0, r: a.r || 3 });
      if (a.client) w.place = await mp(a.mod, "place", { client: a.client, x: a.x, y: a.y, z: a.z || 0 });
      return w;
    },
  },
  {
    name: "mp_status",
    description: "SousVide MP: the session's sides, their state, hold, queue length and boot reports. stop:true ends the session.",
    inputSchema: { type: "object", properties: { mod: MOD, stop: { type: "boolean" } }, required: ["mod"] },
    run: async (a) => a.stop ? mp(a.mod, "stop", {}) : mp(a.mod, "status", undefined, "GET"),
  },
  {
    name: "test",
    description: "Run a mod's pz-test-kit suite (or one file via `only`, a path relative to the mod root) and return totals plus every failing case with its output.",
    inputSchema: { type: "object", properties: { mod: MOD, only: { type: "string" } }, required: ["mod"] },
    run: async (a) => {
      const root = path.join(MONO, a.mod);
      if (!fs.existsSync(path.join(root, "pz-test.lua"))) throw new Error("no pz-test.lua under " + root);
      return runTests(root, a.only);
    },
  },
];

// ── MCP stdio plumbing ──────────────────────────────────────────────────────
function send(msg) { process.stdout.write(JSON.stringify(msg) + "\n"); }
async function handle(msg) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    return send({ jsonrpc: "2.0", id, result: {
      protocolVersion: (params && params.protocolVersion) || "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "sousvide", version: "0.2.0" },
      instructions: "SousVide (the pz-test-kit engine VM): Project Zomboid B42's real engine (projectzomboid.jar) running each mod's Lua headless, with the real map, crafting, timed actions, events, recorded media, a world clock and tooltips. Prefer verifying PZ behaviour here over reasoning from decompiled source. Same VMs as the browser Workbench at " + BASE + "/workbench. The `sousvide` skill is the playbook: which tool answers which question, the headless stand-ins, and the gotchas.",
    } });
  }
  if (method === "notifications/initialized" || (method && method.startsWith("notifications/"))) return;
  if (method === "ping") return send({ jsonrpc: "2.0", id, result: {} });
  if (method === "tools/list") {
    return send({ jsonrpc: "2.0", id, result: { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) } });
  }
  if (method === "tools/call") {
    const t = TOOLS.find((x) => x.name === (params && params.name));
    if (!t) return send({ jsonrpc: "2.0", id, error: { code: -32602, message: "unknown tool " + (params && params.name) } });
    try {
      const r = await t.run((params && params.arguments) || {});
      let text = JSON.stringify(r, null, 1);
      if (text.length > 60000) text = text.slice(0, 60000) + "\n... (truncated)";
      return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text }] } });
    } catch (e) {
      return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "error: " + e.message }], isError: true } });
    }
  }
  if (id !== undefined) send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found: " + method } });
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch (_) { continue; }
    handle(msg).catch((e) => { if (msg.id !== undefined) send({ jsonrpc: "2.0", id: msg.id, error: { code: -32603, message: e.message } }); });
  }
});
