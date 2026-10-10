#!/usr/bin/env node
// Claude Code hook -> SousVide Flow (dashboard/flowcollab.js).
//
// Relays the hook's JSON to the dashboard and prints whatever it answers
// (a deny for an edit on a locked block, or operator notes as context).
// Never in the way: if the dashboard is not running, or slow, this prints
// nothing and exits 0, and the tool call goes ahead as if no hook existed.
//
// Wire it for PreToolUse + PostToolUse (matcher "Read|Edit|MultiEdit|Write|NotebookEdit")
// and UserPromptSubmit:   node <kit>/dashboard/flow-hook.js
const http = require("http");
const PORT = parseInt(process.env.PZTEST_DASH_PORT || "8760", 10);

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (input += c));
process.stdin.on("end", () => {
  const done = (out) => { if (out) process.stdout.write(JSON.stringify(out)); process.exit(0); };
  const req = http.request({ host: "127.0.0.1", port: PORT, path: "/api/flow/hook", method: "POST",
    headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(input) }, timeout: 1500 }, (res) => {
    let body = "";
    res.on("data", (c) => (body += c));
    res.on("end", () => { try { done(JSON.parse(body).output); } catch (_) { done(null); } });
  });
  req.on("timeout", () => { req.destroy(); done(null); });
  req.on("error", () => done(null));
  req.end(input);
});
