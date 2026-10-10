// SousVide Flow, live: the operator and the agent working on the same map.
//
// Agent -> operator: Claude Code hooks (flow-hook.js) report every Read /
// Edit / Write here; the file and line range are mapped onto the map's
// blocks, and the viewer lights them up as they are read and edited, with a
// per-block diff once an edit lands. A map with a flow/regen.sh is rebuilt
// after edits, and the viewer is told which edges appeared or vanished.
//
// Operator -> agent: notes on blocks, locks, and answers to the agent's plan
// are delivered on the agent's next tool call (PostToolUse additionalContext)
// or next prompt. A locked block is enforced, not requested: an Edit or
// Write that touches one is denied at PreToolUse.
//
// State that must survive a dashboard restart (notes, locks, plan) lives in
// .cache/flow-collab.json; activity and diffs are in memory.

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

module.exports = function flowCollab({ BASE, norm, flykeRoots, flykeLocation, readBody, json, bashPath, cacheDir }) {
  const STATE = path.join(cacheDir, "flow-collab.json");
  let state = { notes: [], locks: {}, plan: null, nextNote: 1 };
  try { state = { ...state, ...JSON.parse(fs.readFileSync(STATE, "utf8")) }; } catch (_) {}
  const save = () => { fs.mkdirSync(cacheDir, { recursive: true }); fs.writeFileSync(STATE, JSON.stringify(state, null, 1)); };

  const clients = new Set();
  // every event, newest last; kept on disk so a session's trail survives a
  // reload or a dashboard restart (the viewer replays it as history)
  const LOG = path.join(cacheDir, "flow-activity.jsonl");
  const MAX_EVENTS = 20000;
  let activity = [];
  try { activity = fs.readFileSync(LOG, "utf8").split("\n").filter(Boolean).slice(-MAX_EVENTS).map((l) => JSON.parse(l)); } catch (_) {}
  const edits = new Map();          // "mod|name|id" -> [{old, new, at, agent}]
  const changes = new Map();        // "mod|name" -> last regen's edge diff
  const key = (mod, name, id) => `${mod}|${name}|${id}`;

  function broadcast(evt) {
    const line = `data: ${JSON.stringify(evt)}\n\n`;
    for (const res of clients) { try { res.write(line); } catch (_) { clients.delete(res); } }
  }

  // An idle agent listens with flow-wait.js (a background command that blocks
  // on /api/flow/wait). The moment the operator sends a note or answers a plan,
  // the oldest listener gets it and exits, which wakes the agent. A busy agent
  // gets the same notes from its hooks instead; whichever comes first takes them.
  const waiters = [];
  const listening = () => {
    broadcast({ type: "listening", n: waiters.length });
    if (typeof setStatus === "function" && state.session && state.session.status !== "working") setStatus(waiters.length ? "listening" : "waiting");
  };
  function flushWaiters() {
    if (!waiters.length) return;
    const ctx = pendingContext();
    if (!ctx) return;
    const res = waiters.shift();
    json(res, 200, { context: ctx });
    listening();
  }

  // ── file -> blocks ────────────────────────────────────────────────────────
  const indexCache = new Map();     // flyke file -> { mtime, byFile: Map(absLower -> [node]) }
  function maps() {
    const out = [];
    for (const r of flykeRoots()) {
      const dir = path.join(r.root, "flow");
      let names = [];
      try { names = fs.readdirSync(dir).filter((f) => f.endsWith(".flyke")); } catch (_) { continue; }
      for (const f of names) out.push({ mod: r.id, name: f.replace(/\.flyke$/, ""), root: norm(r.root), file: path.join(dir, f) });
    }
    return out;
  }
  function indexOf(m) {
    const mtime = fs.statSync(m.file).mtimeMs;
    const hit = indexCache.get(m.file);
    if (hit && hit.mtime === mtime) return hit;
    const doc = JSON.parse(fs.readFileSync(m.file, "utf8"));
    const byFile = new Map();
    for (const n of doc.nodes) {
      if (!n.file || !n.line) continue;
      // relative to the map's folder (polyglot) or the monorepo (trace maps);
      // Repo@branch files read out of git have no working copy to edit
      const cands = /^([A-Za-z]:|\/)/.test(n.file) ? [n.file] : [m.root + "/" + n.file, norm(BASE) + "/" + n.file];
      const abs = cands.find((p) => fs.existsSync(p));
      if (!abs) continue;
      const k = norm(abs).toLowerCase();
      if (!byFile.has(k)) byFile.set(k, []);
      byFile.get(k).push({ id: n.id, line: n.line, endLine: n.endLine || n.line });
    }
    const ix = { mtime, byFile, edges: doc.edges };
    indexCache.set(m.file, ix);
    return ix;
  }
  // blocks a line range touches, in every map; [a, b] null = the whole file
  function blocksAt(file, a, b) {
    const k = norm(file).toLowerCase();
    const out = [];
    for (const m of maps()) {
      let ix;
      try { ix = indexOf(m); } catch (_) { continue; }
      const nodes = ix.byFile.get(k);
      if (!nodes) continue;
      let ids;
      if (a == null) ids = nodes.map((n) => n.id);
      else {
        const over = nodes.filter((n) => n.line <= b && n.endLine >= a);
        // prefer real blocks; top-level code only when nothing narrower matches
        const narrow = over.filter((n) => !/::<module>$/.test(n.id));
        ids = (narrow.length ? narrow : over.length ? over : nodes.filter((n) => /::<module>$/.test(n.id))).map((n) => n.id);
      }
      if (ids.length) out.push({ mod: m.mod, name: m.name, root: m.root, ids });
    }
    return out;
  }
  const lineOf = (text, idx) => text.slice(0, idx).split("\n").length;
  function rangeOf(file, needle) {
    if (!needle) return null;
    try {
      const text = fs.readFileSync(file, "utf8").replace(/\r/g, "");
      const i = text.indexOf(needle.replace(/\r/g, ""));
      if (i < 0) return null;
      return [lineOf(text, i), lineOf(text, i) + needle.split("\n").length - 1];
    } catch (_) { return null; }
  }

  // ── what the agent gets told ──────────────────────────────────────────────
  function pendingContext() {
    const lines = [];
    for (const n of state.notes) {
      if (n.delivered || n.done) continue;
      n.delivered = true;
      lines.push(`- note #${n.id} on ${n.node} (${n.mod}/${n.name}): ${n.text}`);
    }
    if (state.plan && state.plan.status !== "proposed" && !state.plan.delivered) {
      const p = state.plan;
      p.delivered = true;
      lines.push(p.status === "rejected"
        ? `- your plan was REJECTED${p.answer ? ": " + p.answer : ""}. Do not start it; ask the operator.`
        : `- your plan was approved${p.removed.length ? `, except these blocks, now locked: ${p.removed.join(", ")}` : ""}${p.answer ? ". Operator: " + p.answer : ""}.`);
    }
    if (state.taskMsgs && state.taskMsgs.length) { lines.push(...state.taskMsgs); state.taskMsgs = []; }
    if (!lines.length) return null;
    save();
    broadcast({ type: "collab" });
    return "SousVide Flow, from the operator watching the flow chart (answer notes with the flow_notes tool, reply + done; tasks with task_update):\n" + lines.join("\n");
  }
  const lockedIn = (hits) => {
    const out = [];
    for (const h of hits) for (const id of h.ids) { const l = state.locks[key(h.mod, h.name, id)]; if (l) out.push({ id, ...l }); }
    return out;
  };

  // ── regen after edits (maps that know how to rebuild themselves) ─────────
  const regenTimers = new Map();
  function scheduleRegen(hit) {
    const script = path.join(hit.root, "flow", "regen.sh");
    if (!fs.existsSync(script)) return;
    const k = hit.mod + "|" + hit.name;
    clearTimeout(regenTimers.get(k));
    regenTimers.set(k, setTimeout(() => {
      const loc = flykeLocation(hit.mod, hit.name);
      const before = loc ? JSON.parse(fs.readFileSync(loc.file, "utf8")).edges : [];
      broadcast({ type: "regen", mod: hit.mod, name: hit.name, phase: "start" });
      const p = spawn(bashPath(), [script], { cwd: hit.root });
      let err = "";
      p.stderr.on("data", (c) => (err += c));
      p.on("close", (code) => {
        let diff = { added: [], removed: [] };
        try {
          const after = JSON.parse(fs.readFileSync(loc.file, "utf8")).edges;
          const ek = (e) => `${e.from}|${e.to}|${e.kind || "call"}`;
          const A = new Set(before.map(ek)), B = new Set(after.map(ek));
          diff = { added: after.filter((e) => !A.has(ek(e))).map((e) => ({ from: e.from, to: e.to, kind: e.kind || "call" })),
                   removed: before.filter((e) => !B.has(ek(e))).map((e) => ({ from: e.from, to: e.to, kind: e.kind || "call" })) };
        } catch (_) {}
        changes.set(k, { ...diff, at: Date.now() });
        broadcast({ type: "reload", mod: hit.mod, name: hit.name, ok: code === 0, error: code ? err.slice(-400) : "", ...diff });
      });
    }, 2500));
  }

  function note(evt) {
    // a subagent's events belong to its lane
    if (evt.sub && evt.lane == null && state.lanes) { const lane = state.lanes.find((l) => l.agentId === evt.sub); if (lane) { evt.lane = lane.id; lane.events++; } }
    activity.push(evt);
    try { fs.mkdirSync(cacheDir, { recursive: true }); fs.appendFileSync(LOG, JSON.stringify(evt) + "\n"); } catch (_) {}
    if (activity.length > MAX_EVENTS * 1.25) {   // compact the log now and then
      activity = activity.slice(-MAX_EVENTS);
      try { fs.writeFileSync(LOG, activity.map((e) => JSON.stringify(e)).join("\n") + "\n"); } catch (_) {}
    }
    broadcast(evt);
    if (typeof stepEvent === "function" && evt.type === "activity") stepEvent(evt);
  }


  // ── the session: everything the agent does, on the map or not ────────────
  // Most of a turn happens off the map: commands, reads of other repos and
  // decompiled source, engine probes, memory, subagents, long runs. Every tool
  // call becomes a session event in plain words (a command by the agent's own
  // description of it), subagents and background commands are LANES with a
  // live status, and the session knows whose turn it is (working / waiting on
  // the operator / listening for notes).
  state.session = state.session || { status: "idle", since: Date.now() };
  state.lanes = state.lanes || []; state.nextLane = state.nextLane || 1;
  let curAgent = null;
  const RAW = path.join(cacheDir, "flow-hook-raw.jsonl");
  let rawCount = 0;
  function rawDump(p) {   // the last hook payloads, values trimmed: for learning the hook fields
    try {
      const t = {};
      const cut = (v) => typeof v === "string" ? v.slice(0, 200) : v;
      for (const [k, v] of Object.entries(p)) t[k] = v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).map(([a, b]) => [a, typeof b === "object" ? JSON.stringify(b).slice(0, 200) : cut(b)])) : cut(v);
      fs.appendFileSync(RAW, JSON.stringify(t) + "\n");
      if (++rawCount % 100 === 0) { const ls = fs.readFileSync(RAW, "utf8").split("\n").filter(Boolean); if (ls.length > 300) fs.writeFileSync(RAW, ls.slice(-200).join("\n") + "\n"); }
    } catch (_) {}
  }
  let sessionTimer = null;
  const sessionChanged = () => { save(); clearTimeout(sessionTimer); sessionTimer = setTimeout(() => broadcast({ type: "session" }), 80); };
  function setStatus(st) {
    if (state.session.status === st) return;
    state.session = { ...state.session, status: st, since: Date.now() };
    sessionChanged();
  }
  const relPath = (f) => {
    const n = norm(String(f || "")), b = norm(BASE);
    return n.toLowerCase().startsWith(b.toLowerCase() + "/") ? n.slice(b.length + 1) : n;
  };
  const firstLine = (t) => String(t || "").split("\n").map((x) => x.trim()).find((x) => x && !/^--/.test(x)) || "";
  const respText = (r) => r == null ? "" : typeof r === "string" ? r : Array.isArray(r) ? r.map((x) => x && x.text || "").join("\n")
    : String(r.stdout || r.output || r.result || r.text || (r.content ? respText(r.content) : JSON.stringify(r)));
  // a tool call in words; null = not worth a line (the board's own tools, schema lookups)
  function describe(tool, ti, p) {
    const m = /^mcp__([^_]+(?:_[^_]+)*?)__(.+)$/.exec(tool);
    if (m) {
      const [, server, name] = m;
      if (server === "sousvide" && /^(flow_|task_)/.test(name)) return null;
      if (server === "sousvide" && /eval$/.test(name)) return { label: `Probed the ${ti.mod || "live"} engine: ${firstLine(ti.lua).slice(0, 90)}`, detail: String(ti.lua || "").slice(0, 1500), kind: "probe" };
      if (server === "sousvide" && name === "test") return { label: `Ran the ${ti.mod} tests${ti.only ? " (" + ti.only + ")" : ""}`, kind: "test" };
      if (server === "mdb-mem") {
        if (name === "search_memories") return { label: `Searched memory: "${String(ti.query || "").slice(0, 80)}"`, kind: "memory" };
        if (name === "add_memory") return { label: `Saved to memory: ${firstLine(ti.content).slice(0, 100)}`, detail: String(ti.content || "").slice(0, 1500), kind: "memory" };
        return { label: `Memory: ${name.replace(/_/g, " ")}`, kind: "memory" };
      }
      return { label: `${server}: ${name.replace(/_/g, " ")}`, kind: "tool" };
    }
    switch (tool) {
      case "Read": return { label: `Read ${relPath(ti.file_path)}${ti.offset ? ` from line ${ti.offset}` : ""}`, file: ti.file_path, kind: "reading" };
      case "Edit": case "MultiEdit": return { label: `Edited ${relPath(ti.file_path)}`, file: ti.file_path, kind: "edited" };
      case "Write": return { label: `Wrote ${relPath(ti.file_path)}`, file: ti.file_path, kind: "edited" };
      case "NotebookEdit": return { label: `Edited ${relPath(ti.notebook_path)}`, file: ti.notebook_path, kind: "edited" };
      case "Grep": return { label: `Searched for "${String(ti.pattern || "").slice(0, 60)}"${ti.path ? " in " + relPath(ti.path) : ""}${ti.glob ? " (" + ti.glob + ")" : ""}`, kind: "search" };
      case "Glob": return { label: `Looked for ${ti.pattern}${ti.path ? " in " + relPath(ti.path) : ""}`, kind: "search" };
      case "WebFetch": return { label: `Fetched ${ti.url}`, kind: "web" };
      case "WebSearch": return { label: `Searched the web: ${ti.query}`, kind: "web" };
      case "Skill": return { label: `Used the ${ti.skill} skill`, kind: "tool" };
      case "AskUserQuestion": {
        const q = (ti.questions || [])[0] || {};
        return { label: `Asked you: ${String(q.question || "").slice(0, 140)}`, detail: respText(p.tool_response).slice(0, 600), kind: "question" };
      }
      case "ToolSearch": case "TaskStop": case "ScheduleWakeup": case "ListAgents": case "SendMessage": return null;
      default: return { label: tool, kind: "tool" };
    }
  }
  // lanes: subagents and background commands
  function laneStart(l) {
    const lane = { id: state.nextLane++, status: "running", started: Date.now(), ended: null, step: state.openStep, task: state.activeTask, events: 0, agent: curAgent, ...l };
    state.lanes.push(lane);
    if (state.lanes.length > 200) state.lanes.splice(0, state.lanes.length - 200);
    sessionChanged();
    return lane;
  }
  function laneEnd(lane, result, status) {
    if (!lane || lane.status !== "running") return;
    lane.status = status || "done"; lane.ended = Date.now(); if (result) lane.result = String(result).slice(0, 1200);
    sessionChanged();
  }
  // Stop and SubagentStop carry the session's background tasks (id, type,
  // status, description): the truth for lanes. Running ones open or keep a
  // lane; a lane whose task is gone or finished ends.
  function reconcileLanes(list) {
    const byId = new Map(list.map((t) => [String(t.id), t]));
    for (const t of list) {
      if (t.status !== "running") continue;
      const known = state.lanes.find((l) => l.agentId === t.id || l.bgId === t.id);
      if (known) { if (known.status !== "running") { known.status = "running"; known.ended = null; sessionChanged(); } continue; }
      const agent = t.type === "subagent";
      laneStart({ kind: agent ? "agent" : "command", label: String(t.description || t.id).slice(0, 120), detail: String(t.command || "").slice(0, 1500),
        ...(agent ? { agentId: t.id, agentType: t.agent_type || "" } : { bgId: t.id }) });
    }
    for (const l of state.lanes) {
      if (l.status !== "running") continue;
      const id = l.agentId || l.bgId;
      if (!id) continue;
      const t = byId.get(id);
      if (!t) laneEnd(l, "", "done");
      else if (t.status !== "running") laneEnd(l, "", t.status === "completed" ? "done" : t.status === "failed" ? "failed" : t.status === "killed" ? "stopped" : t.status);
    }
  }
  // a background command has no end event of its own: watch its output file too
  setInterval(() => {
    let changed = false;
    for (const l of state.lanes) {
      if (l.kind !== "command" || l.status !== "running" || !l.outFile) continue;
      try {
        const st = fs.statSync(l.outFile);
        if (st.mtimeMs !== l.lastOutput) { l.lastOutput = st.mtimeMs; changed = true; }
        if (Date.now() - st.mtimeMs > 6 * 3600e3) { l.status = "quiet"; changed = true; }
      } catch (_) {}
    }
    if (changed) sessionChanged();
  }, 10000).unref();

  // A step is always open. With none, the board opens one from the action
  // and asks the agent (once) to name it; the agent's next flow_step open
  // takes the inferred step over rather than closing it.
  function ensureStep(label) {
    const s = state.openStep != null && stepById(state.openStep);
    if (s && s.status === "open") return null;
    const t = stepOp({ op: "open", title: label.slice(0, 120), why: "", inferred: true });
    if (t.error) return null;
    return `SousVide Flow: no journal step was open, so the board opened one from your last action ("${label.slice(0, 80)}"). Say what you are doing and why: flow_step op open (it takes this step over). The operator follows the session through the journal.`;
  }
  // what an edit changed, for the session's diff fold (bounded)
  function editDiff(tool, ti) {
    const cut = (v, n) => String(v == null ? "" : v).slice(0, n);
    if (tool === "Edit") return [{ old: cut(ti.old_string, 3000), new: cut(ti.new_string, 3000) }];
    if (tool === "MultiEdit") return (ti.edits || []).slice(0, 6).map((e) => ({ old: cut(e.old_string, 1500), new: cut(e.new_string, 1500) }));
    if (tool === "Write") return [{ old: "", new: cut(ti.content, 4000), whole: true }];
    if (tool === "NotebookEdit") return [{ old: "", new: cut(ti.new_source, 3000) }];
    return null;
  }
  // the session event for one tool call (PostToolUse), with lanes and the step
  function sessionEvent(p, agent) {
    const r = sessionEvent1(p, agent);
    if (r && r.ev) { if (p.duration_ms != null) r.ev.ms = p.duration_ms; if (p.prompt_id) r.ev.prompt = String(p.prompt_id).slice(0, 8); }
    return r;
  }
  function sessionEvent1(p, agent) {
    const tool = p.tool_name || "", ti = p.tool_input || {};
    const sub = p.agent_id || null;
    if (tool === "Agent" || tool === "Task") {
      const r = p.tool_response && typeof p.tool_response === "object" && !Array.isArray(p.tool_response) ? p.tool_response : {};
      const text = respText(p.tool_response);
      const bg = !!ti.run_in_background || !!r.isAsync || r.status === "async_launched" || /working in the background|launched successfully/i.test(text);
      const id = r.agentId || (/agentId:\s*(\w+)/.exec(text) || [])[1] || null;
      const pre = state.lanes.filter((l) => l.toolUse && l.toolUse === p.tool_use_id).pop();
      const lane = pre || laneStart({ kind: "agent", label: String(ti.description || "subagent").slice(0, 120), detail: String(ti.prompt || "").slice(0, 1500), toolUse: p.tool_use_id, agentType: ti.subagent_type || "" });
      if (id) lane.agentId = id;
      if (!bg) laneEnd(lane, text);
      sessionChanged();
      return { ev: { type: "activity", kind: "lane", agent, at: Date.now(), lane: lane.id, text: `${bg ? "Started" : "Ran"} a subagent: ${lane.label}`, task: state.activeTask }, label: `Subagent: ${lane.label}` };
    }
    if (tool === "Bash" || tool === "PowerShell") {
      const ce = commandEvent(p, agent);
      if (!ce) return null;
      if (ti.run_in_background) {
        const text = respText(p.tool_response);
        const outFile = (/(?:written to|output file):\s*(\S+?\.output)/i.exec(text) || [])[1] || null;
        const bgId = (/with ID:\s*(\w+)/.exec(text) || [])[1] || null;
        const lane = laneStart({ kind: "command", label: ce.desc || ce.text.slice(0, 120), detail: ce.text, bgId, outFile });
        ce.lane = lane.id;
      }
      if (sub) ce.sub = sub;
      return { ev: ce, label: ce.desc || ce.text.slice(0, 80) };
    }
    const d = describe(tool, ti, p);
    if (!d) return null;
    const ev = { type: "activity", kind: d.kind, agent, at: Date.now(), tool, text: d.label, task: state.activeTask };
    if (d.detail) ev.detail = d.detail;
    if (d.file) ev.file = d.file;
    if (d.kind === "edited") { const df = editDiff(tool, ti); if (df) ev.diff = df; }
    if (sub) ev.sub = sub;
    if (tool === "TaskStop") for (const l of state.lanes) if (l.bgId && l.bgId === ti.task_id) laneEnd(l, "stopped", "stopped");
    return { ev, label: d.label };
  }

  // ── the hook endpoint ─────────────────────────────────────────────────────
  function onHook(p) {
    const ev = p.hook_event_name, tool = p.tool_name || "", ti = p.tool_input || {};
    const agent = String(p.session_id || "agent").slice(0, 6);
    curAgent = agent;
    rawDump(p);
    const sub = p.agent_id || null;
    const withCtx = (name, extra) => {
      const ctx = [pendingContext(), extra].filter(Boolean).join("\n\n");
      return ctx ? { hookSpecificOutput: { hookEventName: name, additionalContext: ctx } } : null;
    };
    if (ev === "UserPromptSubmit") {
      setStatus("working");
      const sys = /^\s*<(task-notification|agent-message|cross-session-message|system-reminder)\b/.test(String(p.prompt || ""));
      if (sys) {
        const t = String(p.prompt);
        const summary = (/<summary>([\s\S]*?)<\/summary>/.exec(t) || [])[1] || (/<agent-message from="([^"]*)"/.test(t) ? "A subagent reported back" : /<cross-session-message/.test(t) ? "A message from another session" : "a background task finished");
        const id = (/<task-id>(\w+)<\/task-id>/.exec(t) || [])[1];
        for (const l of state.lanes) if (id && (l.bgId === id || l.agentId === id)) laneEnd(l, summary);
        note({ type: "activity", kind: "notify", agent, at: Date.now(), text: summary.trim().slice(0, 300), task: state.activeTask });
      } else if (p.prompt) note({ type: "activity", kind: "prompt", agent, at: Date.now(), text: String(p.prompt).slice(0, 4000), task: state.activeTask, prompt: String(p.prompt_id || "").slice(0, 8) });
      return withCtx("UserPromptSubmit");
    }
    if (ev === "Stop") {   // the agent's turn ended: the operator's move
      if (!sub) { setStatus(waiters.length ? "listening" : "waiting"); note({ type: "activity", kind: "stop", agent, at: Date.now(), task: state.activeTask }); }
      return null;
    }
    if (Array.isArray(p.background_tasks)) reconcileLanes(p.background_tasks);
    if (ev === "SubagentStop") {
      // only an exact match: helper agents stop all the time with ids of their own
      const lane = sub && state.lanes.find((l) => l.agentId === sub && l.status === "running");
      if (lane) laneEnd(lane, p.last_assistant_message || "");
      return null;
    }
    if (ev === "PreToolUse" && (tool === "Agent" || tool === "Task")) {
      laneStart({ kind: "agent", label: String(ti.description || "subagent").slice(0, 120), detail: String(ti.prompt || "").slice(0, 1500), toolUse: p.tool_use_id, agentType: ti.subagent_type || "" });
      return null;
    }
    if (ev === "PostToolUse" && !sub && state.session.status !== "working") setStatus("working");
    // everything but on-map reads and edits (below) is one session event
    const onMap = /^(Read|Edit|MultiEdit|Write|NotebookEdit)$/.test(tool);
    if (ev === "PostToolUse" && !onMap) {
      const se = sessionEvent(p, agent);
      let nudge = null;
      if (se) {
        if (!sub) nudge = ensureStep(se.label);
        note(se.ev);
      }
      return withCtx("PostToolUse", nudge);
    }
    if (!onMap) return null;
    const file = ti.file_path || ti.notebook_path;
    const isEdit = /^(Edit|MultiEdit|Write|NotebookEdit)$/.test(tool);
    let hits = [];
    if (file) {
      const list = tool === "MultiEdit" ? (ti.edits || []) : [{ old_string: ti.old_string, new_string: ti.new_string }];
      if (tool === "Read") {
        const a = ti.offset ? Number(ti.offset) : null;
        hits = blocksAt(file, a, a == null ? null : a + Number(ti.limit || 2000) - 1);
      } else if (tool === "Write" || tool === "NotebookEdit") {
        hits = blocksAt(file, null, null);
      } else if (isEdit) {
        const merged = new Map();
        for (const e of list) {
          // before the edit the old text is in the file; after it, the new text
          const r = ev === "PreToolUse" ? rangeOf(file, e.old_string) : rangeOf(file, e.new_string);
          if (!r) continue;
          const span = Math.max((e.old_string || "").split("\n").length, (e.new_string || "").split("\n").length) - 1;
          // the enclosing function by name, read from the file as it is now
          const fnName = scanBlock(file, r[0]);
          const byName = fnName ? blocksByName(file, fnName) : [];
          for (const h of (byName.length ? byName : blocksAt(file, r[0], r[0] + span))) {
            const m = merged.get(h.mod + "|" + h.name) || { ...h, ids: [] };
            for (const id of h.ids) if (!m.ids.includes(id)) m.ids.push(id);
            merged.set(h.mod + "|" + h.name, m);
          }
        }
        hits = [...merged.values()];
      }
    }

    if (ev === "PreToolUse") {
      if (isEdit) {
        const locked = lockedIn(hits);
        if (locked.length) {
          note({ type: "activity", kind: "denied", agent, tool, file, at: Date.now(), hits: hits.map(({ root, ...h }) => h) });
          const why = locked.map((l) => `${l.id}${l.note ? " (" + l.note + ")" : ""}`).join("; ");
          return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny",
            permissionDecisionReason: `The operator has locked these blocks in the SousVide Flow chart: ${why}. Leave them as they are, or ask the operator to unlock them.` } };
        }
      }
      if (hits.length) { note({ type: "activity", kind: isEdit ? "editing" : "reading", agent, tool, file, at: Date.now(), hits: hits.map(({ root, ...h }) => h), task: state.activeTask, text: (describe(tool, ti, p) || {}).label, ...(sub ? { sub } : {}) }); if (!isEdit) taskTouch(hits, "reading"); }
      return null;
    }
    if (ev === "PostToolUse") {
      if (isEdit && hits.length) {
        const list = tool === "MultiEdit" ? (ti.edits || []) : tool === "Edit" ? [{ old_string: ti.old_string, new_string: ti.new_string }] : [{ old_string: "", new_string: "(whole file written)" }];
        const cut = (s) => String(s || "").slice(0, 4000);
        for (const h of hits) {
          for (const id of h.ids) {
            const k = key(h.mod, h.name, id);
            const arr = edits.get(k) || [];
            for (const e of list) arr.push({ old: cut(e.old_string), new: cut(e.new_string), at: Date.now(), agent });
            edits.set(k, arr.slice(-5));
          }
          scheduleRegen(h);
        }
        note({ type: "activity", kind: "edited", agent, tool, file, at: Date.now(), hits: hits.map(({ root, ...h }) => h), task: state.activeTask, text: describe(tool, ti, p).label, diff: editDiff(tool, ti), ...(sub ? { sub } : {}) });
        taskTouch(hits, "edited");
      }
      let nudge = null;
      if (!sub) nudge = ensureStep((describe(tool, ti, p) || { label: tool }).label);
      if (!hits.length) { const se = sessionEvent(p, agent); if (se) note(se.ev); }
      return withCtx("PostToolUse", nudge);
    }
    return null;
  }

  // ── tasks: a graph of work tied to the code ──────────────────────────────
  // A task has a state, typed links to other tasks, and ANCHORS in a map:
  // planned blocks (what it means to touch) and touched blocks (filled in by
  // the hooks while it is the active task). touched - planned = scope drift.
  // Operator changes reach the agent the way notes do. A task that reaches
  // done is appended to <map root>/flow/TASKS.md.
  const TASK_STATES = ["proposed", "planned", "active", "review", "blocked", "done", "dropped"];
  const LINK_TYPES = ["blocks", "found_while", "replaces", "relates"];
  state.tasks = state.tasks || []; state.nextTask = state.nextTask || 1;
  state.activeTask = state.activeTask ?? null; state.taskMsgs = state.taskMsgs || [];
  const taskById = (id) => state.tasks.find((t) => t.id === Number(id));
  let taskTimer = null;
  const tasksChanged = () => { if (typeof sweepSketches === "function") sweepSketches(); save(); clearTimeout(taskTimer); taskTimer = setTimeout(() => broadcast({ type: "tasks" }), 120); };
  function taskTouch(hits, kind) {
    const t = state.activeTask != null && taskById(state.activeTask);
    if (!t) return;
    let any = false;
    for (const h of hits) {
      if (t.mod && (h.mod !== t.mod || h.name !== t.name)) continue;
      if (!t.mod) { t.mod = h.mod; t.name = h.name; }
      for (const id of h.ids) {
        const c = t.touched[id] || (t.touched[id] = { r: 0, e: 0 });
        if (kind === "edited") c.e++; else if (kind === "reading") c.r++;
        any = true;
      }
    }
    if (any) { t.updated = Date.now(); tasksChanged(); }
  }
  function logDone(t) {
    const loc = t.mod && flykeLocation(t.mod, t.name);
    if (!loc) return;
    const file = path.join(loc.root, "flow", "TASKS.md");
    const touched = Object.keys(t.touched), edited = touched.filter((id) => t.touched[id].e);
    const drift = t.planned.length ? edited.filter((id) => !t.planned.includes(id)) : [];
    const checks = t.checks.length ? ` · checks ${t.checks.filter((c) => c.done).length}/${t.checks.length}` : "";
    const lines = [
      `## #${t.id} ${t.title}`,
      `${new Date(t.doneAt).toISOString().slice(0, 10)} · ${t.owner}${checks} · edited ${edited.length} blocks, read ${touched.length - edited.length}${drift.length ? ` · ${drift.length} outside the plan` : ""}`,
      t.why ? `\n${t.why}` : "",
      edited.length ? `\nEdited: ${edited.map((id) => "`" + id + "`").join(", ")}` : "",
      t.links.length ? `\nLinks: ${t.links.map((l) => `${l.type} #${l.to}`).join(", ")}` : "",
      t.evidence.length ? "\n" + t.evidence.map((e) => `- ${e.kind}: ${e.text}`).join("\n") : "",
      "",
    ].filter((x) => x !== "").join("\n");
    try {
      const head = fs.existsSync(file) ? "" : "# Tasks\n\nFinished SousVide Flow tasks, newest last (written by the dashboard).\n\n";
      fs.appendFileSync(file, head + lines + "\n\n");
    } catch (_) {}
  }
  function taskOp(b) {
    const by = b.by === "operator" ? "operator" : "agent";
    const tell = (msg) => { if (by === "operator") state.taskMsgs.push(msg); };
    const now = Date.now();
    if (b.op === "new") {
      if (!String(b.title || "").trim()) return { error: "title" };
      const t = { id: state.nextTask++, title: String(b.title).trim().slice(0, 200), why: String(b.why || "").slice(0, 1000),
        state: TASK_STATES.includes(b.state) ? b.state : "proposed", owner: b.owner || by, parent: b.parent ? Number(b.parent) : null,
        links: [], mod: b.mod || null, name: b.name || null, planned: Array.isArray(b.planned) ? b.planned : [],
        touched: {}, checks: (b.checks || []).map((c) => ({ text: String(c).slice(0, 300), done: false })), evidence: [], created: now, updated: now };
      if (b.found_while) t.links.push({ type: "found_while", to: Number(b.found_while) });
      state.tasks.push(t);
      tell(`- the operator created task #${t.id}: ${t.title}${t.why ? " (" + t.why + ")" : ""}`);
      if (b.activate) state.activeTask = t.id, t.state = "active";
      tasksChanged(); return t;
    }
    const t = taskById(b.id);
    if (!t) return { error: "no such task" };
    if (b.op === "update") {
      if (b.title) t.title = String(b.title).slice(0, 200);
      if (b.why != null) t.why = String(b.why).slice(0, 1000);
      if (b.owner) t.owner = b.owner;
      if (b.parent !== undefined) t.parent = b.parent ? Number(b.parent) : null;
      if (Array.isArray(b.planned)) t.planned = b.planned;
      if (Array.isArray(b.addPlanned)) for (const id of b.addPlanned) if (!t.planned.includes(id)) t.planned.push(id);
      if (b.mod) { t.mod = b.mod; t.name = b.name; }
      for (const c of b.addChecks || []) t.checks.push({ text: String(c).slice(0, 300), done: false });
      if (b.check != null && t.checks[b.check]) { t.checks[b.check].done = b.done !== false; tell(`- the operator ${t.checks[b.check].done ? "ticked" : "unticked"} a check on task #${t.id}: ${t.checks[b.check].text}`); }
      if (b.evidence) t.evidence.push({ kind: String(b.evidence.kind || "note").slice(0, 30), text: String(b.evidence.text || "").slice(0, 600), at: now });
      if (b.state && TASK_STATES.includes(b.state) && b.state !== t.state) {
        const was = t.state; t.state = b.state;
        if (b.state === "active") state.activeTask = t.id;
        else if (state.activeTask === t.id) state.activeTask = null;
        if (b.state === "done") { t.doneAt = now; logDone(t); }
        tell(`- the operator moved task #${t.id} "${t.title}" from ${was} to ${b.state}${b.reason ? ": " + b.reason : ""}`);
      }
      if (b.activate) { state.activeTask = t.id; if (["proposed", "planned", "blocked", "review"].includes(t.state)) t.state = "active"; tell(`- the operator made task #${t.id} "${t.title}" the active task`); }
      t.updated = now; tasksChanged(); return t;
    }
    if (b.op === "link" || b.op === "unlink") {
      if (!LINK_TYPES.includes(b.type) || !taskById(b.to) || Number(b.to) === t.id) return { error: "type must be " + LINK_TYPES.join("|") + " and to an existing other task" };
      t.links = t.links.filter((l) => !(l.type === b.type && l.to === Number(b.to)));
      if (b.op === "link") t.links.push({ type: b.type, to: Number(b.to) });
      t.updated = now; tasksChanged(); return t;
    }
    if (b.op === "delete") { state.tasks = state.tasks.filter((x) => x.id !== t.id); if (state.activeTask === t.id) state.activeTask = null; tasksChanged(); return { deleted: t.id }; }
    return { error: "op: new | update | link | unlink | delete" };
  }

  // ── sketches: nodes the agent puts on a map that the code does not have ──
  // A planned function, a test still to write, a CI job, an outside service.
  // Each sits beside a real block (near), may carry edges to real blocks or
  // other sketches, and may belong to a task. `expect` names the code it
  // stands for: once the map has that block the sketch counts as real. A
  // temporary sketch goes away when its task is done or dropped.
  state.sketches = state.sketches || [];
  const SKETCH_KINDS = ["fn", "test", "check", "job", "service", "data", "note"];
  function sketchOp(b) {
    const now = Date.now();
    if (!b.mod || !b.name) return { error: "mod and name" };
    if (b.op === "clear") { state.sketches = state.sketches.filter((x) => !(x.mod === b.mod && x.name === b.name && (!b.task || x.task === Number(b.task)))); tasksChanged(); return { ok: true }; }
    if (b.op === "remove") { const keys = new Set(b.keys || []); state.sketches = state.sketches.filter((x) => !(x.mod === b.mod && x.name === b.name && keys.has(x.key))); tasksChanged(); return { ok: true }; }
    const put = [];
    for (const n of b.nodes || []) {
      const key = String(n.key || "").replace(/[^\w.-]/g, "_").slice(0, 60);
      if (!key || !String(n.label || "").trim()) continue;
      const old = state.sketches.find((x) => x.mod === b.mod && x.name === b.name && x.key === key);
      const s = Object.assign(old || { key, mod: b.mod, name: b.name, created: now, edges: [] }, {
        label: String(n.label).slice(0, 120), kind: SKETCH_KINDS.includes(n.kind) ? n.kind : "note",
        note: String(n.note || "").slice(0, 600), near: n.near || null, task: n.task ? Number(n.task) : null,
        expect: n.expect || null, temp: !!n.temp, updated: now });
      if (!old) state.sketches.push(s);
      put.push(s);
    }
    for (const e of b.edges || []) {
      const from = state.sketches.find((x) => x.mod === b.mod && x.name === b.name && ("sketch:" + x.key === e.from || x.key === e.from));
      const host = from || state.sketches.find((x) => x.mod === b.mod && x.name === b.name && ("sketch:" + x.key === e.to || x.key === e.to));
      if (!host) continue;
      const norm = (v) => state.sketches.some((x) => x.mod === b.mod && x.name === b.name && x.key === v) ? "sketch:" + v : v;
      const edge = { from: norm(e.from), to: norm(e.to), kind: e.kind || "plan", label: String(e.label || "").slice(0, 120) };
      host.edges = host.edges.filter((x) => !(x.from === edge.from && x.to === edge.to && x.kind === edge.kind)).concat([edge]);
    }
    tasksChanged();
    return { put: put.map((s) => "sketch:" + s.key) };
  }
  // temporary sketches leave with their task
  const sweepSketches = () => {
    const closed = new Set(state.tasks.filter((t) => t.state === "done" || t.state === "dropped").map((t) => t.id));
    state.sketches = state.sketches.filter((x) => !(x.temp && x.task && closed.has(x.task)));
  };

  // ── the work journal: steps the agent writes, with what happened under them ──
  // The feed is raw events ("read exec", "edited Composer.lua"): no intent, no
  // outcome. A STEP is the agent's own account: a title, why it is doing it,
  // and when it closes, the result. While a step is open every hook event
  // (reads, edits, commands, test runs) is filed under it, so the raw events
  // become the evidence of a step instead of the story.
  state.steps = state.steps || []; state.nextStep = state.nextStep || 1; state.openStep = state.openStep ?? null;
  const STEP_STATUS = ["open", "done", "failed", "changed"];
  const stepById = (id) => state.steps.find((x) => x.id === Number(id));
  let stepTimer = null;
  const stepsChanged = () => { save(); clearTimeout(stepTimer); stepTimer = setTimeout(() => broadcast({ type: "steps" }), 120); };
  function stepEvent(e) {
    if (e.sub || e.kind === "prompt" || e.kind === "stop") return;
    const s = state.openStep != null && stepById(state.openStep);
    if (!s) return;
    s.events.push(e);
    if (s.events.length > 300) s.events.splice(0, s.events.length - 300);
    for (const h of e.hits || []) for (const id of h.ids || []) {
      const c = s.blocks[id] || (s.blocks[id] = { r: 0, e: 0 });
      if (e.kind === "edited") c.e++; else if (e.kind === "reading") c.r++;
      if (!s.mod) { s.mod = h.mod; s.name = h.name; }
    }
    stepsChanged();
  }
  function stepOp(b) {
    const now = Date.now();
    if (b.op === "open") {
      if (!String(b.title || "").trim()) return { error: "title" };
      const prev = state.openStep != null && stepById(state.openStep);
      // the agent names a step the board inferred: take it over, events and all
      if (prev && prev.status === "open" && prev.inferred && !b.inferred && !b.closed) {
        prev.title = String(b.title).trim().slice(0, 160); prev.why = String(b.why || "").slice(0, 600); prev.inferred = false;
        if (b.task != null) prev.task = Number(b.task);
        for (const id of b.blocks || []) prev.blocks[id] = prev.blocks[id] || { r: 0, e: 0 };
        stepsChanged();
        return prev;
      }
      if (prev && prev.status === "open") { prev.status = "done"; prev.closed = now; }
      const task = b.task != null ? Number(b.task) : state.activeTask;
      const t = task != null ? taskById(task) : null;
      const s = { id: state.nextStep++, task: t ? t.id : null, title: String(b.title).trim().slice(0, 160), why: String(b.why || "").slice(0, 600),
                  result: "", status: "open", opened: b.at || now, closed: null, mod: b.mod || (t && t.mod) || null, name: b.name || (t && t.name) || null,
                  events: [], blocks: {}, notes: [], inferred: !!b.inferred };
      for (const id of b.blocks || []) s.blocks[id] = { r: 0, e: 0 };
      state.steps.push(s);
      state.openStep = b.closed ? null : s.id;
      if (b.closed) { s.status = STEP_STATUS.includes(b.status) ? b.status : "done"; s.result = String(b.result || "").slice(0, 800); s.closed = b.closedAt || now; }
      stepsChanged();
      return s;
    }
    const s = b.id != null ? stepById(b.id) : (state.openStep != null && stepById(state.openStep));
    if (!s) return { error: "no step (open one first)" };
    if (b.op === "close") {
      s.status = STEP_STATUS.includes(b.status) && b.status !== "open" ? b.status : "done";
      s.result = String(b.result || s.result || "").slice(0, 800);
      s.closed = now;
      if (state.openStep === s.id) state.openStep = null;
      stepsChanged();
      return s;
    }
    if (b.op === "note") { s.notes.push({ text: String(b.text || "").slice(0, 600), at: now }); stepsChanged(); return s; }
    return { error: "op: open | close | note" };
  }
  // a command's result line, when it is one we can read (test runners)
  function commandEvent(p, agent) {
    const ti = p.tool_input || {}, cmd = String(ti.command || "").trim();
    if (!cmd) return null;
    const out = (() => { const r = p.tool_response; if (!r) return ""; if (typeof r === "string") return r; return String(r.stdout || r.output || "") + "\n" + String(r.stderr || ""); })();
    const pick = (re) => { const m = out.match(re); return m ? m[0].trim() : ""; };
    const result = pick(/KAHLUA TOTAL:[^\n]*/) || pick(/MP CHECKS:[^\n]*/) || pick(/\d+ passed[^\n]*/) || pick(/Results: \d+ passed, \d+ failed/);
    const test = /pztest|mp-check|pytest|npm (run )?test|validator/.test(cmd);
    const failed = /([1-9]\d*) failed|[1-9]\d* errors|FAIL\b/.test(result);
    const desc = String(ti.description || "").trim().slice(0, 200);
    return { type: "activity", kind: test ? "test" : "command", agent, at: Date.now(), text: cmd.replace(/\s+/g, " ").slice(0, 240), desc, ...(cmd.length > 240 || cmd.includes(String.fromCharCode(10)) ? { full: cmd.slice(0, 3000) } : {}), result, ok: test ? !failed : undefined, task: state.activeTask };
  }

  // The block an edit lands in, read from the file AS IT IS NOW: walk up from
  // the edited line to the nearest function definition and match its name
  // against the map's blocks for that file. The map's own line numbers go
  // stale as soon as an earlier edit in the file shifts them (until the map
  // rebuilds), which filed edits under blocks they never touched.
  const DEF = [
    /^\s*(?:local\s+)?function\s+([\w.:]+)\s*\(/,            // lua: function a.b(  / local function x(
    /^\s*(?:local\s+)?([\w.:]+)\s*=\s*function\s*\(/,        // lua: x = function(
    /^\s*(?:export\s+)?(?:async\s+)?function\s*\*?\s*(\w+)\s*\(/, // js: function x(
    /^\s*(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?(?:function|\([^)]*\)\s*=>|\w+\s*=>)/, // js: const x = () =>
    /^\s*(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{\s*$/,            // js method: x(a) {
    /^\s*(?:async\s+)?def\s+(\w+)\s*\(/,                     // python
  ];
  function scanBlock(file, line) {
    let lines;
    try { lines = fs.readFileSync(file, "utf8").replace(/\r/g, "").split("\n"); } catch (_) { return null; }
    for (let i = Math.min(line, lines.length) - 1; i >= 0; i--) {
      for (const re of DEF) { const m = re.exec(lines[i]); if (m && !/^(if|for|while|switch|catch|return)$/.test(m[1])) return m[1]; }
    }
    return null;
  }
  function blocksByName(file, name) {
    const k = norm(file).toLowerCase(), out = [];
    for (const m of maps()) {
      let ix; try { ix = indexOf(m); } catch (_) { continue; }
      const nodes = ix.byFile.get(k); if (!nodes) continue;
      const ids = nodes.filter((n) => n.id.split("::").slice(1).join("::").replace(/@\d+$/, "") === name).map((n) => n.id);
      if (ids.length) out.push({ mod: m.mod, name: m.name, root: m.root, ids: ids.slice(0, 1) });
    }
    return out;
  }


  // ── cards: what the session concluded, decided or needs to ask ───────────
  // The work's real output is often not code: a finding, a correction to an
  // earlier finding, a decision between alternatives, an assumption not yet
  // checked, a question only the operator can answer. Each is a card on the
  // step that made it, with evidence and the blocks it is about. A question
  // waits on the operator; the answer reaches the agent the way notes do.
  state.cards = state.cards || []; state.nextCard = state.nextCard || 1;
  const CARD_KINDS = ["finding", "correction", "decision", "assumption", "question"];
  const CARD_STATUS = ["open", "answered", "verified", "wrong", "resolved"];
  function cardOp(b) {
    const now = Date.now(), by = b.by === "operator" ? "operator" : "agent";
    if (b.op === "new") {
      if (!String(b.title || "").trim()) return { error: "title" };
      const c = { id: state.nextCard++, kind: CARD_KINDS.includes(b.kind) ? b.kind : "finding", title: String(b.title).trim().slice(0, 200),
        text: String(b.text || "").slice(0, 2000), step: state.openStep, task: b.task != null ? Number(b.task) : state.activeTask,
        refs: Array.isArray(b.refs) ? b.refs.slice(0, 20) : [], evidence: (b.evidence || []).slice(0, 10).map((e) => ({ kind: String(e.kind || "note").slice(0, 20), text: String(e.text || "").slice(0, 400) })),
        options: Array.isArray(b.options) ? b.options.map((o) => String(o).slice(0, 200)).slice(0, 6) : [], alternatives: Array.isArray(b.alternatives) ? b.alternatives.map((o) => String(o).slice(0, 300)).slice(0, 6) : [],
        corrects: b.corrects != null ? String(b.corrects).slice(0, 300) : null, reversible: b.reversible != null ? !!b.reversible : null,
        status: "open", answer: "", by, at: now, updated: now };
      state.cards.push(c);
      if (c.corrects && /^\d+$/.test(c.corrects)) { const old = state.cards.find((x) => x.id === Number(c.corrects)); if (old) { old.status = "wrong"; old.correctedBy = c.id; } }
      save(); broadcast({ type: "cards" });
      return c;
    }
    const c = state.cards.find((x) => x.id === Number(b.id));
    if (!c) return { error: "no such card" };
    if (b.op === "answer") {   // the operator answers a question (or comments on any card)
      c.answer = String(b.answer || "").slice(0, 2000); if (c.kind === "question") c.status = "answered";
      c.updated = now;
      state.taskMsgs.push(`- the operator answered card #${c.id} (${c.kind}) "${c.title}": ${c.answer}`);
      save(); broadcast({ type: "cards" });
      return c;
    }
    if (b.op === "update") {
      if (b.status && CARD_STATUS.includes(b.status)) c.status = b.status;
      if (b.text != null) c.text = String(b.text).slice(0, 2000);
      if (b.evidence) c.evidence.push({ kind: String(b.evidence.kind || "note").slice(0, 20), text: String(b.evidence.text || "").slice(0, 400) });
      if (by === "operator" && b.status) state.taskMsgs.push(`- the operator marked card #${c.id} "${c.title}" ${b.status}`);
      c.updated = now; save(); broadcast({ type: "cards" });
      return c;
    }
    return { error: "op: new | update | answer" };
  }

  // ── HTTP ──────────────────────────────────────────────────────────────────
  async function handle(req, res, url) {
    const p = url.pathname;
    if (!p.startsWith("/api/flow/")) return false;
    if (p === "/api/flow/hook" && req.method === "POST") {
      const out = onHook(await readBody(req));
      json(res, 200, out ? { output: out } : {});
      return true;
    }
    if (p === "/api/flow/wait") {
      const ctx = pendingContext();
      if (ctx) { json(res, 200, { context: ctx }); return true; }
      waiters.push(res);
      req.on("close", () => { const i = waiters.indexOf(res); if (i >= 0) { waiters.splice(i, 1); listening(); } });
      listening();
      return true;
    }
    if (p === "/api/flow/steps") {
      if (req.method === "POST") { const out = stepOp(await readBody(req)); json(res, out.error ? 400 : 200, out); return true; }
      const task = url.searchParams.get("task");
      const list = task ? state.steps.filter((x) => x.task === Number(task)) : state.steps.slice(-200);
      json(res, 200, { steps: list, open: state.openStep });
      return true;
    }
    if (p === "/api/flow/tasks") {
      const mod = url.searchParams.get("mod"), name = url.searchParams.get("name");
      const list = mod ? state.tasks.filter((t) => !t.mod || (t.mod === mod && t.name === name)) : state.tasks;
      json(res, 200, { tasks: list, active: state.activeTask, states: TASK_STATES, links: LINK_TYPES });
      return true;
    }
    if (p === "/api/flow/sketch" && req.method === "POST") {
      const out = sketchOp(await readBody(req));
      json(res, out.error ? 400 : 200, out);
      return true;
    }
    if (p === "/api/flow/task" && req.method === "POST") {
      const b = await readBody(req);
      const out = taskOp(b);
      if (b.by === "operator" && !out.error) flushWaiters();
      json(res, out.error ? 400 : 200, out);
      return true;
    }
    if (p === "/api/flow/card" && req.method === "POST") {
      const b = await readBody(req);
      const out = cardOp(b);
      if (b.by === "operator" && !out.error) flushWaiters();
      json(res, out.error ? 400 : 200, out);
      return true;
    }
    if (p === "/api/flow/session" && req.method === "POST") {
      // the operator: { op: "lane", id, status } ends a lane by hand (a background run with no end event);
      // { op: "purge", agent } drops one agent id's events (test traffic)
      const b = await readBody(req);
      if (b.op === "lane") { laneEnd(state.lanes.find((l) => l.id === Number(b.id)), b.result || "", b.status || "dismissed"); json(res, 200, { ok: true }); return true; }
      if (b.op === "purge" && b.agent) {
        const drop = (e) => e.agent === b.agent;
        activity = activity.filter((e) => !drop(e));
        try { fs.writeFileSync(LOG, activity.map((e) => JSON.stringify(e)).join(String.fromCharCode(10)) + String.fromCharCode(10)); } catch (_) {}
        for (const st of state.steps) st.events = st.events.filter((e) => !drop(e));
        state.steps = state.steps.filter((st) => !(st.inferred && !st.events.length && st.status !== "open"));
        state.lanes = state.lanes.filter((l) => !(l.agent === b.agent));
        sessionChanged(); stepsChanged();
        json(res, 200, { ok: true }); return true;
      }
      json(res, 400, { error: "op: lane | purge" }); return true;
    }
    if (p === "/api/flow/session") {
      const n = Number(url.searchParams.get("events") || 400);
      json(res, 200, { session: state.session, open: state.openStep, activeTask: state.activeTask, active: taskById(state.activeTask) || null, listening: waiters.length,
        steps: state.steps.slice(-60), lanes: state.lanes.slice(-40), events: activity.slice(-n), cards: state.cards || [] });
      return true;
    }
    if (p === "/api/flow/listening") { json(res, 200, { n: waiters.length }); return true; }
    if (p === "/api/flow/events") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
      res.write(": connected\n\n");
      clients.add(res);
      const ping = setInterval(() => { try { res.write(": ping\n\n"); } catch (_) {} }, 20000);
      req.on("close", () => { clearInterval(ping); clients.delete(res); });
      return true;
    }
    if (p === "/api/flow/collab") {
      const mod = url.searchParams.get("mod"), name = url.searchParams.get("name");
      const pre = `${mod}|${name}|`;
      const locks = {}, nodeEdits = {};
      for (const [k, v] of Object.entries(state.locks)) if (k.startsWith(pre)) locks[k.slice(pre.length)] = v;
      for (const [k, v] of edits) if (k.startsWith(pre)) nodeEdits[k.slice(pre.length)] = v;
      json(res, 200, {
        notes: state.notes.filter((n) => n.mod === mod && n.name === name),
        locks, edits: nodeEdits,
        plan: state.plan && state.plan.mod === mod && state.plan.name === name ? state.plan : null,
        // this map's events (the viewer groups them into sessions by agent)
        activity: activity.filter((e) => (e.hits || []).some((h) => h.mod === mod && h.name === name)).slice(-3000),
        changes: changes.get(`${mod}|${name}`) || null,
        sketches: (state.sketches || []).filter((x) => x.mod === mod && x.name === name),
      });
      return true;
    }
    if (p === "/api/flow/note" && req.method === "POST") {
      const b = await readBody(req);
      if (!b.mod || !b.name || !b.node || !String(b.text || "").trim()) { json(res, 400, { error: "mod, name, node, text" }); return true; }
      const n = { id: state.nextNote++, mod: b.mod, name: b.name, node: b.node, text: String(b.text).trim().slice(0, 2000), at: Date.now(), delivered: false, done: false, reply: "" };
      state.notes.push(n); save(); broadcast({ type: "collab" });
      flushWaiters();
      json(res, 200, n);
      return true;
    }
    if (p === "/api/flow/notes") {
      if (req.method === "POST") {   // the agent answers: { id, reply, done }
        const b = await readBody(req);
        const n = state.notes.find((x) => x.id === Number(b.id));
        if (!n) { json(res, 404, { error: "no such note" }); return true; }
        if (b.reply != null) n.reply = String(b.reply).slice(0, 2000);
        if (b.done != null) n.done = !!b.done;
        n.delivered = true;
        save(); broadcast({ type: "collab" });
        json(res, 200, n);
        return true;
      }
      json(res, 200, { open: state.notes.filter((n) => !n.done) });
      return true;
    }
    if (p === "/api/flow/lock" && req.method === "POST") {
      const b = await readBody(req);
      const k = key(b.mod, b.name, b.node);
      if (b.locked) state.locks[k] = { note: String(b.note || "").slice(0, 300), at: Date.now() };
      else delete state.locks[k];
      save(); broadcast({ type: "collab" });
      json(res, 200, { ok: true });
      return true;
    }
    if (p === "/api/flow/plan" && req.method === "POST") {
      const b = await readBody(req);
      if (b.answer) {               // the operator: { answer: approve|reject, removed, text }
        if (!state.plan) { json(res, 404, { error: "no plan" }); return true; }
        const pl = state.plan;
        pl.status = b.answer === "reject" ? "rejected" : "approved";
        pl.removed = Array.isArray(b.removed) ? b.removed : [];
        pl.answer = String(b.text || "").slice(0, 1000);
        pl.delivered = false;
        for (const id of pl.removed) state.locks[key(pl.mod, pl.name, id)] = { note: "removed from the agent's plan", at: Date.now() };
      } else {                      // the agent proposes: { mod, name, ids, note }
        state.plan = { mod: b.mod, name: b.name, ids: Array.isArray(b.ids) ? b.ids : [], note: String(b.note || "").slice(0, 2000),
                       status: "proposed", removed: [], answer: "", at: Date.now(), delivered: false };
      }
      save(); broadcast({ type: "collab" });
      if (b.answer) flushWaiters();
      json(res, 200, state.plan);
      return true;
    }
    return false;
  }

  // a message for the agent from elsewhere in the dashboard (the summarize
  // button): queued like a task change, delivered by hook context or a wake
  function tell(msg) { state.taskMsgs.push("- " + msg); save(); flushWaiters(); }
  return { handle, broadcast, tell, sketches: () => state.sketches || [] };
};
