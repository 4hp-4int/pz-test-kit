#!/usr/bin/env node
/*
 * UIView — live-drive bridge
 * ==========================
 * Spawns the resident Kahlua harness (`pztest --serve <scene>`), serves the
 * play page, and relays browser input -> Lua -> frame over plain HTTP. Each
 * POST /event writes one command line to the harness's stdin and resolves with
 * the next @@FRAME@@ line it prints. No deps, no websockets — request/response
 * matches click->frame exactly. The Lua VM is the SAME one tests/snapshots use.
 *
 *   node serve-bridge.js [scene] [port]
 *   (defaults: SaucePalette, 8753)
 */
const http = require("http");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const KIT = path.resolve(HERE, "..");
const SCENE = process.argv[2] || "SaucePalette";
const PORT = parseInt(process.argv[3] || "8753", 10);

// ── resident harness ────────────────────────────────────────────────────────
// On Windows, bare "bash" can resolve to the WSL shim (System32ash.exe),
// which fails without a distro. Prefer Git Bash explicitly.
function bashPath() {
  if (process.platform === "win32") {
    for (const c of [
      "C:\Program Files\Git\bin\bash.exe",
      "C:\Program Files (x86)\Git\bin\bash.exe",
    ]) if (fs.existsSync(c)) return c;
  }
  return "bash";
}

const child = spawn(bashPath(), [path.join(KIT, "pztest"), "--serve", SCENE], {
  cwd: HERE,
  stdio: ["pipe", "pipe", "inherit"],
});

let ready = false;
const pending = [];           // FIFO of {resolve} awaiting a frame
let stdoutBuf = "";

child.stdout.on("data", (chunk) => {
  stdoutBuf += chunk.toString();
  let nl;
  while ((nl = stdoutBuf.indexOf("\n")) >= 0) {
    const line = stdoutBuf.slice(0, nl).replace(/\r$/, "");
    stdoutBuf = stdoutBuf.slice(nl + 1);
    if (line === "@@SERVE_READY@@") { ready = true; console.error("[bridge] harness ready"); }
    else if (line.startsWith("@@FRAME@@")) {
      const p = pending.shift();
      if (p) p.resolve({ frame: line.slice("@@FRAME@@".length) });
    } else if (line.startsWith("@@ERR@@")) {
      const p = pending.shift();
      if (p) p.resolve({ error: line.slice("@@ERR@@".length) });
      console.error("[bridge] lua err:", line.slice(7));
    } else if (line.length) {
      console.error("[harness]", line);
    }
  }
});
child.on("exit", (c) => { console.error("[bridge] harness exited", c); process.exit(c || 0); });

function dispatch(cmd) {
  return new Promise((resolve) => {
    pending.push({ resolve });
    child.stdin.write(cmd.replace(/\n/g, " ") + "\n");
    setTimeout(() => {
      const i = pending.findIndex((x) => x.resolve === resolve);
      if (i >= 0) { pending.splice(i, 1); resolve({ error: "timeout" }); }
    }, 4000);
  });
}

// ── static helpers ──────────────────────────────────────────────────────────
function sendFile(res, file, type) {
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, { "Content-Type": type });
    res.end(data);
  });
}

// ── server ──────────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  const url = req.url.split("?")[0];

  if (req.method === "GET" && (url === "/" || url === "/play.html")) {
    return sendFile(res, path.join(HERE, "play.html"), "text/html; charset=utf-8");
  }
  if (req.method === "GET" && url === "/replay.js") {
    return sendFile(res, path.join(HERE, "replay.js"), "application/javascript");
  }
  if (req.method === "GET" && url === "/scene") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ scene: SCENE }));
  }
  // GET /icon/Item_Bandage  -> pre-resolved PNG from .iconcache (warmed by a
  // static build); 404 -> replay.js falls back to a placeholder box.
  if (req.method === "GET" && url.startsWith("/icon/")) {
    // keep hyphens (sir_ui-close etc.); try the loose-file name, then the
    // mod-pack namespace build_view warms as "_mp_<name>.png"
    const name = decodeURIComponent(url.slice("/icon/".length)).replace(/[^A-Za-z0-9_\-]/g, "");
    res.setHeader("Cache-Control", "public, max-age=86400");
    const bare = path.join(HERE, ".iconcache", name + ".png");
    if (fs.existsSync(bare)) return sendFile(res, bare, "image/png");
    return sendFile(res, path.join(HERE, ".iconcache", "_mp_" + name + ".png"), "image/png");
  }
  if (req.method === "POST" && url === "/event") {
    let body = "";
    req.on("data", (d) => { body += d; if (body.length > 4096) req.destroy(); });
    req.on("end", async () => {
      if (!ready) { res.writeHead(503); return res.end('{"error":"starting"}'); }
      const out = await dispatch(body.trim() || "render");
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(out.frame ? out.frame : JSON.stringify(out));
    });
    return;
  }
  res.writeHead(404); res.end("not found");
});

server.listen(PORT, () => {
  console.error(`[bridge] http://localhost:${PORT}  (scene: ${SCENE})`);
});

process.on("SIGINT", () => { try { child.stdin.write("__quit__\n"); } catch (e) {} process.exit(0); });
