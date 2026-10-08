// SousVide Live: the live dedi from the browser (and the MCP), through pz-shell.
//
// The sealed VMs answer "what does the engine do"; this answers "what is the
// running server doing right now". It shells out to the pz-shell CLI
// (../shell/pz-shell), which owns the protocol (a file queue the PZShell server
// mod polls), so everything pz-shell can do, the page can do:
//
//   GET  /live                    the page (live.html)
//   GET  /api/live/status         dedi liveness (dedi-status.sh) + pz-shell gate and reachability
//   POST /api/live/eval           { code }             Lua in the server's VM -> printed output + result
//   GET  /api/live/probes         the probe library (shell/examples/*.lua, first comment line as a title)
//   POST /api/live/probe          { name }             run one probe
//   POST /api/live/puppet         { action, as?, args? }  equip / unequip / inventory / drop / reload / damage / credit-kills / whoami
//   POST /api/live/profile        { cmd: start|snap|stop }
//   POST /api/live/reload         { module }           hot re-require
//   POST /api/live/snapshot       { cmd: list|save|show|delete, name? }
//   POST /api/live/gate           { on: true|false }   arm / disarm the shell
//   GET  /api/live/tail?re=&mod=  server-sent events: the debug log filtered by a regex (or one mod's tap stream)
//
// Dev-only, like pz-shell itself: arbitrary code execution on the server.

"use strict";
const fs = require("fs");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const HERE = __dirname;
const SHELL = path.join(HERE, "..", "shell", "pz-shell");
const EXAMPLES = path.join(HERE, "..", "shell", "examples");
// the monorepo's liveness script, when the kit sits in pz-mods
const DEDI_STATUS = path.join(HERE, "..", "..", "tools", "pz-dedicated-docker", "scripts", "dedi-status.sh");
const BASH = process.env.PZ_BASH || "bash";
const PUPPET = new Set(["equip", "unequip", "inventory", "drop", "reload", "damage", "credit-kills", "whoami"]);

function json(res, code, body) {
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve) => {
    let s = "";
    req.on("data", (c) => { s += c; if (s.length > 1e6) req.destroy(); });
    req.on("end", () => { try { resolve(s ? JSON.parse(s) : {}); } catch (_) { resolve({}); } });
  });
}

// pz-shell has ONE queue file: requests run one at a time, in order
let chain = Promise.resolve();
function shell(args, stdin, timeoutMs = 30000) {
  const run = () => new Promise((resolve) => {
    const child = spawn(BASH, [SHELL, ...args], { env: { ...process.env, MSYS_NO_PATHCONV: "1" } });
    let out = "", err = "";
    const timer = setTimeout(() => { killTree(child); err += "\n(timed out)"; }, timeoutMs);
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.on("error", (e) => { clearTimeout(timer); resolve({ ok: false, code: -1, out, err: String(e) }); });
    child.on("close", (code) => { clearTimeout(timer); resolve({ ok: code === 0, code, out: out.trimEnd(), err: err.trimEnd() }); });
    if (stdin !== undefined) { child.stdin.write(stdin); }
    child.stdin.end();
  });
  const p = chain.then(run, run);
  chain = p.catch(() => {});
  return p;
}

function killTree(child) {
  if (!child || child.exitCode !== null) return;
  if (process.platform === "win32") {
    try { spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"]); } catch (_) {}
  } else {
    try { child.kill("SIGTERM"); } catch (_) {}
  }
}

function probes() {
  if (!fs.existsSync(EXAMPLES)) return [];
  return fs.readdirSync(EXAMPLES).filter((f) => f.endsWith(".lua")).sort().map((f) => {
    const first = fs.readFileSync(path.join(EXAMPLES, f), "utf8").split(/\r?\n/).find((l) => l.startsWith("--")) || "";
    return { name: f, title: first.replace(/^--+\s*/, "").replace(new RegExp("^" + f.replace(".", "\\.") + ":?\\s*"), "") };
  });
}

function dediStatus() {
  if (!fs.existsSync(DEDI_STATUS)) return { text: "dedi-status.sh not found (kit outside pz-mods)", code: -1 };
  const r = spawnSync(BASH, [DEDI_STATUS], { encoding: "utf8", timeout: 10000 });
  return { text: (r.stdout || r.stderr || "").trim(), code: r.status };
}

// LIVE TAILS. Not through `pz-shell tail`: that runs `tail -F` inside the
// container through `docker exec`, and killing the client never stops it, so
// every closed page would leave a tail running in the container (measured:
// one per closed stream). Here the in-container shell records its pid first,
// the filter runs here (a JS RegExp, case-insensitive), and closing the page
// kills exactly that process.
const CONTAINER = process.env.PZ_CONTAINER || "pzserver";
function tail(req, res, url) {
  res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
  const send = (line) => res.write("data: " + JSON.stringify(line) + "\n\n");
  const mod = (url.searchParams.get("mod") || "").replace(/[^\w.-]/g, "");
  let re = null;
  try { const r = url.searchParams.get("re"); if (r) re = new RegExp(r, "i"); } catch (e) { send("[bad regex: " + e.message + "]"); }
  const tag = "/tmp/sousvide-live-" + process.pid + "-" + Date.now() + "-" + Math.random().toString(36).slice(2, 7) + ".pid";
  const file = mod
    ? '/home/steam/Zomboid/Lua/pz-shell/stream/' + mod + '.log'
    : '$(ls -t /home/steam/Zomboid/Logs/*DebugLog-server.txt 2>/dev/null | head -1)';
  const inner = 'f=' + file + '; if [ -z "$f" ] || [ ! -e "$f" ]; then echo "no log to follow" >&2; exit 1; fi; ' +
    'echo $$ > ' + tag + '; echo "following: $f" >&2; exec tail -n 40 -F "$f" 2>&1';
  const child = spawn("docker", ["exec", "-i", CONTAINER, "sh", "-c", inner]);
  let buf = "";
  child.stdout.on("data", (d) => {
    buf += d;
    const lines = buf.split(/\r?\n/);
    buf = lines.pop();
    for (const l of lines) if (l && (!re || re.test(l))) send(l);
  });
  child.stderr.on("data", (d) => send("[live] " + String(d).trim()));
  child.on("error", (e) => { send("[live] " + String(e)); res.end(); });
  child.on("close", (code) => { send("[log ended: " + code + "]"); res.end(); });
  const ping = setInterval(() => res.write(": ping\n\n"), 15000);
  req.on("close", () => {
    clearInterval(ping);
    // stop the tail INSIDE the container, then the local client
    spawn("docker", ["exec", CONTAINER, "sh", "-c", "kill $(cat " + tag + ") 2>/dev/null; rm -f " + tag]).on("error", () => {});
    killTree(child);
  });
}

async function handle(req, res, url) {
  const p = url.pathname;
  if (p === "/live" || p === "/live.html") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    fs.createReadStream(path.join(HERE, "live.html")).pipe(res);
    return true;
  }
  if (!p.startsWith("/api/live/")) return false;
  const action = p.slice("/api/live/".length);
  try {
    if (action === "status" && req.method === "GET") {
      const gate = await shell(["status"], undefined, 15000);
      return json(res, 200, { dedi: dediStatus(), shell: gate }), true;
    }
    if (action === "probes" && req.method === "GET") return json(res, 200, probes()), true;
    if (action === "tail" && req.method === "GET") return tail(req, res, url), true;
    if (req.method !== "POST") return json(res, 405, { error: "POST" }), true;
    const b = await readBody(req);
    if (action === "eval") {
      if (typeof b.code !== "string" || !b.code.trim()) return json(res, 400, { error: "code" }), true;
      return json(res, 200, await shell(["eval", "-"], b.code, (b.timeout || 30) * 1000)), true;
    }
    if (action === "probe") {
      const name = String(b.name || "");
      if (!/^[\w.-]+\.lua$/.test(name) || !fs.existsSync(path.join(EXAMPLES, name))) return json(res, 404, { error: "no such probe" }), true;
      return json(res, 200, await shell(["eval", "-f", path.join(EXAMPLES, name)])), true;
    }
    if (action === "puppet") {
      if (!PUPPET.has(b.action)) return json(res, 400, { error: "action must be one of " + [...PUPPET].join(", ") }), true;
      const args = ["puppet", b.action];
      if (b.as) args.push("--as", String(b.as));
      for (const a of (Array.isArray(b.args) ? b.args : [])) args.push(String(a));
      return json(res, 200, await shell(args)), true;
    }
    if (action === "profile") {
      if (!["start", "snap", "stop"].includes(b.cmd)) return json(res, 400, { error: "cmd: start|snap|stop" }), true;
      return json(res, 200, await shell(["profile", b.cmd])), true;
    }
    if (action === "reload") {
      if (!/^[\w./-]+$/.test(String(b.module || ""))) return json(res, 400, { error: "module" }), true;
      return json(res, 200, await shell(["reload", String(b.module)])), true;
    }
    if (action === "snapshot") {
      if (!["list", "save", "show", "delete"].includes(b.cmd)) return json(res, 400, { error: "cmd: list|save|show|delete" }), true;
      const args = ["snapshot", b.cmd];
      if (b.name) { if (!/^[\w.-]+$/.test(String(b.name))) return json(res, 400, { error: "name" }), true; args.push(String(b.name)); }
      return json(res, 200, await shell(args)), true;
    }
    if (action === "gate") return json(res, 200, await shell([b.on ? "enable" : "disable"])), true;
    return json(res, 404, { error: "unknown action " + action }), true;
  } catch (e) {
    return json(res, 500, { error: String(e && e.message || e) }), true;
  }
}

module.exports = { handle, shell, probes, dediStatus };
